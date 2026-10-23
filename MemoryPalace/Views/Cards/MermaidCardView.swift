import SwiftUI
import WebKit
import SwiftStreamingMarkdown
#if os(iOS)
import UIKit
import Photos
#else
import AppKit
import UniformTypeIdentifiers
#endif

/// ```mermaid 图表卡（plan-mermaid §1）：缓存图 / 渲染中 / 出错三态；点图全屏看矢量；长按（mac 右键）复制源码 / 存图片 / 存文件库。
struct MermaidCardView: View {
    let code: String
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var result: Keyed?
    @State private var retry = 0
    @State private var showFull = false
    @State private var showSource = false
    @State private var notice: Notice?

    static let maxCardHeight: CGFloat = 360
    /// 卡片里最小显示比例：宽图缩到这以下字就看不清了
    static let minScale: CGFloat = 0.6

    private struct Keyed: Equatable {
        let key: String
        let outcome: MermaidRenderer.Outcome
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        // 读 ThemeManager：换主题 → 键变 → 重画
        let request = MermaidRenderer.request(code: code)
        let outcome = result?.key == request.key ? result?.outcome : MermaidRenderer.shared.immediateOutcome(for: request)
        VStack(alignment: .leading, spacing: 0) {
            content(outcome, key: request.key)
            MintHairline()
            HStack {
                Text("图表 · \(Self.typeName(svgType: Self.rendered(outcome)?.type, code: code))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(CodeBlockStyle.label)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .mintCard()
        .contextMenu { menu(outcome) }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFull) { fullScreen(outcome, background: request.background) }
        #else
        .sheet(isPresented: $showFull) { fullScreen(outcome, background: request.background) }
        #endif
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好")))
        }
        .task(id: "\(request.key)#\(retry)") {
            guard MermaidRenderer.shared.immediateOutcome(for: request) == nil else { return }
            let key = request.key
            MermaidRenderer.shared.render(request) { outcome in
                result = Keyed(key: key, outcome: outcome)
            }
        }
    }

    // MARK: - 三态

    @ViewBuilder private func content(_ outcome: MermaidRenderer.Outcome?, key: String) -> some View {
        switch outcome {
        case .rendered(let rendered)?:
            if let entry = MermaidImageCache.entry(at: rendered.png) {
                diagram(entry)
            } else {
                // 缓存文件被系统清掉：忘掉旧结果重画
                rendering.onAppear {
                    MermaidRenderer.shared.forget(key: key)
                    result = nil
                    retry += 1
                }
            }
        case .invalid(let message)?:
            problem(title: "图表有误", message: message, canRetry: false)
        case .failed(let message)?:
            problem(title: message == "图表太大" ? "图表太大" : "图表渲染失败",
                    message: message == "图表太大" ? "源码超过 50KB，只显示源码" : message,
                    canRetry: message != "图表太大")
        case nil:
            rendering
        }
    }

    /// 图按卡宽等比缩（不放大），最小 0.6 倍：再缩就读不了，改为按 0.6 倍从左边裁切 + 右缘渐隐 + 「点开看全图」。
    /// 不做横向滚动（聊天页本身在横向翻页器里，会抢手势）。卡宽由 Layout 的 proposal 拿，不用几何读数（LazyVStack 里不可靠）
    private func diagram(_ entry: MermaidImageCache.Entry) -> some View {
        let layout = MermaidDiagramLayout(natural: entry.pointSize, maxHeight: Self.maxCardHeight, minScale: Self.minScale)
        return layout {
            entry.swiftUIImage
                .resizable()
                .interpolation(.high)
            LinearGradient(colors: [Theme.mainBg.opacity(0), Theme.mainBg], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [Theme.mainBg.opacity(0), Theme.mainBg], startPoint: .top, endPoint: .bottom)
            Text("点开看全图")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(CodeBlockStyle.label)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(CodeBlockStyle.body.opacity(0.92)))
                .overlay(Capsule().strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
                .fixedSize()
        }
        .clipped()
        .background(Theme.mainBg)
        .contentShape(Rectangle())
        .onTapGesture { showFull = true }
    }

    private var rendering: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("图表生成中…").foregroundStyle(CodeBlockStyle.label)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
    }

