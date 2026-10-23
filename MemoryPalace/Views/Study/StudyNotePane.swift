import SwiftUI
import SwiftData
import SwiftStreamingMarkdown

/// 学堂课堂状态下的 HTML 笔记（plan-study-zero-engine §4.11）：读文件库里这门课的笔记，模型写文件后收
/// `.fileLibraryDidChange` 重读，内容变了才换；换了就跳到刚改的地方（P15 V2）。只包一层 HTMLPreviewWebView。
/// 文件库里没有笔记（Claude Code 课 / 不能写文件的卡）→ 显示这段对话最新一个 ```html 代码块（P5 S1）。
struct StudyNotePane: View {
    let notePath: String?
    let conversationId: String
    let profileId: String
    let toolsAvailable: Bool
    let isClaudeCode: Bool
    let refreshKey: RefreshKey

    /// 变了就重读聊天里的 html 块。CC 回复走 proactive 落地（改 updateTime、不发 assistantTurnDidFinish）；
    /// stream 传输先落一条空占位、正文靠 edit 帧改 node.content（不动 updateTime），所以还要看眼前末条的长度
    struct RefreshKey: Equatable {
        var updated: Date
        var tailId: String?
        var tailLength: Int
    }

    @Environment(\.modelContext) private var modelContext
    @State private var content: String?
    @State private var rendered = ""

    var body: some View {
        Group {
            if content == nil {
                placeholder(placeholderText)
            } else {
                HTMLPreviewWebView(content: rendered)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: notePath) { _, _ in reset() }
        .onChange(of: conversationId) { _, _ in reset() }
        .onChange(of: refreshKey) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .fileLibraryDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .assistantTurnDidFinish)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            content = nil
            rendered = ""
        }
    }

    private var placeholderText: String {
        if isClaudeCode { return "Claude Code 会在每一圈结束时把课堂笔记发在聊天里" }
        if notePath == nil { return "这段对话没有约定的笔记位置，可以在文件库的「\(StudyTemplate.noteRoot)」目录里找" }
        return toolsAvailable ? "第零圈结束后，课堂笔记会出现在这里" : "这张卡不能写文件，笔记在对话里的网页卡中"
    }

    private func reset() {
        content = nil
        rendered = ""
        reload()
    }

    private func placeholder(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 26))
                .foregroundColor(Theme.textMuted.opacity(0.6))
            Text(text)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        let fileText = notePath.flatMap { try? FileLibraryStore.read($0, profileId: profileId) }
        guard let text = fileText ?? latestChatHTML() else {
            content = nil
            return
        }
        guard text != content else { return }
        let previous = content
        content = text
        if let previous, let anchor = Self.changedAnchor(old: previous, new: text) {
            rendered = text + Self.revealScript(anchor)
        } else {
            rendered = text
        }
    }

    /// 刚改的地方：改动区里的第一个 id；改动区里没有就取改动前最近的一个
    static func changedAnchor(old: String, new: String) -> String? {
        let a = Array(old.utf8)
        let b = Array(new.utf8)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let changed = String(decoding: b[prefix..<(b.count - suffix)], as: UTF8.self)
        if let id = ids(in: changed).first { return id }
        return ids(in: String(decoding: b[..<prefix], as: UTF8.self)).last
    }

    private static func ids(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\sid="([^"]+)""#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func revealScript(_ id: String) -> String {
        let literal = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """

        <script>(function(){var e=document.getElementById("\(literal)");if(!e)return;var d=e.closest("details");while(d){d.open=true;d=d.parentElement?d.parentElement.closest("details"):null;}e.scrollIntoView({block:"center"});})();</script>
        """
    }

    /// 这段对话最近 20 条 assistant 里最新的 ```html 代码块（绝不全量 fetch MessageNode）
    private func latestChatHTML() -> String? {
        let cid = conversationId
        let pid = profileId
        var descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> {
                $0.conversationId == cid && $0.profileId == pid && $0.role == "assistant"
            },
            sortBy: [SortDescriptor(\.createTime, order: .reverse)]
        )
        descriptor.fetchLimit = 20
        let nodes = (try? modelContext.fetch(descriptor)) ?? []
        return nodes.lazy.compactMap { Self.lastHTMLBlock(in: $0.content) }.first
    }

    /// 一段正文里最后一个写完（已闭合）的 ```html 围栏块的内容；围栏识别同 ChatCardExtractor
    static func lastHTMLBlock(in text: String) -> String? {
        guard text.contains("```") || text.contains("~~~") else { return nil }
        var last: String?
        var open: (char: Character, count: Int, isHTML: Bool)?
        var body: [String] = []
        for line in MarkdownFenceNormalizer.normalize(text).components(separatedBy: "\n") {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let run = MarkdownFenceTracker.fenceRun(trimmed)
            if let current = open {
                if let run, run.char == current.char, run.count >= current.count,
                   trimmed.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    let code = body.joined(separator: "\n")
                    if current.isHTML, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { last = code }
                    open = nil
                    body = []
                } else {
                    body.append(line)
                }
            } else if let run {
                let info = trimmed.dropFirst(run.count)
                if run.char == "`", info.contains("`") { continue }
                let language = info.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                open = (run.char, run.count, language.lowercased() == "html")
            }
        }
        return last
    }

    /// N1：这段对话第一条 user 消息里的「（课堂笔记：…）」。只取一条 node
    static func notePath(conversationId: String, profileId: String, context: ModelContext) -> String? {
        var descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> {
                $0.conversationId == conversationId && $0.profileId == profileId && $0.role == "user"
            },
            sortBy: [SortDescriptor(\.createTime)]
        )
        descriptor.fetchLimit = 1
        guard let first = try? context.fetch(descriptor).first else { return nil }
        return StudyTemplate.notePath(fromFirstMessage: first.content)
    }
}
