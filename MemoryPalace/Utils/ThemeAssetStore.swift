import Foundation

enum ThemeAssetStore {
    private static let directoryName = "ThemeAssets"

    private static var assetsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("MemoryPalace", isDirectory: true)
        let assetsDirectory = appDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        return assetsDirectory
    }

    static func saveBackgroundImage(from url: URL, for themeId: String) throws -> String {
        let data = try Data(contentsOf: url)
        return try saveBackgroundImage(
            data: data,
            for: themeId,
            preferredExtension: url.pathExtension
        )
    }

    static func saveBackgroundImage(
        data: Data,
        for themeId: String,
        preferredExtension: String?
    ) throws -> String {
        let fileExtension = sanitizedExtension(preferredExtension)
        let fileName = "theme-\(themeId)-\(UUID().uuidString).\(fileExtension)"
        let destination = assetsDirectoryURL.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        return fileName
    }

    static func copyBackgroundImage(named fileName: String, for themeId: String) throws -> String {
        guard let sourceURL = url(for: fileName) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let destinationFileName = "theme-\(themeId)-\(UUID().uuidString).\(sanitizedExtension(sourceURL.pathExtension))"
        let destinationURL = assetsDirectoryURL.appendingPathComponent(destinationFileName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationFileName
    }

    static func removeBackgroundImage(named fileName: String) {
        guard let url = url(for: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func url(for fileName: String) -> URL? {
        let candidate = assetsDirectoryURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func sanitizedExtension(_ candidate: String?) -> String {
        let trimmed = (candidate ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if trimmed.isEmpty {
            return "png"
        }

        let allowed = trimmed.filter { $0.isLetter || $0.isNumber }
        return allowed.isEmpty ? "png" : allowed
    }
}
