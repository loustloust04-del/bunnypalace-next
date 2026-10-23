import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
import SwiftStreamingMarkdown  // Phase 4 D11=b：.text 段切 fork，跟 SegmentedAssistantBody tail renderer 一致
#endif

/// segmented 正文显示加工（R9c-A N5，两端都修）：定稿 .text 段与流式尾巴（SegmentedAssistantBody
/// .renderSnapshot）调同一个正则——一个真相，别两处各写参数。气泡模式的 BubbleMarkdownSimplifier
/// 不在此列（SegmentedAssistantBody 只在文章模式用，尾巴不需要 simplifier；调用点各自叠加）。
enum SegmentDisplayText {
    static func apply(scripts: [RegexScript], to text: String, placement: Int = RegexPipeline.assistantPlacement) -> String {
        RegexPipeline.run(scripts, text: text, phase: .display, placement: placement)
    }
}

/// 按顺序渲染 Claude v2 导入的 [MessageSegment]。
/// - 每段独立折叠（思考 = DisclosureGroup；工具 = 可展开卡片）
/// - toolUse 后紧跟的同 id toolResult 会合并成一张卡片
/// - 样式沿用现有 Theme 调色盘（mainBg + textMuted），不引新色
struct MessageSegmentsView: View {
    let segments: [MessageSegment]
    let selectedFont: String
    let fontScale: Double
    let lineSpacingScale: Double
    let paragraphSpacingScale: Double
    let regexScripts: [RegexScript]
    /// user 气泡字体 / 对齐跟 assistant 不一样；text 段按此切换渲染。
    var isUser: Bool = false
    /// 附件一份存储：解 ref 段读盘需要（空串 = 解不了，降级占位卡）
    var profileId: String = ""
    /// 气泡模式：text 段渲染前抹平文档感 Markdown（标题/嵌套列表/分隔线）；文章模式默认 false 原样
    var simplifyMarkdown: Bool = false
    /// 聊天划线锚定的消息节点（iOS 正文浮条用；nil = 无划线子菜单）
    var nodeId: String? = nil
    /// 整条消息还在流式：卡片 / 外链卡等定稿（research-chat-cards §7.4）
    var isStreaming: Bool = false
    /// 浮条「引用」通道（聊天正文调用点传；nil = 浮条不出引用项）
    var onQuoteText: ((String) -> Void)? = nil
    /// 工具卡折叠行跟在工具名后面的一句摘要：(工具名, inputJSON) → 一行字。
    /// 编程会话详情页传（折叠着也要能扫出跑了什么命令）；聊天页不传 = 行为不变
    var toolSummary: ((String, String) -> String?)? = nil
    /// 只有 page1 主对话启用工具组；编程会话保留单工具卡。
    var toolNode: MessageNode? = nil
    var suppressTrailingError: Bool = false

    /// 外观 - 消息显示 - 「显示安全提示卡」开关。粟粟觉得 flag 卡丑可关掉。
    @AppStorage("showFlagBlocks") private var showFlagBlocks: Bool = true

    /// 当条消息里所有 search_web tool result 抽出来的 items——用于 markdown link 反查 `[citation](1:abc)`
    private var citationItems: [WebSearchResultItem] {
        WebSearchCitation.collectItems(from: segments)
    }

    /// 合并后的渲染条目
    fileprivate enum Item {
        case text(String)
        case thinking(String)
        case toolPair(id: String, name: String, inputJSON: String, resultText: String?, isError: Bool, integration: String?, icon: String?)
        case toolGroup([ChatToolStep])
        case orphanToolResult(text: String, isError: Bool, integration: String?)
        case flag(kind: String, helplineLine: String?, helplineUrl: String?)
        case attachment(name: String, type: String?, content: String?)
        case imageStrip(images: [(name: String, type: String?, data: Data)])
        case file(name: String)
    }

