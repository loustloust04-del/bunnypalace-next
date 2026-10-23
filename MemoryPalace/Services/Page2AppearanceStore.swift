import Foundation
import Observation
#if os(iOS)
import UIKit
import ImageIO
#endif

@MainActor
@Observable
final class Page2AppearanceStore {
    static let shared: Page2AppearanceStore = {
        #if DEBUG || PERF_BENCH
        if ProcessInfo.processInfo.arguments.contains("page2-ui-test") {
            let requested = ProcessInfo.processInfo.environment["PAGE2_UI_LAYOUT_CASE"] ?? UUID().uuidString
            let caseID = requested.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let store = Page2AppearanceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("page2-appearance-ui-\(caseID)"))
            if ProcessInfo.processInfo.environment["PAGE2_UI_RENDERING"] == "standard" {
                store.value.rendering = "standard"
                store.value.luminosity = "light"
                store.value.wallpaper = "dusk"
            }
            return store
        }
        #endif
        return Page2AppearanceStore()
    }()
    private(set) var value = Page2Appearance()
    var errorMessage: String?
    private var previewValue: Page2Appearance?
    var displayed: Page2Appearance { previewValue ?? value }
    func preview(_ draft: Page2Appearance) { previewValue = draft }
    func cancelPreview() { previewValue = nil }
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/Page2/Appearance")
        let url = self.directory.appendingPathComponent("appearance.json")
        if let data = try? Data(contentsOf: url) {
            do { value = try JSONDecoder().decode(Page2Appearance.self, from: data) }
            catch { errorMessage = "外观配置暂时无法读取，原文件已保留。" }
        }
    }

    func save(_ candidate: Page2Appearance) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(candidate).write(to: directory.appendingPathComponent("appearance.json"), options: .atomic)
            value = candidate
            previewValue = nil
            errorMessage = nil
            return true
        } catch { errorMessage = "外观没有保存：\(error.localizedDescription)"; return false }
    }

    func assetURL(_ name: String?) -> URL? {
        guard let name, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    #if os(iOS)
    @ObservationIgnored private var images: [String: UIImage] = [:]

    func image(named name: String?) -> UIImage? {
        guard let name else { return nil }
        if let image = images[name] { return image }
        guard let url = assetURL(name), let image = UIImage(contentsOfFile: url.path) else { return nil }
        if images.count >= 24 { images.removeAll(keepingCapacity: true) }
        images[name] = image
        return image
    }

    func discardImportedAssets(_ names: [String]) {
        let referenced = Set(value.icons.values.compactMap(\.imageFile) + [value.imageFile].compactMap { $0 })
        for name in names where !referenced.contains(name) {
            if let url = assetURL(name) { try? FileManager.default.removeItem(at: url) }
            images[name] = nil
        }
    }

    func importImage(_ data: Data, isIcon: Bool) async throws -> String {
        let destination = directory.appendingPathComponent("\(isIcon ? "icon" : "wallpaper")-\(UUID().uuidString).\(isIcon ? "png" : "jpg")")
        let maxSize = isIcon ? 512 : 2048
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSize
                  ] as CFDictionary),
                  let resized = isIcon ? UIImage(cgImage: cgImage).pngData() : UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try resized.write(to: destination, options: .atomic)
        }.value
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        return destination.lastPathComponent
    }
    #endif
}
