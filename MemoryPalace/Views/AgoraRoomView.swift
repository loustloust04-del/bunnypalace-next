#if os(iOS)
import SwiftUI

/// 群聊页外皮（plan-group-room-uikit，粟粟 09-30「只有外皮是 swiftui，别的都 uikit」）：
/// 背景 + 顶部浮层 + 各 sheet 是 SwiftUI；列表 / 气泡 / 输入框 / 键盘 / 长按全在 UIKit `AgoraRoomViewController`。
struct AgoraRoomView: View {
    @Bindable var viewModel: AgoraViewModel
    let onBack: () -> Void
    /// 胶囊右半「›」：和日常聊天一样去 page 2
    var onForward: () -> Void = {}

    @State private var editingRoom: AgoraRoomSummary?
    @State private var showMembers = false
    @State private var showInbox = false
    @State private var showBridge = false
    /// 顶部浮层高度 → UIKit 列表的顶部 inset（内容从浮层下面开始，滚动时从它底下滚过去）
    @State private var topOverlayHeight: CGFloat = 0

    private var room: AgoraRoomSummary? {
        viewModel.rooms.first { $0.id == viewModel.selectedRoomId }
    }

    private var enabledAgents: [AgoraMember] {
        viewModel.membersByActorId.values
            .filter { $0.isEnabled && $0.role == .member }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var unfinishedMentionCount: Int {
        viewModel.mentionCounts.pending + viewModel.mentionCounts.claimed + viewModel.mentionCounts.failed
    }

    /// 学 p3（粟粟 09-24 录屏）：浅灰底 + 白色对方气泡，顶部控件和输入框都是悬浮玻璃，消息从底下滚过去
    static let roomBackground = Color(red: 0.929, green: 0.925, blue: 0.910)

    @AppStorage(GroupRoomStyle.backgroundKey) private var globalBackground = ""
    @AppStorage(GroupRoomStyle.othersKey) private var globalOthers = ""
    @AppStorage(GroupRoomStyle.mineKey) private var globalMine = ""

    private var roomAppearance: GroupAppearance? { room.map { viewModel.appearance(for: $0) } }
    /// 生效颜色：这个群选的 → 设置里选的 → 默认（GroupRoomStyle）
    private var backgroundHex: String? { roomAppearance?.backgroundHex ?? GroupRoomStyle.stored(globalBackground) }
    private var othersHex: String? { roomAppearance?.othersBubbleHex ?? GroupRoomStyle.stored(globalOthers) }
    private var mineHex: String? { roomAppearance?.mineBubbleHex ?? GroupRoomStyle.stored(globalMine) }

    var body: some View {
        ZStack(alignment: .top) {
            // 安全区 / 键盘由 VC 自己处理
            AgoraRoomRepresentable(viewModel: viewModel, topOverlayHeight: topOverlayHeight,
                                   othersHex: othersHex, mineHex: mineHex)
                .ignoresSafeArea()
            topOverlay
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topOverlayHeight = $0 }
        }
        .background(GroupRoomStyle.background(backgroundHex).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.22), value: viewModel.errorBanner)
        .sheet(item: $editingRoom) { room in
            GroupEditSheet(room: room, viewModel: viewModel)
        }
        .sheet(isPresented: $showMembers) {
            AgoraMemberListSheet(
                members: Array(viewModel.membersByActorId.values),
                currentDMActorId: room?.dmPeerActorId,
                onDirectMessage: { member in await viewModel.createDirectMessage(with: member) }
            )
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.mainBg)
        }
        .sheet(isPresented: $showInbox) {
            AgoraMentionInboxSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showBridge) {
            AgoraBridgeSheet(viewModel: viewModel, members: enabledAgents)
                .presentationDetents([.medium])
                .presentationBackground(Theme.mainBg)
        }
    }

    private func bridgeTitle(_ state: AgoraBridgeState) -> String {
        switch state.bridge.status {
        case .active:
            let actorId = state.currentTurn?.expectedActorId
            let name = actorId.flatMap { viewModel.membersByActorId[$0]?.displayName } ?? "成员"
            return "桥接讨论中 · 等待 \(name)"
        case .completed: return "桥接讨论已完成"
        case .stopped: return "桥接讨论已停止"
        case .failed: return "桥接讨论失败"
        }
    }

    /// 顶部和一对一日常聊天同一套（ContentView 聊天页顶栏）：左玻璃圆返回、右玻璃胶囊「⋯ + ›」、
    /// 中间气泡模式同款头像胶囊（`AvatarNameCapsule`）；点胶囊进编辑群聊
    private var topOverlay: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                HStack(spacing: 8) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                    }
                    .frame(width: ChatTopBarLayout.side, alignment: .leading)
                    .accessibilityLabel("返回普通聊天")
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        moreMenu
                        Button(action: onForward) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                    }
                    .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)
                    .frame(width: ChatTopBarLayout.side, alignment: .trailing)
                }
                .frame(height: 48)
                Button { editingRoom = room } label: {
                    AvatarNameCapsule(name: room.map { viewModel.displayTitle(for: $0) } ?? "中庭", chevron: true) {
                        if let room {
                            GroupAvatarView(room: room, appearance: viewModel.appearance(for: room),
                                            imageData: viewModel.avatarData(for: room), size: 56)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(room == nil)
                .accessibilityLabel("\(room.map { viewModel.displayTitle(for: $0) } ?? "中庭")，\(connectionText)")
                .accessibilityHint("编辑群聊")
            }
            statusPills
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.22), value: viewModel.errorBanner)
    }

    /// 右上「⋯」：桥接讨论 / 成员 / @收件箱（原来顶栏上三个按钮）
    private var moreMenu: some View {
        Menu {
            Button { showMembers = true } label: {
                Label("\(viewModel.membersByActorId.count) 位成员", systemImage: "person.2")
            }
            Button { showInbox = true } label: {
                Label(unfinishedMentionCount > 0 ? "提及收件箱（\(unfinishedMentionCount)）" : "提及收件箱", systemImage: "at")
            }
            Button { showBridge = true } label: {
                Label("开始桥接讨论", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(enabledAgents.count < 2 || viewModel.bridgeState?.bridge.status == .active)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if unfinishedMentionCount > 0 {
                        Circle().fill(Theme.danger).frame(width: 7, height: 7).offset(x: -8, y: 9)
                    }
                }
        }
        .accessibilityLabel("更多")
    }

    /// 胶囊下面的小玻璃药丸：断线 / 桥接进行中 / 报错（学 p3 顶部那颗提示药丸）
    @ViewBuilder
    private var statusPills: some View {
        if viewModel.connectionState != .connected {
            Button { viewModel.nudgeReconnectIfNeeded() } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("未连接 · 点此重连")
                }
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        if let state = viewModel.bridgeState {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Theme.branchIndicator)
                Text("\(bridgeTitle(state)) · \(state.bridge.turnsCompleted)/\(state.bridge.maxTurns)")
                    .lineLimit(1)
                if state.bridge.status == .active {
                    Button("停止") { Task { await viewModel.stopBridge() } }
                        .fontWeight(.semibold)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
        if let error = viewModel.errorBanner {
            Button { viewModel.dismissError() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).lineLimit(2)
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityHint("关闭错误提示")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var connectionText: String {
        switch viewModel.connectionState {
        case .disconnected: "未连接"
        case .connecting: "连接中"
        case .connected: room?.isEnabled == false ? "房间已停用" : "已连接"
        case .reconnecting: "重连中"
        case .failed(let message): "连接失败：\(message)"
        }
    }
}

/// UIKit 主体（列表 + 输入框 + 键盘）
private struct AgoraRoomRepresentable: UIViewControllerRepresentable {
    let viewModel: AgoraViewModel
    let topOverlayHeight: CGFloat
    let othersHex: String?
    let mineHex: String?

    func makeUIViewController(context: Context) -> AgoraRoomViewController {
        AgoraRoomViewController(viewModel: viewModel)
    }

    func updateUIViewController(_ controller: AgoraRoomViewController, context: Context) {
        controller.topOverlayHeight = topOverlayHeight
        controller.bubbleColors = .init(othersHex: othersHex, mineHex: mineHex)
    }
}

private struct AgoraBridgeSheet: View {
    @Bindable var viewModel: AgoraViewModel
    let members: [AgoraMember]

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var firstActorId = ""
    @State private var secondActorId = ""
    @State private var maxTurns = 5
    @State private var isStarting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("讨论主题") {
                    TextField("让两位成员讨论什么？", text: $prompt, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("参与者") {
                    Picker("先发言", selection: $firstActorId) {
                        ForEach(members) { member in Text(member.displayName).tag(member.actorId) }
                    }
                    Picker("接力者", selection: $secondActorId) {
                        ForEach(members) { member in Text(member.displayName).tag(member.actorId) }
                    }
                    Stepper("最多 \(maxTurns) 回合", value: $maxTurns, in: 1...50)
                }
            }
            .navigationTitle("桥接讨论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "启动中…" : "开始") {
                        isStarting = true
                        Task {
                            let started = await viewModel.startBridge(
                                prompt: prompt,
                                firstActorId: firstActorId,
                                secondActorId: secondActorId,
                                maxTurns: maxTurns
                            )
                            isStarting = false
                            if started { dismiss() }
                        }
                    }
                    .disabled(
                        isStarting
                        || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || firstActorId.isEmpty
                        || secondActorId.isEmpty
                        || firstActorId == secondActorId
                    )
                }
            }
            .onAppear {
                if firstActorId.isEmpty { firstActorId = members.first?.actorId ?? "" }
                if secondActorId.isEmpty { secondActorId = members.dropFirst().first?.actorId ?? "" }
            }
        }
    }
}

