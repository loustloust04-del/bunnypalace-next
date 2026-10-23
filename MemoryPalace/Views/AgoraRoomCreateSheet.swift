#if os(iOS)
import SwiftUI

struct AgoraRoomCreateSheet: View {
    @Bindable var viewModel: AgoraViewModel
    let initialOwnerDisplayName: String
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var ownerHandle = ""
    @AppStorage("agoraLastOwnerHandle") private var lastOwnerHandle = ""
    @State private var ownerDisplayName = ""
    @State private var availableSessions: [String] = []
    @State private var members: [MemberDraft] = []
    @State private var newSessionName = ""
    @State private var isLoading = false
    @State private var isSpawning = false
    @State private var isCreating = false
    @State private var localError: String?

    private struct MemberDraft: Identifiable {
        let id = UUID()
        let sessionName: String
        var handle: String
        var displayName: String
    }

    private var validationError: String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty || trimmedTitle.count > 120 { return "房间名需为 1–120 个字符" }
        if !Self.isValidHandle(ownerHandle) { return "你的 handle 格式不正确" }
        let ownerName = ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if ownerName.isEmpty || ownerName.count > 80 { return "你的显示名需为 1–80 个字符" }
        if members.isEmpty { return "至少选择 1 个 CC session" }
        if members.count > 15 { return "一个房间最多 15 个 agent" }

        var handles = Set([ownerHandle.lowercased()])
        var sessions = Set<String>()
        for member in members {
            if !Self.isValidHandle(member.handle) { return "@\(member.handle) 的格式不正确" }
            let display = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if display.isEmpty || display.count > 80 { return "\(member.sessionName) 的显示名需为 1–80 个字符" }
            if !handles.insert(member.handle.lowercased()).inserted { return "handle 不能重复：@\(member.handle)" }
            if !sessions.insert(member.sessionName).inserted { return "CC session 不能重复" }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("房间") {
                    TextField("房间名称", text: $title)
                        .textInputAutocapitalization(.sentences)
                    Text("本版创建后暂不支持编辑成员。")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }

                Section("你") {
                    handleField("handle", text: $ownerHandle)
                    TextField("显示名", text: $ownerDisplayName)
                }

                Section("房间成员 · \(members.count)/15") {
                    if members.isEmpty {
                        Text("从下面的 CC sessions 添加成员")
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach($members) { $member in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(member.sessionName, systemImage: "terminal")
                                    .font(.subheadline.monospaced())
                                Spacer()
                                Button(role: .destructive) {
                                    members.removeAll { $0.id == member.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除 \(member.sessionName)")
                            }
                            handleField("房间 handle", text: $member.handle)
                            TextField("显示名", text: $member.displayName)
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section("CC Sessions") {
                    if isLoading {
                        HStack { ProgressView(); Text("正在读取 sessions…") }
                    } else if availableSessions.isEmpty {
                        Text("没有可用的 CC session")
                            .foregroundStyle(Theme.textMuted)
                    } else {
                        ForEach(availableSessions, id: \.self) { session in
                            Button {
                                addSession(session)
                            } label: {
                                HStack {
                                    Label(session, systemImage: "terminal")
                                    Spacer()
                                    if members.contains(where: { $0.sessionName == session }) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Theme.branchIndicator)
                                    } else {
                                        Image(systemName: "plus.circle")
                                    }
                                }
                            }
                            .disabled(members.contains(where: { $0.sessionName == session }) || members.count >= 15)
                        }
                    }

                    HStack {
                        TextField("mp-cc-N", text: $newSessionName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button {
                            spawnSession()
                        } label: {
                            if isSpawning { ProgressView().controlSize(.small) }
                            else { Text("新建") }
                        }
                        .disabled(isSpawning || !Self.isValidSessionName(newSessionName))
                    }
                    Text("新 session 不接历史；创建成功后会登记为中庭 Actor。")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }

                if let error = localError ?? viewModel.errorBanner {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.danger)
                            .accessibilityLabel("错误：\(error)")
                    }
                }
            }
            .navigationTitle("新建中庭房间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        createRoom()
                    } label: {
                        if isCreating { ProgressView().controlSize(.small) }
                        else { Text("创建") }
                    }
                    .disabled(isCreating || validationError != nil)
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
        .presentationBackground(Theme.mainBg)
        .onAppear {
            if ownerHandle.isEmpty {
                let loaded = viewModel.membersByActorId.values.first(where: { $0.role == .owner })?.handle
                ownerHandle = loaded ?? (lastOwnerHandle.isEmpty ? "me" : lastOwnerHandle)
            }
            if ownerDisplayName.isEmpty {
                ownerDisplayName = initialOwnerDisplayName.isEmpty ? "你" : initialOwnerDisplayName
            }
            if newSessionName.isEmpty { newSessionName = "mp-cc-2" }
        }
        .task { await loadSessions() }
        .task(id: localError) {
            guard localError != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            localError = nil
        }
    }

