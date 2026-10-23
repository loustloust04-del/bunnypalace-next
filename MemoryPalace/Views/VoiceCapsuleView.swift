import SwiftUI
import SwiftData
import SwiftStreamingMarkdown
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 语音条（research-chat-cards §11，照 HTML 小样 https://claude.ai/artifact/4Sy83skxbVpNnG2Vn4DpqG）：
/// 一个胶囊——圆形播放键（原地变形成暂停）+ 声纹（柱数随时长、按文件本身的响度）+ 时长（播放 / 暂停时倒计时）。
/// 播放时声纹从左往右填满、播放头附近跟着声音弹。文章模式自带胶囊底（你的 = 你的气泡色，模型的 = 卡片米白 + 薄荷边，固定浅色配色）；
/// 气泡模式内嵌在气泡壳里。长按「换一版」（她自己发的语音条：「复制文字」，plan-voice-note M7）。tap 用 onTapGesture（横向滚动区 Button 会被手势吞的教训）。
/// 声纹读出来之前是低矮平柱，读完第一次出现时 0.8 秒从左往右长出来；播放进度按根插值颜色（能停在半根上）。
struct VoiceCapsuleView: View {
    let path: String          // audioRef 相对路径 = 播放 id
    let duration: Double?
    let nodeId: String
    let profileId: String
    let isUser: Bool
    /// 气泡模式内嵌：外层已是气泡壳（BubbleTailShape），去掉自带胶囊底 / 描边
    var embedded: Bool = false
    /// 她的语音条：转写（「复制文字」用）；AI 的不传
    var script: String? = nil
    /// 自带长按菜单。外面已包了消息长按菜单（她的纯语音条 / 气泡模式）就关掉，免得两个长按抢
    var ownMenu: Bool = true
    /// 「分享」文件名用：说话人（调用处传显示名）和这条消息的时间
    var speaker: String = ""
    var createTime: Date? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bars: [Double]?
    /// 「长出来」开始时刻；nil = 不在长（TimelineView 只在长 / 播放时跑）
    @State private var growStart: Date?
    /// 本次启动已长过的条（按 path）：滚回来不再长第二遍
    @MainActor private static var grownPaths = Set<String>()

    private var player: VoiceMessagePlayer { .shared }
    private var url: URL? { FileLibraryStore.absoluteURL(path, profileId: profileId) }
    private var state: VoiceMessagePlayer.State { player.state(for: path) }
    private var barCount: Int { VoiceWave.barCount(duration: duration) }
    private var ink: Color { Color.primary.opacity(0.88) }

    var body: some View {
        // iOS 不挂系统 .contextMenu：反转列表里 lift 快照带着翻转矩阵插值，长按一压就缩成一条线
        // （docs/research-contextmenu-flipped-list.md）。走消息气泡同款浮层，mac 照旧 .contextMenu
        let specs = ownMenu ? Self.menuSpecs(isUser: isUser, nodeId: nodeId, path: path, profileId: profileId, script: script,
                                             speaker: speaker, date: createTime, context: modelContext) : []
        if !specs.isEmpty {
            BubbleMenuLiftWrapper(isUser: isUser, cornerRadius: 22, actions: specs) { capsule }
            #if os(macOS)
                .contextMenu { MenuActionSpec.menuItems(from: specs) }
            #endif
        } else {
            capsule
        }
    }

    /// 语音条自己的长按菜单：AI 的「换一版」/ 她的「复制文字」（有转写才有），后面都跟「分享」。
    /// 气泡模式 AI 语音条由气泡壳那层挂（浮层预览带壳带尾巴），所以是 static
    static func menuSpecs(isUser: Bool, nodeId: String, path: String, profileId: String, script: String?,
                          speaker: String, date: Date?, context: ModelContext) -> [MenuActionSpec] {
        var specs: [MenuActionSpec] = []
        if !isUser {
            specs.append(MenuActionSpec(title: "换一版", systemImage: "arrow.triangle.2.circlepath") {
                VoiceMessageWriter.regenerate(nodeId: nodeId, context: context)
            })
        }
        if isUser, let script, !script.isEmpty {
            specs.append(MenuActionSpec(title: "复制文字", systemImage: "doc.on.doc") { copy(script) })
        }
        specs.append(VoiceNoteShare.spec(path: path, profileId: profileId, speaker: speaker, date: date))
        return specs
    }

