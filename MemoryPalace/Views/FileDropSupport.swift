#if os(macOS)
import Foundation
import UniformTypeIdentifiers

/// 从 Finder 拖进来的文件（plan-mac-code-mode-gaps §6）：普通聊天变附件、Code 输入框插路径共用
enum FileDrop {
    static let types: [UTType] = [.fileURL]

    /// 取出本地文件 URL，按拖进来的顺序在主线程回调。没有文件就返回 false（让别的 drop 接，比如贴纸）
    @discardableResult
    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let lock = NSLock()
        var urls = [URL?](repeating: nil, count: files.count)
        let group = DispatchGroup()
        for (index, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                urls[index] = url
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(urls.compactMap { $0 }) }
        }
        return true
    }

    /// 终端拖文件的写法：特殊字符前加反斜杠（Claude Code / Codex 认这种路径，图片会自己读）
    static func shellEscaped(_ path: String) -> String {
        let special = Set(" \t\\'\"()[]{}<>|&;$!*?#~`")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }
}
#endif