    private func problem(title: String, message: String, canRetry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CodeBlockStyle.label)
                Spacer()
                if canRetry {
                    Button("重试") {
                        result = nil
                        retry += 1
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(CodeBlockStyle.label)
                }
            }
            Text(Self.firstLines(message))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(CodeBlockStyle.label)
                .lineLimit(3)
                .textSelection(.enabled)
            DisclosureGroup(isExpanded: $showSource) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 4)
                }
            } label: {
                Text("源码").font(.system(size: 12)).foregroundStyle(CodeBlockStyle.label)
            }
            .tint(CodeBlockStyle.label)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .light)      // 米白卡底固定浅色（同 ChatCardShell）
    }

    // MARK: - 菜单

    @ViewBuilder private func menu(_ outcome: MermaidRenderer.Outcome?) -> some View {
        Button {
            PlatformClipboard.copyString(code)
        } label: {
            Label("复制源码", systemImage: "doc.on.doc")
        }
        if let rendered = Self.rendered(outcome) {
            Button {
                saveImage(rendered)
            } label: {
                #if os(iOS)
                Label("存图片", systemImage: "photo")
                #else
                Label("存图片到下载", systemImage: "photo")
                #endif
            }
        }
        Button {
            if let path = saveMermaidToLibrary(code: code, profileId: profileId) {
                notice = Notice(title: "已保存到文件库", message: path)
            } else {
                notice = Notice(title: "保存失败", message: "没能写进文件库")
            }
        } label: {
            Label("保存到文件库", systemImage: "folder")
        }
    }

    private func saveImage(_ rendered: MermaidRenderer.Rendered) {
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: rendered.png.path) else { return }
        // 带 completion：权限被拒 / 失败不弹假成功（同 AttachmentPreviewSheet.saveToPhotos）
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { success, error in
            DispatchQueue.main.async {
                notice = success
                    ? Notice(title: "已存到相册", message: "")
                    : Notice(title: "保存失败", message: error?.localizedDescription ?? "检查相册权限")
            }
        }
        #else
        let source = rendered.png
        // 延迟一帧，等右键菜单关掉再弹 NSSavePanel（同 StickerViewModel.saveToFiles）
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "图表.png"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? FileManager.default.removeItem(at: url)
            if (try? FileManager.default.copyItem(at: source, to: url)) == nil {
                notice = Notice(title: "保存失败", message: url.path)
            }
        }
        #endif
    }

    @ViewBuilder private func fullScreen(_ outcome: MermaidRenderer.Outcome?, background: String) -> some View {
        if let rendered = Self.rendered(outcome) {
            MermaidFullScreenView(code: code, svgURL: rendered.svg, background: background)
        }
    }

    // MARK: - 工具

    private static func rendered(_ outcome: MermaidRenderer.Outcome?) -> MermaidRenderer.Rendered? {
        if case .rendered(let rendered)? = outcome { return rendered }
        return nil
    }

    private static func firstLines(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: true).prefix(3).joined(separator: "\n")
    }

    /// 卡片底栏类型名：先看 SVG 根的 aria-roledescription，没有再看代码首个关键词
    static func typeName(svgType: String?, code: String) -> String {
        let role = (svgType ?? "").lowercased()
        if !role.isEmpty, let name = name(for: role) { return name }
        return name(for: firstKeyword(code)) ?? "图表"
    }

    private static func name(for keyword: String) -> String? {
        let k = keyword.lowercased()
        if k.hasPrefix("flowchart") || k == "graph" { return "流程图" }
        if k.hasPrefix("sequence") { return "时序图" }
        if k.hasPrefix("class") { return "类图" }
        if k.hasPrefix("state") { return "状态图" }
        if k == "gantt" { return "甘特图" }
        if k == "pie" { return "饼图" }
        if k == "mindmap" { return "思维导图" }
        return nil
    }

    /// 跳过 --- 前言块和 %% 注释后的第一个词
    static func firstKeyword(_ code: String) -> String {
        var inFrontMatter = false
        var seenLine = false
        for raw in code.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !seenLine && line == "---" { inFrontMatter = true; seenLine = true; continue }
            seenLine = true
            if inFrontMatter { if line == "---" { inFrontMatter = false }; continue }
            if line.hasPrefix("%%") { continue }
            return String(line.prefix { !$0.isWhitespace && $0 != ";" && $0 != ":" })
        }
        return ""
    }
}