    private var items: [Item] {
        // ref 段先统一解成内联（读盘）；丢失文件降级 .attachment 占位卡
        let hydrated = self.segments.hydratedForDisplay(profileId: profileId)
        let visible = suppressTrailingError ? ChatSystemMessage.removingTrailingError(from: hydrated) : hydrated
        let segments = toolNode == nil ? visible : ChatToolTimeline.pairedSegments(visible)
        var result: [Item] = []
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            switch seg {
            case .text(let s):
                result.append(.text(s))
                i += 1
            case .thinking(let text, _):
                result.append(.thinking(text))
                i += 1
            case .toolUse(let id, let name, let inputJSON, let integration, let icon):
                // Peek next: 若紧邻的是匹配 id 的 toolResult → 配对
                if i + 1 < segments.count,
                   case let .toolResult(toolUseId, text, isError, resultIntegration) = segments[i + 1],
                   toolUseId == id {
                    result.append(.toolPair(
                        id: id,
                        name: name,
                        inputJSON: inputJSON,
                        resultText: text,
                        isError: isError,
                        integration: integration ?? resultIntegration,
                        icon: icon
                    ))
                    i += 2
                } else {
                    // 没有配对的 result（罕见；防御）
                    result.append(.toolPair(
                        id: id,
                        name: name,
                        inputJSON: inputJSON,
                        resultText: nil,
                        isError: false,
                        integration: integration,
                        icon: icon
                    ))
                    i += 1
                }
            case .toolResult(_, let text, let isError, let integration):
                // 没有配对的 toolUse 的孤儿 result（防御）
                result.append(.orphanToolResult(text: text, isError: isError, integration: integration))
                i += 1
            case .flag(let kind, let hName, let hPhone, let hUrl):
                var parts: [String] = []
                if let hName, !hName.isEmpty { parts.append(hName) }
                if let hPhone, !hPhone.isEmpty { parts.append(hPhone) }
                result.append(.flag(
                    kind: kind,
                    helplineLine: parts.isEmpty ? nil : parts.joined(separator: " · "),
                    helplineUrl: hUrl
                ))
                i += 1
            case .attachment(let name, let type, let extracted):
                result.append(.attachment(name: name, type: type, content: extracted))
                i += 1
            case .image(let name, let type, let data):
                var images: [(name: String, type: String?, data: Data)] = [(name, type, data)]
                i += 1
                while i < segments.count, case .image(let n, let t, let d) = segments[i] {
                    images.append((n, t, d))
                    i += 1
                }
                result.append(.imageStrip(images: images))
            case .file(let name, _):
                result.append(.file(name: name))
                i += 1
            case .fileData(let name, _, _):
                result.append(.file(name: name))   // C2：此 view 里当文件 chip 显示（主显示走 CardFlowView 卡片）
                i += 1
            case .imageRef, .fileDataRef:
                i += 1   // 不可达：顶部 hydratedForDisplay 已把 ref 解成内联/占位
            case .audioRef:
                i += 1   // 语音条在气泡外侧 BubbleAttachmentStrip 渲染，此处跳过
            }
        }
        guard toolNode != nil else { return result }
        var grouped: [Item] = []
        for item in result {
            if case let .toolPair(id, name, inputJSON, resultText, isError, integration, icon) = item {
                if name == AskUserTool.toolName && !isError { continue }
                let step = ChatToolStep(id: id, name: name, inputJSON: inputJSON, result: resultText,
                                        isError: isError, integration: integration, icon: icon)
                if case .toolGroup(let previous)? = grouped.last {
                    grouped[grouped.count - 1] = .toolGroup(previous + [step])
                } else { grouped.append(.toolGroup([step])) }
            } else { grouped.append(item) }
        }
        return grouped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let resolved = items
            ForEach(resolved.indices, id: \.self) { idx in
                itemView(resolved[idx])
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: Item) -> some View {
        switch item {
        case .text(let s):
            let regexed = SegmentDisplayText.apply(scripts: regexScripts, to: s,
                                                   placement: isUser ? RegexPipeline.userPlacement : RegexPipeline.assistantPlacement)
            let applied = simplifyMarkdown ? BubbleMarkdownSimplifier.simplify(regexed) : regexed
            if !applied.isEmpty {
                // Phase 4 D11=b：iOS .text 段切 fork，跟 SegmentedAssistantBody 末尾 tail renderer 一致
                // user 跟 assistant 都走，跟现状一致（baseline 一致原因）
                // R2-4b：ChatMarkdownView = MarkdownView + 划词收生词浮条（5 个正文调用点统一走它）
                ChatMarkdownView(
                    text: MessageHTMLSegments.markdownPromotingHTML(applied),   // 卡库 ⑦：明确 HTML 交给网页卡
                    fontName: selectedFont,
                    scale: CGFloat(fontScale > 0 ? fontScale : 1.0),
                    nodeId: nodeId,
                    profileId: profileId,
                    onQuote: onQuoteText,
                    // M1 三格：用户消息带复杂段（工具/附件混排）时正文走这条路，
                    // 不接就会漏回主文字。`isUser` 原来只有声明零使用点，正是给这儿的。
                    role: isUser ? .user : .assistant
                )
                .chatCardRenderer(nodeId: nodeId, streaming: isStreaming)
                .environment(\.openURL, OpenURLAction { url in
                    // assistant 才需要 citation 反查；user 不参与（items 应为空）
                    let items = citationItems
                    guard !items.isEmpty else { return .systemAction }
                    if let real = WebSearchCitation.resolve(linkURL: url.absoluteString, items: items),
                       let realURL = URL(string: real) {
                        return .systemAction(realURL)
                    }
                    return .systemAction
                })
            }
        case .thinking(let s):
            ThinkingBlockView(text: s, nodeId: nodeId, profileId: profileId)
        case .toolGroup(let steps):
            if let toolNode {
                ChatToolGroupView(node: toolNode, steps: steps, isStreaming: isStreaming)
                if !profileId.isEmpty {
                    ForEach(steps) { step in
                        if let card = DeviceToolCard.parse(step.result) {
                            DeviceToolCardView(card: card, profileId: profileId)
                        }
                    }
                }
            }
        case .toolPair(_, let name, let inputJSON, let resultText, let isError, let integration, let icon):
            if name == AskUserTool.toolName && !isError {
                // 问问题不在 assistant 流里渲染：等待中卡片在底部 sheet，已答的 Q/A 是
                // 紧随其后的真实 user 消息节点（100% 复用用户气泡）。segments 只留 API 痕迹。
                // 参数无效的 error 配对仍走工具卡。
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ToolCallCardView(
                        name: name,
                        inputJSON: inputJSON,
                        resultText: resultText,
                        isError: isError,
                        integration: integration,
                        icon: icon,
                        profileId: profileId,
                        summary: toolSummary?(name, inputJSON)
                    )
                    // 设备工具产生系统实体时额外出一张结果卡（plan-设备工具 §-0.5）；
                    // 折叠行仍保留——它是「过程」，卡片是「结果」，点开折叠行还能看原始 JSON。
                    // profileId 为空的调用点（编程会话）不出：这张卡渲染期就会拿 profileId 去文件库读缩略图（R-CD #5）
                    if !profileId.isEmpty, let card = DeviceToolCard.parse(resultText) {
                        DeviceToolCardView(card: card, profileId: profileId)
                    }
                }
            }
        case .orphanToolResult(let text, let isError, let integration):
            ToolCallCardView(
                name: isError ? "tool 结果（失败）" : "tool 结果",
                inputJSON: "",
                resultText: text,
                isError: isError,
                integration: integration,
                profileId: profileId
            )
        case .flag(let kind, let helplineLine, let helplineUrl):
            if showFlagBlocks {
                FlagCardView(kind: kind, helplineLine: helplineLine, helplineUrl: helplineUrl)
            }
        case .attachment(let name, let type, let content):
            AttachmentCardView(name: name, type: type, extractedContent: content)
        case .imageStrip:
            EmptyView()
        case .file(let name):
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                Text(name.isEmpty ? "(图片)" : name)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }
}

