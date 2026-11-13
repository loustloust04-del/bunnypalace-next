import SwiftUI
import SwiftData

/// cc-bridge L2：CC session 选择 UI 内容（可嵌入 ModelPickerPopover 顶部，不带 Sheet 装饰）。
///
/// 显示 3 类条目：
/// - "mp-cc"（默认会话，接历史 / 共享所有 CC 对话）
/// - hub alive 的其它 mp-cc-* sessions（已被占用的灰显 + 🔒）
/// - "+ 新建 session" 触发 spawn_cc
///
/// 选定后 onPick 回调（带会话所在的那台）；调用方核对话还绑着那台再写回 conversation.ccBridgeSessionName + dismiss 父容器。
struct CCSessionPickerContent: View {
    let conversation: Conversation
    /// "claude" 列 mp-cc-*（含默认行）；"codex" 列 mp-codex-*（无默认会话概念）
    var engine: String = "claude"
    /// 新建的对话（还没发过）：≥2 台电脑时会话列表上面先选在哪台（plan-multi-hub B4.4）
    var choosesHub = false
    /// (会话名, 它在哪台)
    var onPick: (String?, String) -> Void

    @Environment(\.modelContext) private var modelContext

    /// hub 返回的当前 alive sessions（mp-cc 前缀）
    @State private var aliveSessions: [String] = []
    @State private var loadError: String?
    @State private var loading = true

    @State private var newSessionName: String = ""
    @State private var spawning = false
    @State private var spawnError: String?

    /// 已被其它对话占用的 mp-cc-N session（默认 mp-cc 不算 — 大家共享）
    @State private var sessionOwners: [String: String] = [:]
    /// 打开时的「上次选的」（选了别台后标记不跟着跳）
    @State private var lastPicked: String?
    /// 选台期间旧那台迟到的 list / spawn 回包不认（b4 #2）
    @State private var requests = CCSessionPickerRequests()

    private var hubId: String { CCHubRegistry.hubId(of: conversation) }

    static let badgeColor = Color(red: 0.22, green: 0.94, blue: 0.49)
    private static let defaultSession = "mp-cc"

    private var currentBound: String? { conversation.ccBridgeSessionName }

    private var aliveExtraSessions: [String] {
        engine == "codex"
            ? aliveSessions.filter { $0.hasPrefix("mp-codex") }
            : aliveSessions.filter { $0 != Self.defaultSession && !$0.hasPrefix("mp-codex") }
    }

    private var hasNonDefaultBinding: Bool {
        guard let b = currentBound, !b.isEmpty, b != Self.defaultSession else { return false }
        return true
    }