    @ViewBuilder
    private var capsule: some View {
        let state = self.state
        let fileURL = url                                        // 只查一次文件（不在每帧 / 每根柱里查，终审 I-1）
        let hasFile = fileURL != nil
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(hasFile ? ink : ink.opacity(0.2))
                PlayPauseShape(morph: state == .playing ? 1 : 0)
                    .fill(.background)                           // 与墨色圆反色：亮 / 暗主题都看得见（终审 I-2）
                    .frame(width: 16, height: 16)
                    .animation(ChatCardMotion.animation(ChatCardMotion.snappy, reduceMotion: reduceMotion), value: state)
            }
            .frame(width: 32, height: 32)

            TimelineView(.animation(paused: state != .playing && growStart == nil)) { timeline in
                let fraction = player.fraction(for: path) ?? 0
                let grow = growStart.map { min(1, timeline.date.timeIntervalSince($0) / VoiceWave.growDuration) } ?? 1
                let shown = VoiceWave.grown(
                    VoiceWave.bounced(bars ?? placeholder, fraction: fraction, playing: state == .playing && !reduceMotion),
                    from: VoiceWave.placeholderLevel, progress: grow)
                HStack(spacing: 0) {
                    Canvas { g, size in
                        let n = shown.count
                        for (i, a) in shown.enumerated() {
                            let x = CGFloat(i) * (VoiceWave.barWidth + VoiceWave.gap)
                            let h = max(3, CGFloat(a) * (size.height - 4))
                            let played = state != .idle && hasFile ? VoiceWave.playedFill(index: i, count: n, fraction: fraction) : 0
                            let rect = CGRect(x: x, y: (size.height - h) / 2, width: VoiceWave.barWidth, height: h)
                            g.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                                   with: .color(ink.opacity(0.2 + 0.8 * played)))
                        }
                    }
                    .frame(width: VoiceWave.width(barCount: shown.count), height: 26)
                    Text(label(state: state, fraction: fraction, hasFile: hasFile))
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CodeBlockStyle.label)
                        .frame(minWidth: 38, alignment: .trailing)
                        .padding(.leading, 10)
                }
            }
        }
        .padding(.leading, embedded ? 0 : 6)
        .padding(.trailing, embedded ? 2 : 14)
        .frame(height: embedded ? 32 : 44)
        .padding(.vertical, embedded ? -7 : 0)                   // 气泡壳自带上下 15：抵掉一些，整泡回到约 48 高（终审 M-1）
        .padding(.horizontal, embedded ? -8 : 0)
        .background {
            if !embedded {
                Capsule().fill(isUser ? Theme.userBubble : CodeBlockStyle.body)
                    .overlay(Capsule().strokeBorder(isUser ? Color.clear : CodeBlockStyle.stroke, lineWidth: 1))
            }
        }
        .environment(\.colorScheme, !embedded && !isUser ? .light : colorScheme)   // 模型的胶囊同卡片：固定浅色
        .contentShape(Capsule())
        .onTapGesture { toggle(fileURL) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasFile ? "语音，\(durationText)" : "语音，文件不在了")
        .accessibilityValue(accessibilityState(state))
        .accessibilityAddTraits(hasFile ? .isButton : [])
        .accessibilityAction { toggle(fileURL) }
        .if(!isUser) { view in
            view.accessibilityAction(named: "换一版") { VoiceMessageWriter.regenerate(nodeId: nodeId, context: modelContext) }
        }
        .if(isUser && !(script ?? "").isEmpty) { view in
            view.accessibilityAction(named: "复制文字") { Self.copy(script ?? "") }
        }
        .accessibilityAction(named: "分享") {
            VoiceNoteShare.share(path: path, profileId: profileId, speaker: speaker, date: createTime)
        }
        .task(id: "\(path)|\(barCount)") {                     // 「换一版」换了文件：先清掉旧声纹（终审 M-3）
            let key = "\(profileId)|\(path)|\(barCount)"
            if let hit = VoiceWaveCache.shared.cached(key) {
                bars = hit
            } else {
                bars = nil
                guard let fileURL else { return }
                bars = await VoiceWaveCache.shared.bars(key: key, url: fileURL, count: barCount)
            }
            // 第一次出现：0.8 秒从左往右长出来（被滚走取消也会落到 growStart = nil，TimelineView 不会空转）
            guard !reduceMotion, Self.grownPaths.insert(path).inserted else { return }
            growStart = Date()
            try? await Task.sleep(for: .seconds(VoiceWave.growDuration))
            growStart = nil
        }
    }

    /// 声纹还没读出来时：低矮的平柱（读完从左往右长成真声纹）
    private var placeholder: [Double] { [Double](repeating: VoiceWave.placeholderLevel, count: barCount) }

    private static func copy(_ script: String) {
        guard !script.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        #else
        UIPasteboard.general.string = script
        #endif
        ToastCenter.shared.show("已复制")
    }

    private var durationText: String {
        guard let duration, duration.isFinite, duration > 0 else { return "语音" }
        return VoiceWave.clock(duration)
    }

    @Environment(\.colorScheme) private var colorScheme

    private func toggle(_ fileURL: URL?) {
        guard let fileURL else { return }
        VoiceMessagePlayer.shared.toggle(url: fileURL, id: path)
    }

    private func accessibilityState(_ state: VoiceMessagePlayer.State) -> String {
        guard let duration, duration.isFinite, duration > 0 else { return "" }
        let left = VoiceWave.clock(duration * (1 - (player.fraction(for: path) ?? 0)))
        switch state {
        case .playing: return "正在播放，剩 \(left)"
        case .paused: return "已暂停，剩 \(left)"
        case .idle: return ""
        }
    }

    private func label(state: VoiceMessagePlayer.State, fraction: Double, hasFile: Bool) -> String {
        guard hasFile else { return "文件不在了" }
        guard state != .idle, let duration, duration.isFinite, duration > 0 else { return durationText }
        return VoiceWave.remaining(duration: duration, fraction: fraction)
    }
}