private struct AgoraMemberListSheet: View {
    let members: [AgoraMember]
    let currentDMActorId: String?
    let onDirectMessage: (AgoraMember) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDirectActorId: String?

    private var sortedMembers: [AgoraMember] {
        members.sorted {
            if $0.role != $1.role { return $0.role == .owner }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List(sortedMembers) { member in
                HStack(spacing: 11) {
                    ZStack {
                        Circle().fill(Theme.branchIndicator.opacity(0.2))
                        Text(String(member.displayName.prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(member.displayName).font(.body.weight(.medium))
                            if member.role == .owner {
                                Text("房主")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.accent.opacity(0.5)))
                            }
                        }
                        Text("@\(member.handle)")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    if member.role == .member && member.isEnabled {
                        Button {
                            pendingDirectActorId = member.actorId
                            Task {
                                let succeeded = await onDirectMessage(member)
                                pendingDirectActorId = nil
                                if succeeded { dismiss() }
                            }
                        } label: {
                            if pendingDirectActorId == member.actorId {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(
                                    currentDMActorId == member.actorId ? "当前私信" : "私信",
                                    systemImage: "bubble.left"
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(pendingDirectActorId != nil || currentDMActorId == member.actorId)
                        .accessibilityLabel("私信 \(member.displayName)")
                    } else if !member.isEnabled {
                        Text("已停用").font(.caption).foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle("房间成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
#endif