    private var showsHubChoice: Bool { choosesHub && CCHubTitle.showsHubChoice(hubCount: CCHubRegistry.shared.hubs.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHubChoice { hubSection }
            // Section title
            HStack {
                Text(engine == "codex" ? "Codex Session" : "CC Session")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                if hasNonDefaultBinding {
                    Button(action: { onPick(Self.defaultSession, hubId) }) {
                        Label("切回默认", systemImage: "arrow.uturn.backward")
                            .font(.system(size: Theme.F.caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 默认 mp-cc — claude 引擎才有默认会话概念
            if engine != "codex" {
            sessionRow(
                name: Self.defaultSession,
                subtitle: hasNonDefaultBinding ? "默认会话 · 点这里切回默认" : "接历史（默认会话）",
                isBound: currentBound == nil || currentBound == Self.defaultSession,
                isAlive: aliveSessions.contains(Self.defaultSession),
                onTap: { onPick(Self.defaultSession, hubId) }
            )
            }

            // 已有的额外 sessions
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("加载 session...")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else if let loadError {
                Text("拉取失败：\(loadError)")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(aliveExtraSessions, id: \.self) { name in
                    let ownerTitle = sessionOwners[name]
                    sessionRow(
                        name: name,
                        subtitle: ownerTitle.map { "已被「\($0)」占用" },
                        isBound: currentBound == name,
                        isAlive: true,
                        isDisabled: ownerTitle != nil,
                        onTap: {
                            if ownerTitle == nil { onPick(name, hubId) }
                        }
                    )
                }
            }

            // 新建
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(engine == "codex" ? "mp-codex-N" : "mp-cc-N", text: $newSessionName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: Theme.F.body, design: .monospaced))
                        .disabled(spawning)

                    Button(action: { spawnNew() }) {
                        if spawning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("+ 新建")
                                .font(.system(size: Theme.F.body, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(spawning || !isValidName(newSessionName))
                }

                if let spawnError {
                    Text(spawnError)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(.red)
                }
                Text("新 session 不接历史（不 --continue）")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear {
            // 新对话先按「上次选的」绑上，下面列的会话才是那台的
            if showsHubChoice {
                lastPicked = CCHubRegistry.shared.lastHubId
                CCHubRegistry.shared.bindNewCCConversation(conversation)
            }
            loadOwners(); suggestNextName(); refresh()
        }
        .onDisappear { requests.invalidate() }
    }

    // MARK: - 在哪台电脑上（小样第 5 屏）

    private var hubSection: some View {
        let current = CCHubRegistry.hubId(of: conversation)
        return VStack(alignment: .leading, spacing: 6) {
            Text("在哪台电脑上")
                .font(.system(size: Theme.F.caption, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(CCHubRegistry.shared.hubs) { hub in
                    hubCard(hub, selected: hub.id == current)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func hubCard(_ hub: CCHubRegistry.HubProfile, selected: Bool) -> some View {
        let status = CCHubTitle.status(of: hub)
        let detail = (hub.id == lastPicked ? ["上次选的"] : []) + [status.text]
        return Button { pickHub(hub.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: hub.id == CCHubRegistry.primaryId ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.bottom, 2)
                Text(hub.name)
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(detail.joined(separator: " · "))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Self.badgeColor.opacity(0.15) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selected ? Self.badgeColor : Theme.textMuted.opacity(0.3), lineWidth: selected ? 1.5 : 1))
            )
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(spawning)
    }

    /// 选了哪台：记成上次选的、绑上，下面的会话换成那台的（连不上的也能选，等它接上再发）。新建 session 等回包时不让换台
    private func pickHub(_ id: String) {
        guard id != hubId, !spawning else { return }
        requests.invalidate()
        CCHubTitle.pickForNewConversation(conversation, hubId: id)
        aliveSessions = []
        newSessionName = ""
        loadOwners(); suggestNextName(); refresh()
    }

    // MARK: - Row builder

    @ViewBuilder
    private func sessionRow(
        name: String,
        subtitle: String?,
        isBound: Bool,
        isAlive: Bool,
        isDisabled: Bool = false,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isDisabled ? Color.gray.opacity(0.4) : (isAlive ? Self.badgeColor : Color.gray.opacity(0.4)))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: Theme.F.body, design: .monospaced))
                        .foregroundColor(isDisabled ? .secondary : Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(isDisabled ? .orange : .secondary)
                    }
                }

                Spacer()

                if isBound {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Self.badgeColor)
                } else if isDisabled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.optionRowVerticalPadding)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isBound ? Self.badgeColor.opacity(0.15) : Color.clear)
            )
            .opacity(isDisabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    // MARK: - Actions

    private func loadOwners() {
        let descriptor = FetchDescriptor<Conversation>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        sessionOwners = Self.sessionOwners(in: all, excluding: conversation.id, hubId: CCHubRegistry.hubId(of: conversation))
    }

    /// 会话名 → 占着它的对话标题。只算绑同一台 hub 的对话（plan-multi-hub B2.8；按 CCHubRegistry.hubId(of:)）
    static func sessionOwners(in all: [Conversation], excluding conversationId: String, hubId: String,
                              hubOf: (Conversation) -> String = CCHubRegistry.hubId(of:)) -> [String: String] {
        var map: [String: String] = [:]
        for c in all {
            guard !c.isTrashed, c.id != conversationId, hubOf(c) == hubId,
                  let name = c.ccBridgeSessionName,
                  !name.isEmpty, name != Self.defaultSession else { continue }
            map[name] = c.title
        }
        return map
    }

    private func refresh() {
        loading = true
        loadError = nil
        // 列 / 起会话都在这条对话连的那台上（plan-multi-hub B3.4）；那台用不了就不列、不起，不落到主 hub
        guard let client = hubClient(onFailure: { loading = false; loadError = $0 }) else { return }
        let ticket = requests.begin(conversationId: conversation.id, hubId: client.hubId)
        client.listSessions { result in
            guard requests.isCurrent(ticket, conversationId: conversation.id, hubId: hubId) else { return }
            loading = false
            switch result {
            case .success(let list): aliveSessions = list
            case .failure(let err):  loadError = err.reason
            }
        }
    }

    private func spawnNew() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name) else {
            spawnError = "名字非法：1-32 字符，仅 alphanum + _-."
            return
        }
        spawning = true
        spawnError = nil
        guard let client = hubClient(onFailure: { spawning = false; spawnError = $0 }) else { return }
        let ticket = requests.begin(conversationId: conversation.id, hubId: client.hubId)
        client.spawnSession(name) { result in
            guard requests.isCurrent(ticket, conversationId: conversation.id, hubId: hubId) else { return }
            spawning = false
            switch result {
            case .success:
                onPick(name, ticket.hubId)
            case .failure(let err):
                spawnError = "spawn 失败：\(err.reason)"
            }
        }
    }

    private func hubClient(onFailure: (String) -> Void) -> CCBridgeWebSocketClient? {
        switch CCHubRegistry.shared.route(CCHubRegistry.hubId(of: conversation)) {
        case .success(let client): return client
        case .failure(let why): onFailure(why.message); return nil
        }
    }

    private func isValidName(_ s: String) -> Bool {
        let pattern = #"^[A-Za-z0-9_.-]{1,32}$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private func suggestNextName() {
        if !newSessionName.isEmpty { return }
        var i = 2
        while aliveSessions.contains("mp-cc-\(i)") || sessionOwners.keys.contains("mp-cc-\(i)") {
            i += 1
        }
        newSessionName = "mp-cc-\(i)"
    }
}

/// 会话选择器里 list / spawn 请求的代次（b4 #2）：请求记下 (对话, 那台, 代次)，回包三样都对得上才认；选台 / 关掉作废旧的
struct CCSessionPickerRequests {
    struct Ticket: Equatable {
        let conversationId: String
        let hubId: String
        let generation: Int
    }

    private(set) var generation = 0

    func begin(conversationId: String, hubId: String) -> Ticket {
        Ticket(conversationId: conversationId, hubId: hubId, generation: generation)
    }

    mutating func invalidate() { generation += 1 }

    func isCurrent(_ ticket: Ticket, conversationId: String, hubId: String) -> Bool {
        ticket == Ticket(conversationId: conversationId, hubId: hubId, generation: generation)
    }
}
