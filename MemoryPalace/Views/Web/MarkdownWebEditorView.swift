import SwiftUI

struct MarkdownWebEditorCommand: Equatable {
    let name: String
    let token: Int
}

struct MarkdownWebEditorView: View {
    @Binding var content: String
    var findQuery: String = ""
    var findIndex: Int = 0
    /// 查找并替换的替换文本（命令 replaceNext / replaceAll 用）
    var replaceText: String = ""
    var showsLineNumbers: Bool = false
    var hidesKeyboardAccessory: Bool = false
    var command: MarkdownWebEditorCommand?
    var onRequestSave: (() -> Void)? = nil
    var onFindResult: ((Int, Int) -> Void)? = nil
    /// 编辑器里按 ⌘F
    var onOpenFind: (() -> Void)? = nil
    /// 替换完成，参数 = 下一处的序号（0 起）
    var onReplaceDone: ((Int) -> Void)? = nil
    /// [[wiki link]] 点击：交上层跳转/建文件
    var onOpenWikiLink: ((String) -> Void)? = nil

    @State private var isReady = false
    @State private var errorMessage: String?
    @State private var revision = 0

    var body: some View {
        ZStack {
            WebViewHost(
                htmlResourceName: "markdown-editor",
                payload: editorPayload,
                hidesKeyboardAccessory: hidesKeyboardAccessory,
                onMessage: handleMessage
            )

            if !isReady {
                Text(errorMessage ?? "正在加载编辑器")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(errorMessage == nil ? Theme.textMuted : Theme.branchIndicator)
                    .padding(10)
                    .background(Theme.mainBg.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .background(Theme.mainBg)
    }

    private var editorPayload: [String: Any] {
        let tokens = ThemeManager.shared.currentTokenSet
        var payload: [String: Any] = [
            "type": "setContent",
            "content": content,
            "revision": revision,
            "lineNumbers": showsLineNumbers,
            // 网页底色透明（透出下面的 Theme.mainBg），字色跟主题走
            "colors": [
                "text": tokens.textPrimary.hexString,
                "muted": tokens.textMuted.hexString,
                "scheme": Theme.activeScheme == .dark ? "dark" : "light"
            ],
            "find": [
                "query": findQuery,
                "index": findIndex,
                "replace": replaceText
            ]
        ]
        if let command {
            payload["command"] = [
                "name": command.name,
                "token": command.token
            ]
        }
        return payload
    }

    private func handleMessage(_ message: WebViewBridgeMessage) {
        switch message.type {
        case "ready":
            isReady = true
            errorMessage = nil
        case "contentChanged":
            if let newContent = message.content, newContent != content {
                content = newContent
                revision = message.revision ?? revision
            }
        case "requestSave":
            if let newContent = message.content {
                content = newContent
            }
            onRequestSave?()
        case "error":
            errorMessage = message.message ?? "编辑器加载失败"
        case "openWikiLink":
            if let target = message.target, !target.isEmpty {
                onOpenWikiLink?(target)
            }
        case "openLink":
            openExternalWebViewLink(message.href)
        case "findResult":
            onFindResult?(message.count ?? 0, message.index ?? 0)
        case "openFind":
            onOpenFind?()
        case "replaceDone":
            onReplaceDone?(message.index ?? 0)
        default:
            break
        }
    }
}
