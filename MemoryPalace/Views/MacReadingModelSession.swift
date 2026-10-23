#if os(macOS)
import Foundation
import CryptoKit

/// Owned by the Settings host, so switching pages reuses completed model lists.
@MainActor
final class MacReadingModelSession {
    private struct RequestKey: Hashable {
        let id: String
        let type: String
        let baseURL: String
        let headers: Data
        let keyDigest: Data
    }
    private struct Entry {
        let key: RequestKey
        let models: [ProviderModel]
        let expires: Date
    }
    private var entries: [String: Entry] = [:]

    func models(for credential: APICredential, manager: ProviderManager) async -> [ProviderModel]? {
        let headers = credential.extraHeaders.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        let key = RequestKey(id: credential.id, type: credential.type.rawValue, baseURL: credential.baseURL,
                             headers: (try? JSONEncoder().encode(headers)) ?? Data(),
                             keyDigest: Data(SHA256.hash(data: Data((manager.apiKey(for: credential.id) ?? "").utf8))))
        entries = entries.filter { entry in manager.credentials.contains { $0.id == entry.key } }
        if let entry = entries[credential.id], entry.key == key, entry.expires > Date() { return entry.models }
        guard !Task.isCancelled else { return nil }
        let result = await manager.fetchModels(credentialId: credential.id)
        guard !Task.isCancelled else { return nil }
        if case .success(let models) = result, !models.isEmpty {
            entries[credential.id] = Entry(key: key, models: models, expires: Date().addingTimeInterval(300))
            return models
        }
        // Briefly reuse the existing fallback after an error; do not cache cancellation.
        entries[credential.id] = Entry(key: key, models: credential.models, expires: Date().addingTimeInterval(20))
        return credential.models
    }
}
#endif
