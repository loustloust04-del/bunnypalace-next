import SwiftUI
import Observation

extension Notification.Name {
    /// 打开状态面板（iOS：ContentView 翻到 page2 打开它；点小芽横幅 / 点 route=status 的推送）
    static let statusPanelRequested = Notification.Name("MemoryPalaceStatusPanelRequested")
}

/// 状态面板入口：iOS 交给 ContentView（page / 选中的 app 是它的状态）；mac 直接开右栏
@MainActor
enum StatusPanelRoute {
    nonisolated static let toolId = "status"
    /// 点推送冷启动时 ContentView 还没监听：先记下，出现后消费
    nonisolated static let pendingKey = "pendingPushRoute"

    static func open() {
        #if os(iOS)
        NotificationCenter.default.post(name: .statusPanelRequested, object: nil)
        #else
        IPadPanelLayout.shared.dockShown = true
        IPadPanelLayout.shared.open(toolId)
        #endif
    }
}

struct XiaoyaNotice: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case bad, recovered }

    let id: String
    let source: String
    let kind: Kind
    let text: String
    let names: [String]
    let receivedAt: Date
    /// hub 生成这条提醒的时刻（补投 / 回放可能乱序到，同源只认更新的）
    var createdAt: Date? = nil
}

/// 小芽横幅队列（plan-status-panel §7.7）：UserDefaults 持久；按 id 去重（最近 200 个）；同源新提醒顶掉旧的；
/// ≥2 条合成「有 N 件事要你看一眼。」。挂着直到点 × 或点它
@MainActor
@Observable
final class XiaoyaNoticeCenter {
    static let shared = XiaoyaNoticeCenter()

    private static let noticesKey = "xiaoyaNotices_v1"
    private static let seenKey = "xiaoyaNoticeSeenIDs_v1"
    private static let memoryKey = "xiaoyaMemoryNoticeAt_v1"
    private static let seenLimit = 200

    private(set) var notices: [XiaoyaNotice] = []
    @ObservationIgnored private var seen: [String] = []
    private let defaults: UserDefaults
    /// 运行时的当前楼层（ContentView 接上）；没接上就不喊记忆提醒
    @ObservationIgnored weak var profiles: ProfileManager?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.noticesKey),
           let saved = try? JSONDecoder().decode([XiaoyaNotice].self, from: data) {
            notices = saved
        }
        seen = defaults.stringArray(forKey: Self.seenKey) ?? []
    }

    /// 横幅上那句话；没有就不挂
    var bannerText: String? {
        switch notices.count {
        case 0: return nil
        case 1: return notices[0].text
        default: return "有 \(notices.count) 件事要你看一眼。"
        }
    }

    /// 只有一条时右边那颗：坏了 = 掉落的玫瑰珠，好了 = 金星
    var single: XiaoyaNotice? { notices.count == 1 ? notices.first : nil }

    /// hub 的 status_alert：收过的直接算成功（让 hub 删 pending），返回值 = 能不能 ack
    @discardableResult
    func receive(_ alert: StatusAlert) -> Bool {
        let kind: XiaoyaNotice.Kind = alert.kind == .bad ? .bad : .recovered
        enqueue(XiaoyaNotice(id: alert.id, source: alert.source, kind: kind, text: alert.text, names: alert.names, receivedAt: Date(),
                             createdAt: StatusISO.parse(alert.createdAt)))
        return true
    }

    /// false = 没挂出来（这个 id 收过了 / 同源已经挂着一条更新的）
    @discardableResult
    func enqueue(_ notice: XiaoyaNotice) -> Bool {
        guard !seen.contains(notice.id) else { return false }
        seen.append(notice.id)
        if seen.count > Self.seenLimit { seen = Array(seen.suffix(Self.seenLimit)) }
        if let incoming = notice.createdAt,
           let existing = notices.first(where: { $0.source == notice.source })?.createdAt, existing > incoming {
            save()
            return false
        }
        notices.removeAll { $0.source == notice.source }
        notices.append(notice)
        save()
        return true
    }

    func dismissAll() {
        guard !notices.isEmpty else { return }
        notices = []
        save()
    }

    /// 记忆管线：当前楼层某一项 needsAttention 由假变真时调（MemoryHealthStore.recordError）；同一 (项, 楼层) 24h 一次，恢复不喊
    func noteMemoryFailing(_ kind: MemoryHealthStore.Kind, profileId: String, streak: Int, now: Date = Date()) {
        guard let line = MemoryHealthStatusView.lines.first(where: { $0.0 == kind }), MemoryHealthStore.isOn(kind) else { return }
        guard let current = profiles?.currentProfile.id, current == profileId else { return }
        let key = "\(kind.rawValue)|\(profileId)"
        var last = defaults.dictionary(forKey: Self.memoryKey) as? [String: Double] ?? [:]
        if let at = last[key], now.timeIntervalSince1970 - at < 86400 { return }
        last[key] = now.timeIntervalSince1970
        defaults.set(last, forKey: Self.memoryKey)
        enqueue(XiaoyaNotice(id: "memory-\(key)-\(Int(now.timeIntervalSince1970))", source: "memory.\(kind.rawValue)", kind: .bad,
                             text: "记忆这边「\(line.1)」连着失败 \(streak) 次了，点我看是哪儿卡住。", names: [line.1], receivedAt: now))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notices) { defaults.set(data, forKey: Self.noticesKey) }
        defaults.set(seen, forKey: Self.seenKey)
    }
}

// MARK: - 横幅（App 顶上，双端；设计 docs/design-status-widget.html「小芽来喊你」）

struct XiaoyaNoticeBanner: View {
    @State private var center = XiaoyaNoticeCenter.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let text = center.bannerText {
                banner(text)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: center.notices)
    }

    private func banner(_ text: String) -> some View {
        let palette = StatusPalette(scheme)
        return HStack(spacing: 12) {
            Circle().fill(XiaoyaSkin.current(scheme).mint)
                .frame(width: 44, height: 44)
                .overlay(Image("xiaoya-cameo").resizable().scaledToFit().padding(9).foregroundStyle(palette.stem))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(AssistantPrompts.assistantName)
                        .font(.custom("Georgia", size: 12).italic())
                        .foregroundStyle(palette.stem)
                    if let single = center.single {
                        StatusPendant(recovered: single.kind == .recovered)
                    }
                }
                Text(message(text, names: center.single?.names ?? [], palette: palette))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { center.dismissAll() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.faint)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起")
        }
        .padding(.leading, 11).padding(.trailing, 8).padding(.vertical, 11)
        .background(palette.banner, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color(hex: 0x3C463C).opacity(0.13), radius: 13, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            center.dismissAll()
            StatusPanelRoute.open()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开状态面板")
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// 坏项名字标玫瑰色加粗
    private func message(_ text: String, names: [String], palette: StatusPalette) -> AttributedString {
        var attributed = AttributedString(text)
        for name in names where !name.isEmpty {
            guard let range = attributed.range(of: name) else { continue }
            attributed[range].foregroundColor = palette.badText
            attributed[range].font = .system(size: 14, weight: .semibold)
        }
        return attributed
    }
}

/// 横幅「小芽」旁边那颗：掉落的玫瑰珠 / 点点金星
private struct StatusPendant: View {
    let recovered: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            if recovered {
                StatusStrandDrawing.dotStar(in: &context, center: center, radius: 5, color: StatusPalette.gold)
            } else {
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3.6, y: center.y - 3.6, width: 7.2, height: 7.2)), with: .color(StatusPalette.rose))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}