/// 她发的语音条下面那行（plan-voice-note M7）：默认折叠「转文字 ›」，点开显示转写，再点「收起 ‹」
struct VoiceTranscriptToggle: View {
    let script: String?
    @State private var expanded = false

    var body: some View {
        let empty = (script ?? "").isEmpty
        VStack(alignment: .trailing, spacing: 4) {
            if expanded {
                Text(empty ? "没转出文字" : script ?? "")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary.opacity(empty ? 0.45 : 0.8))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(expanded ? "收起 ‹" : "转文字 ›")
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(expanded ? "收起转写" : "看转写文字")
        }
        .padding(.horizontal, 6)
    }
}

/// 她发的语音条（文章模式，plan-voice-note M7）：胶囊 + 转文字折叠行，右对齐
struct UserVoiceNoteView: View {
    let path: String
    let duration: Double?
    let script: String?
    let nodeId: String
    let profileId: String
    var ownMenu: Bool = true
    var speaker: String = ""
    var createTime: Date? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VoiceCapsuleView(path: path, duration: duration, nodeId: nodeId, profileId: profileId,
                             isUser: true, script: script, ownMenu: ownMenu, speaker: speaker, createTime: createTime)
            VoiceTranscriptToggle(script: script)
        }
    }
}

/// 分享语音条（plan-voice-polish-1007 D）：复制一份到临时目录、改名「<说话人>的语音条-yyyyMMdd-HHmm.<原扩展名>」
/// 再弹系统分享（iOS 分享面板 / mac 分享菜单），原文件不动
enum VoiceNoteShare {
    static func fileName(speaker: String, date: Date, ext: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        // 名字里的 / 和 : 进文件名会变路径 / 被 Finder 换掉
        let who = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (who.isEmpty ? "语音条" : "\(who)的语音条") + "-" + f.string(from: date)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// quickLabel 有值 = 进 iOS 浮层顶上那排图标（消息菜单里用）；语音条自己的菜单一行一个
    @MainActor
    static func spec(path: String, profileId: String, speaker: String, date: Date?, quickLabel: String? = nil) -> MenuActionSpec {
        MenuActionSpec(title: "分享", systemImage: "square.and.arrow.up", quickLabel: quickLabel) {
            share(path: path, profileId: profileId, speaker: speaker, date: date)
        }
    }

    /// 路径解析同播放（audioRef 相对路径 → 楼层文件库）
    @MainActor
    static func share(path: String, profileId: String, speaker: String, date: Date?) {
        guard let src = FileLibraryStore.absoluteURL(path, profileId: profileId) else {
            ToastCenter.shared.show("语音文件不在了")
            return
        }
        // 每次一个新目录：同一分钟两条不撞名，分享面板还在读上一份时也不被覆盖
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceShare-\(UUID().uuidString)", isDirectory: true)
        let dst = dir.appendingPathComponent(fileName(speaker: speaker, date: date ?? Date(), ext: src.pathExtension))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            ToastCenter.shared.show("分享失败：\(error.localizedDescription)")
            return
        }
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: [dst], applicationActivities: nil)
        // iPad 是 popover：锚在屏幕中间、不要箭头
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        vc.popoverPresentationController?.permittedArrowDirections = []
        top.present(vc, animated: true)
        #else
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        // 菜单是右键点出来的：分享菜单从鼠标位置弹
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [dst]).show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)),
                                                  of: view, preferredEdge: .minY)
        #endif
    }
}
