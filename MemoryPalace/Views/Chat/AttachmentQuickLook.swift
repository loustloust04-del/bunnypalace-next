#if os(macOS)
import SwiftUI
import QuickLook

/// mac 附件预览请求（面 3b，C1）：只是附件的**值快照**（名字 + 字节），不指向 VM 附件数组 / Conversation / 源文件。
/// 图片和带原始字节的文件按原字节预览；只剩提取文本的旧附件按 .txt 预览，不伪称原文件。
struct AttachmentPreviewRequest: Equatable {
    let name: String
    let data: Data

    init(_ item: BubbleAttachmentItem) {
        switch item {
        case .image(let name, let data):
            self.init(name: name, data: data, textFallback: false)
        case .fileData(let name, _, let data):
            self.init(name: name, data: data, textFallback: false)
        case .file(let name, _, let content):
            self.init(name: name, data: Data((content ?? "").utf8), textFallback: true)
        }
    }

    init(_ att: PendingChatAttachment) {
        if att.isImage, let data = att.imageData {
            self.init(name: att.name, data: data, textFallback: false)
        } else if let data = att.fileData {
            self.init(name: att.name, data: data, textFallback: false)
        } else {
            self.init(name: att.name, data: Data(att.extractedText.utf8), textFallback: true)
        }
    }

    private init(name: String, data: Data, textFallback: Bool) {
        // 文件名只取末级、保扩展；文本兜底一律 .txt
        var base = (name as NSString).lastPathComponent
        if base.isEmpty { base = "attachment" }
        if textFallback, (base as NSString).pathExtension.lowercased() != "txt" {
            base += ".txt"
        }
        self.name = base
        self.data = data
    }
}

extension View {
    /// 系统 QuickLook（同文件库）预览一个附件快照：每次预览写到独立临时目录，面板关掉（url 回 nil）才删目录、复位请求。
    func attachmentQuickLook(_ request: Binding<AttachmentPreviewRequest?>) -> some View {
        modifier(AttachmentQuickLookModifier(request: request))
    }
}

private struct AttachmentQuickLookModifier: ViewModifier {
    @Binding var request: AttachmentPreviewRequest?
    @State private var url: URL?

    func body(content: Content) -> some View {
        content
            .quickLookPreview($url)
            .onChange(of: request) { _, req in
                guard let req else { return }
                url = AttachmentPreviewFiles.write(req)
                if url == nil { request = nil }
            }
            .onChange(of: url) { old, new in
                // QuickLook 面板关闭 = SwiftUI 把 url 置回 nil：这时副本才没人用，删目录、复位请求
                if new == nil, let old {
                    AttachmentPreviewFiles.remove(old)
                    request = nil
                }
            }
    }
}

private enum AttachmentPreviewFiles {
    static func write(_ req: AttachmentPreviewRequest) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-preview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = dir.appendingPathComponent(req.name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try req.data.write(to: file, options: .atomic)
            return file
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
#endif
