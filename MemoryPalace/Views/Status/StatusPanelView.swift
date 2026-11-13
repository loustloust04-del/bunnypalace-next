import SwiftUI

/// 状态面板（plan-status-panel §3.3，样子照 docs/design-status-widget.html「点进去：状态面板」）：
/// 大标题是结论；每串在上、坏项逐条在下，通着的收成一行；右上「立即检修」；底部小芽静音时段
struct StatusPanelView: View {
    @State private var snapshot = StatusSnapshot.shared
    @State private var bridge = CCBridgeWebSocketClient.shared
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    @State private var expanded: Set<String> = []
    @State private var choosingRun = false
    @State private var editingQuiet = false
    @State private var showsFormat = false

    private var palette: StatusPalette { StatusPalette(scheme) }

    var body: some View {
        let strands = StatusModel.strands(sources: snapshot.sources, garden: snapshot.garden, now: now)
        let head = StatusModel.headline(strands, now: now)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    Text(head.title)
                        .font(.custom("Georgia", size: 34))
                        .tracking(0.5)
                        .foregroundStyle(palette.ink)
                        .padding(.top, 18)
                    Text(head.subtitle)
                        .font(.system(size: 13))
                        .tracking(1)
                        .foregroundStyle(palette.faint)
                        .padding(.top, 2)
                    if snapshot.sources.isEmpty { emptyBlock }
                    ForEach(strands) { strand in
                        strandBlock(strand).id(strand.id)
                    }
                    quietRow
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 30)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { consumeTarget(proxy) }
            .onChange(of: navigator?.pendingTarget) { _, _ in consumeTarget(proxy) }
        }
        .background(palette.page.ignoresSafeArea())
        .onAppear(perform: refreshGarden)
        .task {
            snapshot.refreshIfNeeded()
            await snapshot.refreshNotificationPermission()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
                refreshGarden()
            }
        }
        .onChange(of: bridge.isConnected) { _, connected in
            refreshGarden()
            if connected { snapshot.refreshIfNeeded() }
        }
        .onChange(of: bridge.lastError) { _, _ in refreshGarden() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            now = Date()
            refreshGarden()
            snapshot.refreshIfNeeded()
            Task { await snapshot.refreshNotificationPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            now = Date()
            refreshGarden()
        }
        .sheet(isPresented: $editingQuiet) {
            StatusQuietEditor(quiet: snapshot.quiet, connected: bridge.isConnected) { start, end in
                snapshot.setQuiet(start: start, end: end)
            }
        }
        .confirmationDialog("检修哪一串", isPresented: $choosingRun, titleVisibility: .visible) {
            ForEach(snapshot.runnable) { source in
                Button(source.title) { snapshot.run(source.id) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack {
            Spacer(minLength: 0)
            if !snapshot.runnable.isEmpty {
                Button {
                    if snapshot.runnable.count == 1, let only = snapshot.runnable.first { snapshot.run(only.id) } else { choosingRun = true }
                } label: {
                    Text(snapshot.running ? "检修中…" : "立即检修")
                        .font(.system(size: 13))
                        .tracking(1)
                        .foregroundStyle(snapshot.running || !bridge.isConnected ? palette.faint : palette.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(palette.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(snapshot.running || !bridge.isConnected)
            }
        }
        .frame(minHeight: 34)
    }

    // MARK: 一个外部源都没有

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusStrandView(beads: [], look: .empty).frame(height: 56)
            Text("还没有检修记录")
                .font(.system(size: 14))
                .foregroundStyle(palette.faint)
            Button { withAnimation(.easeInOut(duration: 0.2)) { showsFormat.toggle() } } label: {
                Text("Mac 上的检修脚本可以把结果报到这里 \(showsFormat ? "⌄" : "›")")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.sub)
            }
            .buttonStyle(.plain)
            if showsFormat {
                Text(Self.formatSample)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.sub)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.top, 26)
    }

    private static let formatSample = """
    POST http://127.0.0.1:<hub 端口>/agent/status/<源 id>
    （只认本机；id 用小写字母、数字、- 和 _）
    {
      "title": "线路检修",
      "checkedAt": "2026-10-31T10:17:00+08:00",
      "staleAfterHours": 36,
      "items": [
        {"name": "线路A", "ok": true},
        {"name": "服务器B", "ok": false, "detail": "连不上"}
      ]
    }
    """

    // MARK: 一串

    private func strandBlock(_ strand: StatusStrand) -> some View {
        let stale = strand.verdict == .stale
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(strand.title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 8)
                Text(timeLabel(strand))
                    .font(.custom("Georgia", size: 13).italic())
                    .foregroundStyle(palette.faint)
            }
            if !strand.isGarden && !bridge.isConnected {
                Text("旧的 · 连不上 Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.faint)
                    .padding(.top, 2)
            }
            StatusStrandView(beads: strand.beads, look: strand.look, beadR: 5, fallKey: strand.isGarden ? nil : strand.id)
                .frame(height: strand.isGarden ? 70 : 96)
            if strand.isGarden {
                VStack(spacing: 0) { ForEach(strand.lines) { line(for: $0) } }
                    .padding(.top, 6)
            } else {
                summary(strand)
                    .font(.system(size: 13))
                    .padding(.top, 2)
                VStack(spacing: 0) {
                    ForEach(strand.badLines) { line(for: $0) }
                    let good = strand.lines.filter { $0.bead != .bad }
                    if !good.isEmpty {
                        if expanded.contains(strand.id) {
                            ForEach(good) { line(for: $0) }
                        } else {
                            fold(strand.id, label: strand.badLines.isEmpty ? "看看这 \(good.count) 条" : "其余 \(good.count) 条都通")
                        }
                    }
                }
                .opacity(stale ? 0.55 : 1)
                .padding(.top, 10)
            }
        }
        .padding(.top, 26)
    }

    private func summary(_ strand: StatusStrand) -> Text {
        let total = strand.lines.count
        switch strand.verdict {
        case .bad(let n):
            return Text("\(total) 条里 ").foregroundColor(palette.sub)
                + Text("\(n) 条不通").foregroundColor(palette.badText).fontWeight(.semibold)
        case .stale:
            let last = strand.checkedAt.map { StatusTime.format($0, now: now) } ?? "没有时间"
            return Text("检修没跑 · 上次 \(last)").foregroundColor(palette.faint)
        default:
            return Text("\(total) 条都通").foregroundColor(palette.sub)
        }
    }

    private func timeLabel(_ strand: StatusStrand) -> String {
        if strand.isGarden { return "刚刚" }
        return strand.checkedAt.map { StatusTime.format($0, now: now) } ?? ""
    }

    private func line(for line: StatusLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            dot(line.bead)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(line.name)
                .font(.system(size: 14))
                .foregroundStyle(palette.ink)
            Spacer(minLength: 12)
            Text(line.detail)
                .font(.system(size: 13))
                .foregroundStyle(line.bead == .bad ? palette.badText : palette.faint)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    @ViewBuilder
    private func dot(_ bead: StatusBead) -> some View {
        switch bead {
        case .ok: Circle().fill(palette.bead).frame(width: 9, height: 9)
        case .bad: Circle().fill(StatusPalette.rose).frame(width: 9, height: 9)
        case .off: Circle().stroke(StatusPalette.hollow, lineWidth: 1).frame(width: 9, height: 9)
        }
    }

    private func fold(_ id: String, label: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { _ = expanded.insert(id) } } label: {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(palette.sub)
                Text("›").foregroundStyle(palette.faint)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.top, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    // MARK: 小芽夜里不吵你

    private var quietRow: some View {
        Button { editingQuiet = true } label: {
            HStack {
                Text("小芽夜里不吵你")
                Spacer(minLength: 8)
                Text("\(snapshot.quiet.start) – \(snapshot.quiet.end) ›")
            }
            .font(.system(size: 13))
            .foregroundStyle(palette.faint)
            .padding(.top, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        .padding(.top, 28)
    }

    private func refreshGarden() {
        snapshot.refreshGarden(profileId: profiles?.currentProfile.id ?? "")
    }

    private func consumeTarget(_ proxy: ScrollViewProxy) {
        guard let target = navigator?.pendingTarget, target.tool == StatusPanelRoute.toolId else { return }
        navigator?.pendingTarget = nil
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target.id, anchor: .top) }
        }
    }
}

/// 改小芽静音时段：按这台设备的时区算
private struct StatusQuietEditor: View {
    let quiet: StatusQuiet
    let connected: Bool
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: $end, displayedComponents: .hourAndMinute)
                } footer: {
                    Text(connected
                         ? "按这台设备的时区（\(TimeZone.current.identifier)）算。静音时横幅照挂，只是不推送，出了时段再补。"
                         : "连上 Mac 才能改。")
                }
            }
            .navigationTitle("小芽夜里不吵你")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(Self.text(start), Self.text(end))
                        dismiss()
                    }
                    .disabled(!connected)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 240)
        #endif
        .onAppear {
            start = Self.date(quiet.start) ?? start
            end = Self.date(quiet.end) ?? end
        }
    }

    private static func date(_ text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }

    private static func text(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
