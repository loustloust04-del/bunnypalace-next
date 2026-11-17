import Foundation

/// 资源只在 `MemoryCore_memoryd.bundle` 里：`Bundle.module` 找不到包会直接 fatalError，所以没有「源目录兜底」这条路
enum MemorydResources {
    static var bundle: Bundle { .module }

    /// `Sources/memoryd/web`（打包后在 `MemoryCore_memoryd.bundle/web`）
    static var webRoot: URL? {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            return nil
        }
        return url.deletingLastPathComponent()
    }

    /// `Sources/memoryd/MemoryBench`（打包后在 `MemoryCore_memoryd.bundle/MemoryBench`）
    static var benchDirectory: URL? {
        guard let url = Bundle.module.url(forResource: "memory-bench-wiki-probe", withExtension: "json", subdirectory: "MemoryBench") else {
            return nil
        }
        return url.deletingLastPathComponent()
    }
}