// 模块级共用（头像裁剪/缓存也用）
#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

// MARK: - Thinking Block

/// 原本用 `DisclosureGroup("思考")` —— macOS 下嵌在 LazyVStack + 自定义 bubble
/// background 里有时吃点击（实测粟粟反馈"思考都点不开"）。Button + @State 结构
/// 命中区域扩到整行保证可点——现统一收进 ThinkingDisclosure（含「思考过程弹出显示」分流）。
private struct ThinkingBlockView: View {
    let text: String
    var nodeId: String? = nil
    var profileId: String = ""

    var body: some View {
        ThinkingDisclosure(label: "思考", text: text, nodeId: nodeId, profileId: profileId)
    }
}

// MARK: - Tool Call Card

struct ToolCallCardView: View {
    let name: String
    let inputJSON: String
    let resultText: String?
    let isError: Bool
    let integration: String?
    /// 循环给每个工具存的 SF Symbol（globe / terminal / lock…）；没有的（老消息、fs_*）还是 🔧（进度卡顺手修，粟粟 10-03）
    let icon: String?
    let profileId: String
    /// 折叠行里跟在工具名后面的一句（编程会话传 `cd /Users/…`；聊天页 nil）
    let summary: String?
    var forceDetail: Bool = false

    @AppStorage(DisclosureKind.tool.key) private var modeRaw = DisclosureKind.tool.migratedDefault.rawValue
    @State private var isExpanded: Bool
    @State private var showSheet = false
    @State private var fullResult: (path: String, text: String, truncated: Bool)?

