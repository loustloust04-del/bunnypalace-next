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

    /// 内置虚构楼层（recall-24 的 `snapshot` 目标；与 app 资源 / 包测试夹具逐字节相同）
    static var recallFloorURL: URL? {
        Bundle.module.url(forResource: "memory-bench-recall-floor-xingyan", withExtension: "json", subdirectory: "MemoryBench")
    }
}
