import SwiftUI
import SwiftData

/// cc-bridge L2：CC session 选择 UI 内容（可嵌入 ModelPickerPopover 顶部，不带 Sheet 装饰）。
///
/// 显示 3 类条目：
/// - "mp-cc"（默认会话，接历史 / 共享所有 CC 对话）
/// - hub alive 的其它 mp-cc-* sessions（已被占用的灰显 + 🔒）
/// - "+ 新建 session" 触发 spawn_cc
///
/// 选定后 onPick 回调；调用方负责写回 conversation.ccBridgeSessionName + dismiss 父容器。
struct CCSessionPickerContent: View {
    let conversation: Conversation
    /// "claude" 列 mp-cc-*（含默认行）；"codex" 列 mp-codex-*（无默认会话概念）
    var engine: String = "claude"
    var onPick: (String?) -> Void

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section title
            HStack {
                Text(engine == "codex" ? "Codex Session" : "CC Session")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                if hasNonDefaultBinding {
                    Button(action: { onPick(Self.defaultSession) }) {
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
                onTap: { onPick(Self.defaultSession) }
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
                            if ownerTitle == nil { onPick(name) }
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
        .onAppear { loadOwners(); suggestNextName(); refresh() }
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
        var map: [String: String] = [:]
        for c in all {
            guard !c.isTrashed, c.id != conversation.id,
                  let name = c.ccBridgeSessionName,
                  !name.isEmpty, name != Self.defaultSession else { continue }
            map[name] = c.title
        }
        sessionOwners = map
    }

    private func refresh() {
        loading = true
        loadError = nil
        CCBridgeWebSocketClient.shared.listSessions { result in
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
        CCBridgeWebSocketClient.shared.spawnSession(name) { result in
            spawning = false
            switch result {
            case .success:
                onPick(name)
            case .failure(let err):
                spawnError = "spawn 失败：\(err.reason)"
            }
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