    private func handleField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 3) {
            Text("@").foregroundStyle(Theme.textMuted)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
        }
    }

    private func addSession(_ session: String) {
        guard members.count < 15,
              !members.contains(where: { $0.sessionName == session }) else { return }
        let handle = Self.suggestedHandle(for: session)
        members.append(MemberDraft(sessionName: session, handle: handle, displayName: session))
    }

    private func loadSessions() async {
        isLoading = true
        localError = nil
        defer { isLoading = false }
        var sessions = Set<String>()
        do {
            for actor in try await viewModel.listActors() where actor.kind == .ccBridge && actor.disabledAt == nil {
                if let name = actor.sessionName { sessions.insert(name) }
            }
        } catch {
            localError = error.localizedDescription
        }
        do {
            for name in try await listCCSessions() { sessions.insert(name) }
        } catch {
            if sessions.isEmpty { localError = error.localizedDescription }
        }
        availableSessions = sessions.sorted()
        suggestNextSessionName()
    }

    private func spawnSession() {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSessionName(name) else { return }
        isSpawning = true
        localError = nil
        Task {
            defer { isSpawning = false }
            do {
                try await spawnCCSession(name)
                _ = try await viewModel.upsertCCActor(sessionName: name)
                if !availableSessions.contains(name) { availableSessions.append(name); availableSessions.sort() }
                addSession(name)
                suggestNextSessionName()
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func createRoom() {
        guard validationError == nil else { return }
        isCreating = true
        localError = nil
        let creationMembers = members.map {
            AgoraRoomCreationMember(
                sessionName: $0.sessionName,
                handle: $0.handle.lowercased(),
                displayName: $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                avatarRef: nil
            )
        }
        Task {
            let succeeded = await viewModel.createRoom(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                ownerProfile: AgoraOwnerProfile(
                    handle: ownerHandle.lowercased(),
                    displayName: ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    avatarRef: nil
                ),
                members: creationMembers
            )
            isCreating = false
            if succeeded {
                lastOwnerHandle = ownerHandle.lowercased()
                onCreated()
                dismiss()
            }
        }
    }

    private func listCCSessions() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            CCBridgeWebSocketClient.shared.listSessions { continuation.resume(with: $0) }
        }
    }

    private func spawnCCSession(_ name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CCBridgeWebSocketClient.shared.spawnSession(name) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func suggestNextSessionName() {
        var index = 2
        let occupied = Set(availableSessions).union(members.map(\.sessionName))
        while occupied.contains("mp-cc-\(index)") { index += 1 }
        newSessionName = "mp-cc-\(index)"
    }

    private static func isValidHandle(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$"#, options: .regularExpression) != nil
    }

    private static func isValidSessionName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_.-]{1,32}$"#, options: .regularExpression) != nil
    }

    private static func suggestedHandle(for session: String) -> String {
        var value = session.lowercased()
        if value.hasPrefix("mp-cc-") { value.removeFirst("mp-cc-".count) }
        value = value.replacingOccurrences(of: #"[^a-z0-9_.-]"#, with: "-", options: .regularExpression)
        if value.isEmpty { value = "agent" }
        if value.first?.isLetter != true && value.first?.isNumber != true { value = "agent-\(value)" }
        return String(value.prefix(32))
    }
}
#endif
