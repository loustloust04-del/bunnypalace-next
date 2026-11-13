import MemoryCore
import Foundation

extension WikiStore {
    init(profileId: String) {
        self.init(root: FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent("wiki", isDirectory: true))
    }
}

extension CatalogRecallIndexer {
    func deleteProfile(_ profileId: String, wiki: WikiStore? = nil) {
        deleteProfile(profileId, wiki: wiki, fallback: { WikiStore(profileId: profileId) })
    }
}
