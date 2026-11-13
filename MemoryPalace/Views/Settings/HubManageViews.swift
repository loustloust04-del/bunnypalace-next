#if os(iOS)
import SwiftData
import SwiftUI

/// 多台电脑的三处界面（plan-multi-hub B4.3，小样第 3 / 4 屏）：扫码落点、管理这台、设置 › 我的电脑顶上的电脑列表。
/// 配对一律经 classifyPairing 认是哪台，再按结果 addHub / updatePairing；没有「替换某台」

/// 扫码 / 手填 → 先握一次手认是哪台 → 更新那台 / 添加新电脑。target = 从哪台的「重新扫码」进来（nil = 再接一台）；
/// check = 主电脑的入口已经握过手、认出不是它（b4 #1）：直接停在落点
struct HubPairingSheet: View {
    let target: String?
    var check: CCHubRegistry.PrimaryPairingCheck? = nil
    /// 提交成了才回（更新了哪台 / 加了新电脑）：调用方据此续上原来的流程（R5.5）；取消 / 关掉不回
    var onCommitted: ((CCHubPairingLanding.Commit) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @State private var showScanner = false
    @State private var primaryDraft = ""
    @State private var backupDraft = ""
    @State private var tokenDraft = ""
    @State private var stage: Stage = .input
    @State private var choice: CCHubPairingLanding.Choice?
    @State private var name = ""
    @State private var nameSelection: TextSelection?
    @FocusState private var nameFocused: Bool
    @State private var failure: String?

    private struct Candidate {
        let pairing: CCHubPairing
        let token: String
        /// 握手时 hello 报的 hub_id（老 hub = nil）：更新时当预期身份，新增时先记下
        let reported: String?
    }

    private enum Stage {
        case input
        case probing
        case landing(CCHubPairingLanding, Candidate)
    }

    /// 握手回调里接 hello
    private final class HelloBox {
        var hello: HubHello?
    }

    private var registry: CCHubRegistry { .shared }

    private func hubName(_ id: String) -> String { registry.hubs.first { $0.id == id }?.name ?? "这台电脑" }

    var body: some View {
        NavigationStack {
            SettingsSectionList(.list) {
                switch stage {
                case .input: inputSections
                case .probing:
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在认是哪台…").font(m.rowLabel).foregroundColor(Theme.textMuted)
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                case .landing(let landing, let candidate): landingSections(landing, candidate)
                }
            }
            .tint(Theme.branchIndicator)
            .navigationTitle(target.map { "重新扫码 · \(hubName($0))" } ?? "再接一台电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            CCPairScannerSheet { payload in probe(CCHubPairing(payload: payload), token: payload.t) }
        }
        .onAppear(perform: prefill)
    }

    // MARK: 扫码 / 手填

    @ViewBuilder
    private var inputSections: some View {
        Section {
            Button { showScanner = true } label: {
                Label("扫码", systemImage: "qrcode.viewfinder").font(m.rowLabel).foregroundColor(Theme.textPrimary)
            }
        } footer: {
            Text("扫那台电脑上 hub 给的配对二维码（Mac：设置 →「让手机连这台 Mac」→「配对手机」）。扫到已有的那台就是更新它，对话和窗口都留着。")
        }
        .listRowBackground(Theme.mainBg)

        Section {
            field("主地址", "ws://…:7890/cc", text: $primaryDraft)
            field("备地址", "选填", text: $backupDraft)
            VStack(alignment: .leading, spacing: 6) {
                Text("口令").font(m.caption).foregroundColor(Theme.textSecondary)
                SecureField("hub 的口令", text: $tokenDraft)
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
            Button("认一认是哪台") { probe(manualPairing, token: tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .font(m.rowLabel)
                .disabled(!manualReady)
        } header: {
            Text("没法扫码就手填")
        } footer: {
            Text("改地址、换口令都在这里。填完先连一下认是哪台，再决定是更新还是新加。")
        }
        .listRowBackground(Theme.mainBg)
    }

    private func field(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(m.caption).foregroundColor(Theme.textSecondary)
            TextField(placeholder, text: text)
                .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
        }
    }

    private var manualReady: Bool {
        primaryDraft.trimmingCharacters(in: .whitespaces).hasPrefix("ws")
            && !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 手填：从某台进来的，地址没变就留着它扫码存的中继（同 API 卡的手填规则）
    private var manualPairing: CCHubPairing {
        let primary = primaryDraft.trimmingCharacters(in: .whitespaces)
        let backup = backupDraft.trimmingCharacters(in: .whitespaces)
        guard let base = target.flatMap(registry.defaults(for:)).map(CCHubPairing.read) else {
            return CCHubPairing(primaryURL: primary, backupURL: backup)
        }
        return base.manual(primary: primary, backup: backup)
    }

    /// 从某台进来：手填框先填它现在的地址（口令不回显）；带着握过手的结果进来就直接落点
    private func prefill() {
        if primaryDraft.isEmpty, let d = target.flatMap(registry.defaults(for:)) {
            let current = CCHubPairing.read(d)
            primaryDraft = current.primaryURL ?? ""
            backupDraft = current.backupURL ?? ""
        }
        if let check, case .input = stage {
            land(check.match, pairing: check.pairing, token: check.token, reported: check.reported, hostName: check.hostName)
        }
    }

    private func probe(_ pairing: CCHubPairing, token: String) {
        stage = .probing
        failure = nil
        let box = HelloBox()
        Task {
            let match = await registry.classifyPairing(pairing, token: token, target: target) { pairing, token in
                await CCHubRegistry.handshakeProbe(pairing, token: token) { box.hello = $0 }
            }
            land(match, pairing: pairing, token: token, reported: box.hello?.hubId, hostName: box.hello?.hostName)
        }
    }

    private func land(_ match: CCHubRegistry.PairingMatch, pairing: CCHubPairing, token: String, reported: String?, hostName: String?) {
        let landing = CCHubPairingLanding.make(
            match, hostName: hostName, hubs: registry.hubs, target: target, new: pairing, token: token,
            pairing: { registry.defaults(for: $0).map(CCHubPairing.read) },
            fingerprint: { registry.defaults(for: $0).flatMap(CCHubPairingStore.storedFingerprint) })
        choice = landing.choices.first
        name = landing.suggestedName
        stage = .landing(landing, Candidate(pairing: pairing, token: token, reported: reported))
    }

    // MARK: 落点

    @ViewBuilder
    private func landingSections(_ landing: CCHubPairingLanding, _ candidate: Candidate) -> some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: icon(landing.kind))
                    .foregroundColor(landing.kind == .unreachable ? Theme.danger : Theme.branchIndicator)
                Text(landing.title).font(m.rowLabel.weight(.semibold)).foregroundColor(Theme.textPrimary)
            }
            Text(landing.hint).font(m.secondary).foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)

        if case .update = landing.kind {
            Section {
                ForEach(landing.changes, id: \.label) { change in
                    HStack(alignment: .firstTextBaseline) {
                        Text(change.label).font(m.rowLabel).foregroundColor(Theme.textPrimary)
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(change.old ?? "没有").strikethrough(change.old != nil).foregroundColor(Theme.textMuted)
                            Text(change.new ?? "没有").foregroundColor(Theme.textPrimary)
                        }
                        .font(m.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }
                HStack {
                    Text("口令").font(m.rowLabel).foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(landing.tokenChanged ? "换成新的" : "没变").font(m.secondary).foregroundColor(Theme.textMuted)
                }
            } header: {
                Text("会变的")
            }
            .listRowBackground(Theme.mainBg)
        }

        if case .choose = landing.kind {
            Section {
                ForEach(landing.choices, id: \.self) { option in
                    Button { choice = option } label: {
                        HStack(spacing: 10) {
                            Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(choice == option ? Theme.branchIndicator : Theme.textMuted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(m.rowLabel).foregroundColor(Theme.textPrimary)
                                Text(option.detail).font(m.caption).foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
        }

        if landing.needsName(choice: choice) {
            Section {
                TextField("名字", text: $name, selection: $nameSelection)
                    .font(m.rowLabel)
                    .focused($nameFocused)
                    .onAppear {
                        // 先聚焦再全选（没聚焦时设的选区会被丢掉）
                        nameFocused = true
                        DispatchQueue.main.async { nameSelection = TextSelection(range: name.startIndex..<name.endIndex) }
                    }
            } header: {
                Text("名字")
            } footer: {
                Text("hub 报的主机名，先填着，改成你认得的（比如它在哪）。会摆在后排；型号报不上来就画成一体机。")
            }
            .listRowBackground(Theme.mainBg)
        }

        if let failure {
            Section {
                Text(failure).font(m.secondary).foregroundColor(Theme.danger)
            }
            .listRowBackground(Theme.mainBg)
        }

        Section {
            Button(landing.buttonTitle(choice: choice, names: hubName)) { commit(landing, candidate) }
                .font(m.rowLabel.weight(.semibold))
        }
        .listRowBackground(Theme.mainBg)
    }

    private func icon(_ kind: CCHubPairingLanding.Kind) -> String {
        switch kind {
        case .update: return "checkmark.circle.fill"
        case .addNew: return "plus.circle.fill"
        case .choose: return "questionmark.circle.fill"
        case .unreachable: return "exclamationmark.triangle.fill"
        }
    }

    private func commit(_ landing: CCHubPairingLanding, _ candidate: Candidate) {
        guard let action = landing.commit(choice: choice) else {
            stage = .input
            return
        }
        switch action {
        case .add:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? CCHubPairingLanding.fallbackName : trimmed
            let result = registry.addHub(name: name, pairing: candidate.pairing, token: candidate.token, identity: candidate.reported)
            if let message = CCHubPairingLanding.failure(result, names: hubName) {
                failure = message
                return
            }
            ToastCenter.shared.show("加好了：\(name)")
            onCommitted?(.add)
        case .update(let id):
            let primary = id == CCHubRegistry.primaryId
            let result = registry.updatePairing(id, candidate.pairing, token: candidate.token, expectedIdentity: candidate.reported,
                                                providerManager: primary ? providerManager : nil)
            if let message = CCHubPairingLanding.failure(result, target: id, names: hubName) {
                failure = message
                return
            }
            if primary { providerManager?.reload() }
            ToastCenter.shared.show("\(hubName(id))更新好了 · 对话和窗口都留着")
            onCommitted?(.update(id))
        }
        dismiss()
    }
}

/// 一台电脑的状态一句话（管理页 / 电脑列表共用）
private struct HubStatusLine {
    let text: String
    let color: Color
    /// 右边的动作
    let action: Action?

    enum Action { case reconnect, rescan }

    @MainActor
    init(_ id: String) {
        let registry = CCHubRegistry.shared
        let client = try? registry.route(id).get()
        let pairing = registry.defaults(for: id).map(CCHubPairing.read) ?? CCHubPairing()
        switch registry.status(for: id) {
        case .needsPairing?:
            self.init(text: "要重新配对", color: Palette.apricot, action: .rescan)
        case .identityChanged?:
            self.init(text: "连上的是另一台电脑，先停住了", color: Palette.apricot, action: .rescan)
        case nil:
            self.init(text: "已经删了", color: Theme.textMuted, action: nil)
        case .ready?:
            if let client, client.isConnected {
                let route = client.currentHost.map { " · \(NetworkRoute.classify($0).label)" } ?? ""
                self.init(text: "已接上" + route, color: Theme.branchIndicator, action: nil)
            } else if pairing.primaryURL != nil || pairing.backupURL != nil || pairing.relayURL != nil {
                self.init(text: TerminalLastSeen.broken(client?.lastAliveAt), color: Theme.danger, action: .reconnect)
            } else {
                self.init(text: "还没配对", color: Theme.textMuted, action: .rescan)
            }
        }
    }

    private init(text: String, color: Color, action: Action?) {
        self.text = text
        self.color = color
        self.action = action
    }
}

/// 终端首页底部条「管理这台」：自带导航栏 + 完成；终端的暗色面板（小样第 3 屏）
struct HubManageSheet: View {
    let hubId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HubManagePage(hubId: hubId, dark: true)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .environment(\.colorScheme, .dark)
        .presentationBackground(TerminalChrome.sheet)
    }
}

/// 管理这台（小样第 3 屏）：名字可改；连接；地址只读（改地址 / 口令一律重新扫码）；附加那台看 hubInfo、能删；
/// 主电脑只放名字 / 连接 / 地址 + 一行跳 设置 › 我的电脑
struct HubManagePage: View {
    let hubId: String
    /// 从 设置 › 我的电脑 点进来的不再给跳回去那行
    var showsMyComputerLink = true
    /// 从终端进来：终端的暗色面板（小样第 3 屏）；从设置进照旧亮色
    var dark = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.settingsMetrics) private var m
    @State private var name = ""
    @State private var savedName = ""
    @State private var showRescan = false
    @State private var confirmDelete = false
    @State private var boundCount = 0

    private var registry: CCHubRegistry { .shared }
    private var isPrimary: Bool { hubId == CCHubRegistry.primaryId }
    private var profile: CCHubRegistry.HubProfile? { registry.hubs.first { $0.id == hubId } }
    private var client: CCBridgeWebSocketClient? { try? registry.route(hubId).get() }
    private var pairing: CCHubPairing { registry.defaults(for: hubId).map(CCHubPairing.read) ?? CCHubPairing() }
    private var rowBackground: Color { dark ? TerminalChrome.selected : Theme.mainBg }
    private var ink: Color { dark ? TerminalChrome.ink : Theme.textPrimary }
    private var muted: Color { dark ? TerminalChrome.dim : Theme.textMuted }

    var body: some View {
        SettingsSectionList(.list) {
            if profile != nil {
                heroSection
                nameSection
                connectionSection
                addressSection
                if !isPrimary { infoSection }
                pairingSection
                tailSection
            }
        }
        .tint(Theme.branchIndicator)
        .scrollContentBackground(dark ? .hidden : .automatic)
        .background(dark ? TerminalChrome.sheet : Color.clear)
        .navigationTitle("管理这台")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: saveName)
        .onChange(of: profile == nil) { _, gone in if gone { dismiss() } }
        .sheet(isPresented: $showRescan) { HubPairingSheet(target: hubId) }
        .alert("删除「\(savedName)」？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive, action: delete)
        } message: {
            Text(deleteMessage)
        }
    }

    private var hubInfo: HubHello? { client?.hubInfo }

    private var heroSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: hubInfo?.hostModelName == nil && !isPrimary ? "desktopcomputer" : "laptopcomputer")
                    .font(.system(size: 22))
                    .foregroundColor(muted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile?.name ?? "").font(m.rowLabel.weight(.semibold)).foregroundColor(ink)
                        if isPrimary {
                            Text("主电脑")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Theme.mainBg)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.branchIndicator))
                        }
                    }
                    Text(hubInfo?.hostModelName ?? hubInfo?.hostName ?? "型号报不上来").font(m.caption).foregroundColor(muted)
                }
            }
        }
        .listRowBackground(rowBackground)
    }

    private var nameSection: some View {
        Section {
            TextField("名字", text: $name)
                .font(m.rowLabel)
                .submitLabel(.done)
                .onSubmit(saveName)
        } header: {
            Text("名字")
        }
        .listRowBackground(rowBackground)
    }

    private var connectionSection: some View {
        let line = HubStatusLine(hubId)
        return Section {
            HStack(spacing: 8) {
                Circle().fill(line.color).frame(width: 7, height: 7)
                // 「N 分钟前还在」按分钟走
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(HubStatusLine(hubId).text).font(m.secondary).foregroundColor(ink)
                }
                Spacer(minLength: 8)
                switch line.action {
                case .reconnect?:
                    Button("重新连接") { client?.reconnectNow() }.font(m.secondary)
                case .rescan?:
                    Button("重新扫码") { showRescan = true }.font(m.secondary)
                case nil:
                    EmptyView()
                }
            }
        } header: {
            Text("连接")
        }
        .listRowBackground(rowBackground)
    }

    private var addressSection: some View {
        let p = pairing
        return Section {
            // 主电脑什么都没配时连的是本机默认地址（同 CCBridgeEndpoints.configuredURLs）
            addressRow("主", p.primaryURL ?? (isPrimary && p.relayURL == nil ? "\(APIProvider.ccBridge.baseURL)（默认）" : nil))
            addressRow("备", p.backupURL)
            addressRow("中继", p.relayURL)
        } header: {
            Text("地址")
        } footer: {
            if !isPrimary, [p.primaryURL, p.backupURL].contains(where: CCHubPairingLanding.isPlaintextPublic) {
                Text("明文连接，确认只有梯子 / Tailscale 能到这个端口")
            }
        }
        .listRowBackground(rowBackground)
    }

    private func addressRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).font(m.rowLabel).foregroundColor(ink)
            Spacer(minLength: 12)
            Text(value ?? "没有")
                .font(m.caption.monospaced())
                .foregroundColor(muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    /// 附加那台只显示 hub 报来的（B5 最后一行）
    private var infoSection: some View {
        Section {
            if let info = hubInfo {
                if let host = info.hostName { infoRow("主机名", host) }
                if let version = info.hubVersion { infoRow("hub 版本", version) }
                infoRow("Agent", agents(info.tools))
            } else {
                Text("连上后这里会列出来").font(m.secondary).foregroundColor(muted)
            }
        } header: {
            Text("这台电脑")
        }
        .listRowBackground(rowBackground)
    }

    private func agents(_ tools: HubHello.Tools) -> String {
        let list = [tools.claude == true ? "Claude Code" : nil, tools.codex == true ? "Codex" : nil].compactMap { $0 }
        if !list.isEmpty { return list.joined(separator: "、") }
        return tools.claude == false && tools.codex == false ? "都没装" : "还不知道"
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(m.rowLabel).foregroundColor(ink)
            Spacer(minLength: 12)
            Text(value).font(m.secondary).foregroundColor(muted).lineLimit(1)
        }
    }

    private var pairingSection: some View {
        Section {
            Button { showRescan = true } label: {
                Label("重新扫码", systemImage: "qrcode.viewfinder").font(m.rowLabel).foregroundColor(ink)
            }
        } header: {
            Text("配对")
        } footer: {
            Text("改地址、换口令都走这里（扫不了就在扫码页手填）。扫到同一台就是更新，对话和窗口都留着。")
        }
        .listRowBackground(rowBackground)
    }

    @ViewBuilder
    private var tailSection: some View {
        if isPrimary {
            Section {
                if showsMyComputerLink {
                    NavigationLink {
                        MyComputerSettingsPage()
                    } label: {
                        HStack {
                            Text("工作目录、绑定开关…").font(m.rowLabel).foregroundColor(ink)
                            Spacer()
                            Text("设置 › 我的电脑").font(m.secondary).foregroundColor(muted)
                        }
                    }
                }
            } footer: {
                Text("这是主电脑：实时活动、语音通话、记忆同步这些只走它，所以不能删，也不能把别的电脑设成主电脑。")
            }
            .listRowBackground(rowBackground)
        } else {
            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text("删除这台电脑").font(m.rowLabel).foregroundColor(Theme.danger)
                }
            } footer: {
                Text("连着\(savedName)的 \(boundCount) 个对话会留着，删掉后换一台电脑才能接着发。")
            }
            .listRowBackground(rowBackground)
        }
    }

    private var deleteMessage: String {
        let push = client?.isConnected == true
            ? "会先让\(savedName)注销这台手机的推送，以后不再收到它的提醒。"
            : "\(savedName)现在连不上，注销不了推送：那台电脑以后可能还会推送，直到它下次上线被注销（也可以在那台电脑上自己清掉）。"
        return push + "\n\n连着它的 \(boundCount) 个对话会停住，换一台电脑才能接着发。"
    }

    private func load() {
        if savedName.isEmpty {
            savedName = profile?.name ?? ""
            name = savedName
        }
        boundCount = Self.boundConversations(hubId, context: modelContext)
    }

    /// 绑在这台上的对话数（所有楼层）。ccHubId 是 optional，谓词只用非 optional 字段，在内存里数
    static func boundConversations(_ hubId: String, context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { !$0.isTrashed })
        descriptor.propertiesToFetch = [\.ccHubId]
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.ccHubId == hubId }.count
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedName, profile != nil else { return }
        if trimmed.isEmpty, !isPrimary {
            name = savedName
            return
        }
        registry.rename(hubId, to: trimmed)
        savedName = profile?.name ?? trimmed
        name = savedName
    }

    private func delete() {
        let name = savedName
        registry.remove(hubId)
        ToastCenter.shared.show("删掉了\(name) · 连着它的对话换一台电脑才能接着发")
    }
}

