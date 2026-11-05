import SwiftUI

struct MarkdownWebEditorCommand: Equatable {
    let name: String
    let token: Int
}

struct MarkdownWebEditorReplacement {
    let content: String
    let nativeRevision: Int
}

struct MarkdownWebEditorDocument {
    private(set) var content: String
    private(set) var revision = 0
    private(set) var replacement: MarkdownWebEditorReplacement

    init(content: String) {
        self.content = content
        replacement = .init(content: content, nativeRevision: 0)
    }

    mutating func replace(with text: String) {
        content = text
        revision = 0
        replacement = .init(content: text, nativeRevision: replacement.nativeRevision + 1)
    }

    mutating func receive(content: String, revision: Int, nativeRevision: Int) -> Bool {
        guard nativeRevision == replacement.nativeRevision, revision >= self.revision,
              revision > self.revision || content == self.content else { return false }
        self.content = content
        self.revision = revision
        return true
    }
}

struct MarkdownWebEditorView: View {
    @Binding var document: MarkdownWebEditorDocument
    var findQuery: String = ""
    var findIndex: Int = 0
    /// 查找并替换的替换文本（命令 replaceNext / replaceAll 用）
    var replaceText: String = ""
    var showsLineNumbers: Bool = false
    var hidesKeyboardAccessory: Bool = false
    /// false = 被藏在别的模式下面（WebView 不拆，撤销历史留着）：网页先把防抖里的改动发回来，再收焦点
    var isActive: Bool = true
    var command: MarkdownWebEditorCommand?
    var onRequestSave: (() -> Void)? = nil
    var onFindResult: ((Int, Int) -> Void)? = nil
    /// 编辑器里按 ⌘F
    var onOpenFind: (() -> Void)? = nil
    /// 替换完成，参数 = 下一处的序号（0 起）
    var onReplaceDone: ((Int) -> Void)? = nil
    /// [[wiki link]] 点击：交上层跳转/建文件
    var onOpenWikiLink: ((String) -> Void)? = nil
    /// CodeMirror 撤销 / 重做是否可用（浮条按钮置灰）
    var onHistoryChange: ((_ canUndo: Bool, _ canRedo: Bool) -> Void)? = nil
    var onPendingChange: (() -> Void)? = nil
    var onSnapshot: (() -> Void)? = nil
    var onFlushed: ((Int) -> Void)? = nil
    /// 上次的位置：网页只在打开后的首次配置时用
    var restorePosition: FileEditorPositionStore.Position? = nil
    /// 滚动 / 选区变了（网页 250ms 防抖）
    var onPositionChange: ((FileEditorPositionStore.Position) -> Void)? = nil

    @State private var isReady = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            WebViewHost(
                htmlResourceName: "markdown-editor",
                payload: editorPayload,
                editorDocument: document.replacement,
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
            "type": "configure",
            "lineNumbers": showsLineNumbers,
            "active": isActive,
            // 网页底色透明（透出下面的 Theme.mainBg），字色跟主题走
            "colors": [
                "text": tokens.textPrimary.hexString,
                "muted": tokens.textMuted.hexString,
                "caret": FileEditorCaret.cssHex,
                "scheme": Theme.activeScheme == .dark ? "dark" : "light"
            ],
            "find": [
                "query": findQuery,
                "index": findIndex,
                "replace": replaceText
            ]
        ]
        if let restorePosition {
            payload["restore"] = [
                "anchor": restorePosition.anchor,
                "head": restorePosition.head,
                "top": restorePosition.top
            ]
        }
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
        case "documentChanged":
            guard message.raw["nativeRevision"] as? Int == document.replacement.nativeRevision,
                  let revision = message.revision, revision >= document.revision else { return }
            onPendingChange?()
        case "contentChanged":
            acceptSnapshot(message)
        case "requestSave":
            guard acceptSnapshot(message) else { return }
            onRequestSave?()
        case "flushed":
            acceptSnapshot(message)
            if let token = message.raw["token"] as? Int { onFlushed?(token) }
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
        case "position":
            if let anchor = message.raw["anchor"] as? Int, let head = message.raw["head"] as? Int, let top = message.raw["top"] as? Int {
                onPositionChange?(.init(anchor: anchor, head: head, top: top))
            }
        case "historyState":
            onHistoryChange?(message.raw["canUndo"] as? Bool ?? false, message.raw["canRedo"] as? Bool ?? false)
        default:
            break
        }
    }

    @discardableResult
    private func acceptSnapshot(_ message: WebViewBridgeMessage) -> Bool {
        guard let content = message.content, let revision = message.revision,
              let nativeRevision = message.raw["nativeRevision"] as? Int else { return false }
        var snapshot = document
        guard snapshot.receive(content: content, revision: revision, nativeRevision: nativeRevision) else { return false }
        document = snapshot
        onSnapshot?()
        return true
    }
}