/// 图表卡的图区排版。子视图顺序固定：0 图、1 右缘渐隐、2 底缘渐隐、3「点开看全图」。
/// 缩放 = min(1, 卡宽 / 自然宽)，但不低于 minScale；低于时按 minScale 靠左摆、右边裁掉（外面 clipped）。
/// 用不上的渐隐 / 标签摆到可见区外，被外层裁掉。
struct MermaidDiagramLayout: Layout {
    let natural: CGSize
    let maxHeight: CGFloat
    let minScale: CGFloat

    private struct Metrics {
        let width: CGFloat
        let height: CGFloat
        let shown: CGSize
        let overflowX: Bool
        let overflowY: Bool
    }

    private func metrics(for proposal: ProposedViewSize) -> Metrics {
        let naturalWidth = max(natural.width, 1)
        var width = proposal.width ?? naturalWidth
        if !width.isFinite { width = naturalWidth }
        let scale = max(min(1, width / naturalWidth), minScale)
        let shown = CGSize(width: naturalWidth * scale, height: natural.height * scale)
        return Metrics(width: width, height: min(shown.height, maxHeight), shown: shown,
                       overflowX: shown.width > width + 0.5, overflowY: shown.height > maxHeight + 0.5)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = metrics(for: proposal)
        return CGSize(width: m.width, height: m.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = metrics(for: ProposedViewSize(width: bounds.width, height: bounds.height))
        let hidden = CGPoint(x: bounds.minX - 10_000, y: bounds.minY)
        if subviews.count > 0 {
            let x = m.overflowX ? bounds.minX : bounds.midX - m.shown.width / 2
            subviews[0].place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(m.shown))
        }
        if subviews.count > 1 {
            let fade = CGSize(width: 40, height: m.height)
            subviews[1].place(at: m.overflowX ? CGPoint(x: bounds.maxX - fade.width, y: bounds.minY) : hidden,
                              proposal: ProposedViewSize(fade))
        }
        if subviews.count > 2 {
            let fade = CGSize(width: m.width, height: 48)
            subviews[2].place(at: m.overflowY ? CGPoint(x: bounds.minX, y: bounds.maxY - fade.height) : hidden,
                              proposal: ProposedViewSize(fade))
        }
        if subviews.count > 3 {
            let size = subviews[3].sizeThatFits(.unspecified)
            subviews[3].place(at: m.overflowX ? CGPoint(x: bounds.maxX - size.width - 8, y: bounds.maxY - size.height - 8) : hidden,
                              proposal: ProposedViewSize(size))
        }
    }
}

/// 图表 → 文件库 artifacts/ 下的 .md（内容 = 围栏块本身）。返回相对路径（nil = profileId 空或写失败）。
/// 同 saveArtifactToLibrary（那个写死 .html）。
func saveMermaidToLibrary(code: String, profileId: String) -> String? {
    guard !profileId.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let base = "图表-" + formatter.string(from: Date())
    var candidate = "artifacts/\(base).md"
    var index = 2
    while FileLibraryStore.exists(candidate, profileId: profileId) {
        candidate = "artifacts/\(base)-\(index).md"
        index += 1
    }
    let fence = code.contains("```") ? "~~~~" : "```"
    let content = "\(fence)mermaid\n\(code)\n\(fence)\n"
    guard (try? FileLibraryStore.write(candidate, content: content, profileId: profileId)) != nil else { return nil }
    NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
    return candidate
}

/// 卡片图片解码缓存（body 每次求值都要用，别每次读盘解码）
@MainActor
enum MermaidImageCache {
    final class Entry {
        #if os(iOS)
        let image: UIImage
        #else
        let image: NSImage
        #endif
        /// 截图按 2× 像素出，点尺寸 = 像素 / 2
        let pointSize: CGSize

        #if os(iOS)
        init(image: UIImage, pointSize: CGSize) { self.image = image; self.pointSize = pointSize }
        var swiftUIImage: Image { Image(uiImage: image) }
        #else
        init(image: NSImage, pointSize: CGSize) { self.image = image; self.pointSize = pointSize }
        var swiftUIImage: Image { Image(nsImage: image) }
        #endif
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 40
        return cache
    }()

    static func entry(at url: URL) -> Entry? {
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else { return nil }
        let pixels = CGSize(width: cg.width, height: cg.height)
        #else
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first,
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        #endif
        let entry = Entry(image: image, pointSize: CGSize(width: pixels.width / 2, height: pixels.height / 2))
        cache.setObject(entry, forKey: url.path as NSString)
        return entry
    }
}
