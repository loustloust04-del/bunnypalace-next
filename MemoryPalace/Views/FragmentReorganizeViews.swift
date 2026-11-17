import MemoryCore
import SwiftUI

// MARK: - 手动「重新整理」的两个入口（记忆格 ⋯ / 设置 › 记忆 › 审计台设置）；状态是同一份 `FragmentReorganizeStatus`

/// 现在能不能点（只读开关，不读盘：菜单内容会被提前算）
private struct ReorganizeSwitches: DynamicProperty {
    @AppStorage("mem_master") private var memMaster = true
    @AppStorage("mem_content_facts") private var memFacts = true
    @AppStorage(FragmentModelRoute.key) private var c2Model = ""

    var blocked: String? { FragmentReorganize.blocked(master: memMaster, facts: memFacts, choice: c2Model) }
}

/// 记忆格 ⋯ 里那一项：平时「Organize now」，跑的时候变成「Stop · 第几批」
struct ReorganizeDraftsMenuButton: View {
    let profileId: String
    let host: UUID
    private var switches = ReorganizeSwitches()

    init(profileId: String, host: UUID) {
        self.profileId = profileId
        self.host = host
    }

    var body: some View {
        let status = FragmentReorganizeStatus.shared
        if let running = status.running[profileId] {
            Button { status.stop(profileId: profileId) } label: {
                Label("Stop · 第 \(running.batch) / \(running.of) 批", systemImage: "stop.circle")
            }
            .disabled(running.stopping)
        } else {
            Button { status.ask(profileId: profileId, host: host) } label: {
                Label("Organize now", systemImage: "wand.and.stars")
                if let why = switches.blocked { Text(why) }
            }
            .disabled(switches.blocked != nil || !status.counting.isEmpty)
        }
    }
}

/// 记忆格列表最上面那一行：正在数、正在跑（能 Stop）、跑完那句结果才出现，平时没有
struct ReorganizeDraftsStatusSection: View {
    let profileId: String
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        let status = FragmentReorganizeStatus.shared
        if status.counting.contains(profileId) {
            row("\(FragmentDream.actor) · 正在数有多少要整理…") { EmptyView() }
        } else if let running = status.running[profileId] {
            row("\(FragmentDream.actor) · 第 \(running.batch) / \(running.of) 批" + (running.stopping ? "，这一批跑完就停" : "")) {
                Button("Stop") { status.stop(profileId: profileId) }
                    .foregroundColor(Theme.danger)
                    .disabled(running.stopping)
            }
        } else if let result = status.results[profileId] {
            row("\(FragmentDream.actor) · \(result)") {
                Button { status.dismissResult(profileId: profileId) } label: { Image(systemName: "xmark") }
                    .foregroundColor(Theme.textMuted)
                    .accessibilityLabel("收起")
            }
        }
    }

    private func row<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
                    .buttonStyle(.borderless)
            }
            .font(m.caption)
        }
        .panelRowBackground()
    }
}

/// 设置 › 记忆 › 审计台设置「C2 整理」那一节里的几行：按钮、进度（能 Stop）、上一次的结果；确认框也挂在这里
struct ReorganizeDraftsSettingsRows: View {
    let profileId: String
    @Environment(\.settingsMetrics) private var m
    @State private var host = UUID()
    private var switches = ReorganizeSwitches()

    init(profileId: String) {
        self.profileId = profileId
    }

    var body: some View {
        let status = FragmentReorganizeStatus.shared
        Group {
            if let running = status.running[profileId] {
                HStack(spacing: 8) {
                    SubRowLabel(title: "正在整理 · 第 \(running.batch) / \(running.of) 批",
                                sub: running.stopping ? "这一批跑完就停" : "每批在记忆日志里有一行")
                    Button("Stop") { status.stop(profileId: profileId) }
                        .font(m.caption)
                        .foregroundColor(Theme.danger)
                        .buttonStyle(.borderless)
                        .disabled(running.stopping)
                }
            } else {
                Button { status.ask(profileId: profileId, host: host) } label: {
                    SubRowLabel(title: "Organize now",
                                sub: switches.blocked ?? (status.counting.contains(profileId)
                                    ? "正在数有多少要整理…" : "把这一层还在 Draft 的记忆条目重新整理一遍，开始前先报条数和估价"))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(switches.blocked != nil || !status.counting.isEmpty)
                .opacity(switches.blocked != nil ? 0.5 : 1)
            }
        }
        .modifier(ReorganizeDraftsConfirm(host: host))
        if let result = status.results[profileId] {
            VStack(alignment: .leading, spacing: 2) {
                Text("上一次")
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Text(result)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 确认框的宿主：只弹自己这个入口问的那一问；她点「Organize」才跑
struct ReorganizeDraftsConfirm: ViewModifier {
    let host: UUID

    func body(content: Content) -> some View {
        let status = FragmentReorganizeStatus.shared
        content
            .alert(FragmentDream.actor,
                   isPresented: Binding(get: { status.prompt?.host == host }, set: { if !$0, status.prompt?.host == host { status.prompt = nil } }),
                   presenting: status.prompt.flatMap { $0.host == host ? $0 : nil }) { prompt in
                if prompt.canRun {
                    Button("Cancel", role: .cancel) { }
                    Button("Organize") { status.start(prompt) }
                } else {
                    Button("OK", role: .cancel) { }
                }
            } message: { prompt in
                Text(prompt.text)
            }
            .onDisappear { if status.prompt?.host == host { status.prompt = nil } }
    }
}