/// 设置 › 我的电脑 顶上：一行行的电脑（点了进管理这台），给不进终端的人找得到；主电脑配过对后可以再接一台。
/// 「再接一台」的 sheet 挂在页面上（adding）：挂在列表的 Section 上会一行挂一份，同时弹几次把整个设置顶掉（B7.2 B2）
struct HubListSection: View {
    let primaryPaired: Bool
    @Binding var adding: Bool

    @Environment(\.settingsMetrics) private var m

    private var hubs: [CCHubRegistry.HubProfile] { CCHubRegistry.shared.hubs }

    var body: some View {
        Section {
            ForEach(hubs) { hub in
                NavigationLink {
                    HubManagePage(hubId: hub.id, showsMyComputerLink: false)
                } label: {
                    row(hub)
                }
            }
            if primaryPaired {
                Button { adding = true } label: {
                    Label("再接一台电脑…", systemImage: "plus").font(m.rowLabel).foregroundColor(Theme.textPrimary)
                }
            }
        } header: {
            Text("电脑")
        } footer: {
            if hubs.count >= 2 {
                Text("下面这些设置只管主电脑「\(CCHubRegistry.shared.primaryName)」。")
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    /// 「N 分钟前还在」按 30 秒刷（只刷这一行，同首页，b4 #12）
    private func row(_ hub: CCHubRegistry.HubProfile) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let line = HubStatusLine(hub.id)
            HStack(spacing: 8) {
                Circle().fill(line.color).frame(width: 7, height: 7)
                Text(hub.name).font(m.rowLabel).foregroundColor(Theme.textPrimary).lineLimit(1)
                if hub.id == CCHubRegistry.primaryId, hubs.count >= 2 {
                    Text("主电脑").font(m.caption).foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 8)
                Text(line.text).font(m.secondary).foregroundColor(Theme.textMuted).lineLimit(1)
            }
        }
    }
}
#endif