    private var mode: DisclosureMode { DisclosureMode(rawValue: modeRaw) ?? .inline }
    private var displayName: String { name.isEmpty ? "(未命名 tool)" : name }

    /// B4 D2b：结果被外置（尾注里有 tool-results/ 路径）或 fs_read 被头截（原文件路径在 input 里）时，可打开全文
    private var fullResultPath: String? {
        // 打开全文要读那个楼层的文件库；profileId 为空的调用点（编程会话）整个不给这条路（R-CD #5）
        guard !profileId.isEmpty else { return nil }
        if let p = ToolResultOffload.embeddedPath(in: resultText) { return p }
        guard name == FileLibraryTools.Name.read.rawValue, resultText?.contains("[已截断：") == true,
              let args = try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any],
              let path = args["path"] as? String, !path.isEmpty else { return nil }
        return path
    }

    private func openFullResult() {
        guard let path = fullResultPath else { return }
        let r = (try? FileLibraryStore.readAny(path, profileId: profileId, maxBytes: 1_048_576)) ?? (text: "（读取失败）", truncated: false)
        fullResult = (path, r.text, r.truncated)
    }

    init(name: String, inputJSON: String, resultText: String?, isError: Bool, integration: String?,
         icon: String? = nil, profileId: String, summary: String? = nil, forceDetail: Bool = false) {
        self.forceDetail = forceDetail
        self.icon = icon
        self.name = name
        self.inputJSON = inputJSON
        self.resultText = resultText
        self.isError = isError
        self.integration = integration
        self.profileId = profileId
        self.summary = summary
        // run_command 跑完直接展开看输出，不用再点一下（plan-离线沙箱-phase1 §1.5）；只对原地档有意义
        _isExpanded = State(initialValue: name == "run_command")
    }

    /// run_command 结果拆成可读三段（命令 / stdout / stderr），其余工具维持原始 JSON。
    private var shellView: (command: String, stdout: String, stderr: String, exit: Int?)? {
        guard name == "run_command", let r = resultText,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any],
              let data = obj["data"] as? [String: Any] else { return nil }
        let cmd = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any])?["command"] as? String ?? ""
        return (cmd, data["stdout"] as? String ?? "", data["stderr"] as? String ?? "", data["exit_code"] as? Int)
    }

    var body: some View {
        // 隐藏档：整卡不出（设备结果卡由父层另出，它是"结果"不是"过程"）
        if mode != .hidden || forceDetail { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !forceDetail {
            Button {
                // 反转列表里展开动画 vs 同帧钉住（CellGrowthAnchor）必错一帧，不做动画（plan-stream-follow-controller §三.7）
                if mode == .sheet { showSheet = true } else { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if let icon, !icon.isEmpty {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 14)
                    } else {
                        Image(systemName: "wrench.and.screwdriver").font(.system(size: 11))
                    }
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    if let integration, !integration.isEmpty {
                        Text("· \(integration)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                    if isError {
                        Text("· 失败")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.8))
                    }
                    // 折叠着也要能扫出跑了什么（编程会话）；排在「失败」之后，长了自己截，不挤掉前面的字
                    if let summary, !summary.isEmpty {
                        Text("· \(summary)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded && mode == .inline ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .buttonStyle(.plain)
            }

            if (isExpanded && mode == .inline) || forceDetail {
                if let sh = shellView {
                    shellBody(sh, monoSize: forceDetail ? 12 : 10)
                } else {
                    ToolCallDetail(inputJSON: inputJSON, resultText: resultText, truncateResult: !forceDetail, showCopy: forceDetail, monoSize: forceDetail ? 12 : 10)
                }
                openFullButton(size: 10)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.mainBg.opacity(0.5))
        )
        .sheet(isPresented: $showSheet) {
            DisclosureSheet(title: displayName) {
                if let sh = shellView {
                    shellBody(sh, monoSize: 12)
                } else {
                    ToolCallDetail(inputJSON: inputJSON, resultText: resultText, truncateResult: false, showCopy: true, monoSize: 12)
                }
                openFullButton(size: 12)
            }
        }
        .sheet(isPresented: Binding(get: { fullResult != nil }, set: { if !$0 { fullResult = nil } })) {
            if let full = fullResult {
                DisclosureSheet(title: (full.path as NSString).lastPathComponent) {
                    VStack(alignment: .leading, spacing: 6) {
                        if full.truncated {
                            Text("文件过大，只显示前 1MB").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                        }
                        Text(full.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func openFullButton(size: CGFloat) -> some View {
        if fullResultPath != nil {
            Button("打开完整结果") { openFullResult() }
                .font(.system(size: size))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
        }
    }

    /// run_command 展开体（原地 / sheet 共用）：`$ 命令` / stdout / stderr / exit，等宽 + 横向滚动（ls -l 对齐不被折行毁掉）
    private func shellBody(_ sh: (command: String, stdout: String, stderr: String, exit: Int?), monoSize: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
            VStack(alignment: .leading, spacing: 4) {
                Text("$ " + sh.command)
                    .foregroundColor(Theme.textPrimary)
                if !sh.stdout.isEmpty {
                    Text(sh.stdout.trimmingCharacters(in: .newlines))
                        .foregroundColor(Theme.textMuted)
                }
                if !sh.stderr.isEmpty {
                    Text(sh.stderr.trimmingCharacters(in: .newlines))
                        .foregroundColor(Theme.branchIndicator)
                }
                if let code = sh.exit, code != 0 {
                    Text("exit \(code)").foregroundColor(Theme.textMuted.opacity(0.8))
                }
            }
            .font(.system(size: monoSize, design: .monospaced))
            .textSelection(.enabled)
            .padding(.top, 2)
        }
    }
}

/// 工具卡展开体（原地和 sheet 共用）：input JSON + 结果；原地 >2000 字再折，sheet 全量 + 复制
private struct ToolCallDetail: View {
    let inputJSON: String
    let resultText: String?
    let truncateResult: Bool
    var showCopy: Bool = false
    /// 原地 10；sheet 里 12
    var monoSize: CGFloat = 10

    @State private var resultExpanded = false
    private let resultTruncate = 2000

    private var hasInput: Bool { !inputJSON.isEmpty && inputJSON != "{}" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasInput {
                Text(inputJSON)
                    .font(.system(size: monoSize, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let r = resultText, !r.isEmpty {
                if hasInput {
                    Divider().padding(.vertical, 2)
                }
                let shown = (truncateResult && !resultExpanded) ? String(r.prefix(resultTruncate)) : r
                Text(shown)
                    .font(.system(size: monoSize, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if truncateResult, r.count > resultTruncate {
                    Button(resultExpanded ? "收起结果" : "展开全部（共 \(r.count) 字）") {
                        resultExpanded.toggle()
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.branchIndicator)
                    .buttonStyle(.plain)
                }
            }
            if showCopy {
                Button("复制") {
                    let text = [hasInput ? inputJSON : nil, resultText].compactMap { $0 }.joined(separator: "\n\n")
                    #if os(iOS)
                    UIPasteboard.general.string = text
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #endif
                }
                .font(.system(size: 12))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Flag Card

private struct FlagCardView: View {
    let kind: String
    let helplineLine: String?
    let helplineUrl: String?

    var body: some View {
        VStack(spacing: 6) {
            ChatSystemCapsule(text: "flag: \(kind)" + (helplineLine.map { " · " + $0 } ?? ""),
                              symbol: "exclamationmark.triangle")
            if let url = helplineUrl, let link = URL(string: url) {
                Link(url, destination: link)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.branchIndicator)
            }
        }
    }
}

// MARK: - Attachment Card

private struct AttachmentCardView: View {
    let name: String
    let type: String?
    let extractedContent: String?

    @State private var isExpanded = false
    private let previewTruncate = 2000

    private var hasContent: Bool {
        (extractedContent?.isEmpty == false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if hasContent {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 11))
                    Text(name.isEmpty ? "(附件)" : name)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                    if let t = type, !t.isEmpty {
                        Text("· \(t)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                    }
                    Spacer()
                    if hasContent {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)

            if isExpanded, let ex = extractedContent, !ex.isEmpty {
                let shown = ex.count > previewTruncate ? String(ex.prefix(previewTruncate)) + "\n...（已截断）" : ex
                Text(shown)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.mainBg.opacity(0.5))
        )
    }
}
