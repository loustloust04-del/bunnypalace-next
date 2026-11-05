import SwiftUI

/// A4-2 版本历史的纯逻辑：总开关、列表每版的增删统计、来源 / 时间文案
enum FileVersionHistory {
    struct Entry: Identifiable, Equatable {
        let version: FileVersionStore.Version
        /// 相对上一版（更老的那版）；最老一版 / 内容读不出 → nil
        let added: Int?
        let removed: Int?
        let isOldest: Bool
        /// 和编辑器现在的内容一字不差
        let matchesCurrent: Bool

        var id: String { version.id }
    }

    struct Restored {
        let text: String
        let date: Date
    }

    /// versions 新→旧（同 `FileVersionStore.versions`）
    static func entries(_ versions: [FileVersionStore.Version], contents: [String: String], current: String) -> [Entry] {
        versions.indices.map { i in
            let version = versions[i]
            let text = contents[version.id]
            var added: Int?, removed: Int?
            if i + 1 < versions.count, let text, let older = contents[versions[i + 1].id] {
                let diff = LineDiff.compute(old: older, new: text)
                added = diff.added
                removed = diff.removed
            }
            return Entry(version: version, added: added, removed: removed,
                         isOldest: i == versions.count - 1, matchesCurrent: text == current)
        }
    }

    /// 设置 → 文件库「记录版本」总开关（默认开）：文件库所有文件 + 有稳定 key 的长文本都记
    static let enabledKey = "fileVersionHistoryEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// 编辑器真正拿来记版本的 key：总开关关了 = 不记
    static func recordingKey(_ key: FileVersionStore.Key?, enabled: Bool) -> FileVersionStore.Key? {
        enabled ? key : nil
    }

    static func sourceLabel(_ source: FileVersionStore.Source) -> String {
        switch source {
        case .manualSave: "保存"
        case .autoSave: "自动保存"
        case .external: "载入"
        case .restore: "恢复"
        }
    }

    static func timeText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 " + clock }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 " + clock
        }
        if calendar.component(.year, from: now) == c.year { return "\(c.month ?? 0)月\(c.day ?? 0)日 " + clock }
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 " + clock
    }
}

/// 增删色：取文件夹调色板里的薄荷 / 玫瑰，半透明铺底，字不着色（不做绿套绿）
private enum FileVersionDiffPalette {
    static let addedFill = Color(hex: 0x8FB79D).opacity(0.22)
    static let removedFill = Color(hex: 0xD99AA5).opacity(0.24)
    static let addedInk = Color(hex: 0x5F8F74)
    static let removedInk = Color(hex: 0xC27F8F)
    /// 行内真正改了的那几个字：同色深一档的半透明底，字照旧棕黑
    static let addedMark = Color(hex: 0x8FB79D).opacity(0.5)
    static let removedMark = Color(hex: 0xD99AA5).opacity(0.55)
}

/// 编辑器「…」→「版本历史」：列表 → 点一版看它和编辑器当前内容的 diff → 恢复。
/// 恢复只把文本交回编辑器，不直接写文件；保存时编辑器自己再记一版。
struct FileVersionHistoryView: View {
    @Environment(\.dismiss) private var dismiss

    let key: FileVersionStore.Key
    let currentContent: String
    let onRestore: (FileVersionHistory.Restored) -> Void
    var store: FileVersionStore = .shared

    @State private var entries: [FileVersionHistory.Entry]?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let entries, !entries.isEmpty {
                    list(entries)
                } else {
                    VStack(spacing: 8) {
                        if entries == nil && loadError == nil {
                            ProgressView()
                        } else {
                            Text(loadError ?? "还没有版本记录")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.mainBg)
            .navigationTitle("版本历史")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 600)
        #else
        .presentationBackground(Theme.mainBg)
        #endif
        .task { await load() }
    }

    private func list(_ entries: [FileVersionHistory.Entry]) -> some View {
        List(entries) { entry in
            NavigationLink {
                FileVersionDiffView(key: key, entry: entry, currentContent: currentContent, store: store) { restored in
                    onRestore(restored)
                    dismiss()
                }
            } label: {
                row(entry)
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ entry: FileVersionHistory.Entry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(FileVersionHistory.timeText(entry.version.date))
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 6) {
                    Text(FileVersionHistory.sourceLabel(entry.version.source))
                    if entry.matchesCurrent { Text("· 和现在一样") }
                }
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 8)
            stats(entry)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func stats(_ entry: FileVersionHistory.Entry) -> some View {
        if let added = entry.added, let removed = entry.removed {
            HStack(spacing: 6) {
                Text("+\(added)").foregroundColor(FileVersionDiffPalette.addedInk)
                Text("−\(removed)").foregroundColor(FileVersionDiffPalette.removedInk)
            }
            .font(.system(size: Theme.F.secondary, design: .monospaced))
        } else if entry.isOldest {
            Text("最早")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
        }
    }

    private func load() async {
        do {
            let versions = try await store.versions(key: key)
            var contents: [String: String] = [:]
            for version in versions {
                if let text = try await store.content(key: key, id: version.id) { contents[version.id] = text }
            }
            let current = currentContent
            entries = await Task.detached(priority: .userInitiated) {
                FileVersionHistory.entries(versions, contents: contents, current: current)
            }.value
        } catch {
            loadError = "版本记录读不了：\(error.localizedDescription)"
        }
    }
}

/// 这一版 vs 编辑器现在的内容：删行 = 这一版有、现在没有；增行 = 现在有、这一版没有
struct FileVersionDiffView: View {
    let key: FileVersionStore.Key
    let entry: FileVersionHistory.Entry
    let currentContent: String
    let store: FileVersionStore
    let onRestore: (FileVersionHistory.Restored) -> Void

    @State private var versionText: String?
    @State private var prepared: Prepared?
    @State private var expandedFolds: Set<Int> = []
    @State private var loadError: String?
    @State private var confirmRestore = false

    private struct Prepared: Sendable {
        let diff: LineDiff.Result
        let highlights: [[Range<Int>]]
        let segments: [LineDiff.Segment]
    }

    private enum Row: Identifiable {
        case line(Int)
        case fold(Range<Int>)

        var id: Int {
            switch self {
            case .line(let index): index
            case .fold(let range): -1 - range.lowerBound
            }
        }
    }

    private var diff: LineDiff.Result? { prepared?.diff }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            if let prepared {
                if prepared.diff.lines.isEmpty {
                    placeholder("两边都是空的")
                } else if prepared.diff.added == 0 && prepared.diff.removed == 0 {
                    placeholder("和现在一样")
                } else {
                    lines(prepared)
                }
            } else {
                placeholder(loadError)
            }
        }
        .background(Theme.mainBg)
        .navigationTitle(FileVersionHistory.timeText(entry.version.date))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("恢复到这版") { confirmRestore = true }
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(versionText == nil || versionText == currentContent)
            }
        }
        .confirmationDialog("恢复到这一版？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复") {
                guard let versionText else { return }
                onRestore(FileVersionHistory.Restored(text: versionText, date: entry.version.date))
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("编辑器里的内容会换成这一版，保存后才生效；没保存前可以在编辑器顶部换回。")
        }
        .task { await load() }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Text(FileVersionHistory.sourceLabel(entry.version.source))
                .foregroundColor(Theme.textMuted)
            if let diff {
                if diff.added == 0 && diff.removed == 0 {
                    Text("和现在一样").foregroundColor(Theme.textMuted)
                } else {
                    // 讲「这版之后又改了什么」：删行 = 这版有现在没了，增行 = 之后新加的
                    Text("这版之后").foregroundColor(Theme.textMuted)
                    if diff.removed > 0 {
                        Text("删了 \(diff.removed) 行").foregroundColor(FileVersionDiffPalette.removedInk)
                    }
                    if diff.added > 0 {
                        Text("加了 \(diff.added) 行").foregroundColor(FileVersionDiffPalette.addedInk)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: Theme.F.caption))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func placeholder(_ text: String?) -> some View {
        VStack {
            if let text {
                Text(text)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 单列行号 = 现在的行号；删行（只在这版里）不标号，靠「−」认
    private func lines(_ prepared: Prepared) -> some View {
        let digits = String(max(prepared.diff.lines.last(where: { $0.newNumber != nil })?.newNumber ?? 1, 1)).count
        let numberWidth = CGFloat(digits) * Theme.F.mono * 0.62 + 8
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows(prepared)) { row in
                    switch row {
                    case .line(let index):
                        lineRow(prepared.diff.lines[index], highlights: prepared.highlights[index], numberWidth: numberWidth)
                    case .fold(let range):
                        foldRow(range, numberWidth: numberWidth)
                    }
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
    }

    private func rows(_ prepared: Prepared) -> [Row] {
        var rows: [Row] = []
        for segment in prepared.segments {
            switch segment {
            case .shown(let range):
                rows.append(contentsOf: range.map(Row.line))
            case .folded(let range):
                if expandedFolds.contains(range.lowerBound) {
                    rows.append(contentsOf: range.map(Row.line))
                } else {
                    rows.append(.fold(range))
                }
            }
        }
        return rows
    }

    private func foldRow(_ range: Range<Int>, numberWidth: CGFloat) -> some View {
        Button {
            expandedFolds.insert(range.lowerBound)
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: numberWidth + 20, height: 1)
                Text("… \(range.count) 行没变")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lineRow(_ line: LineDiff.Line, highlights: [Range<Int>], numberWidth: CGFloat) -> some View {
        let sign: String
        let fill: Color
        let mark: Color
        switch line.change {
        case .added: sign = "+"; fill = FileVersionDiffPalette.addedFill; mark = FileVersionDiffPalette.addedMark
        case .removed: sign = "−"; fill = FileVersionDiffPalette.removedFill; mark = FileVersionDiffPalette.removedMark
        case .unchanged: sign = " "; fill = .clear; mark = .clear
        }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.change == .removed ? "" : line.newNumber.map(String.init) ?? "")
                .frame(width: numberWidth, alignment: .trailing)
                .foregroundColor(Theme.textMuted)
            Text(sign)
                .frame(width: 20)
                .foregroundColor(Theme.textSecondary)
            Text("\(Text(marked(line.text, highlights: highlights, mark: mark)))\(Text(line.missingNewline && line.change != .unchanged ? "  ⏎ 末尾无换行" : "").foregroundColor(Theme.textMuted))")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: Theme.F.mono, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 10)
        .background(fill)
    }

    private func marked(_ text: String, highlights: [Range<Int>], mark: Color) -> AttributedString {
        var string = AttributedString(text.isEmpty ? " " : text)
        string.foregroundColor = Theme.textPrimary
        guard !text.isEmpty else { return string }
        let characters = string.characters
        let count = characters.count
        for range in highlights where range.lowerBound < count {
            let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let upper = characters.index(lower, offsetBy: min(range.upperBound, count) - range.lowerBound)
            string[lower..<upper].backgroundColor = mark
        }
        return string
    }

    private func load() async {
        do {
            guard let text = try await store.content(key: key, id: entry.version.id) else {
                loadError = "这一版的内容找不到了"
                return
            }
            versionText = text
            let current = currentContent
            prepared = await Task.detached(priority: .userInitiated) {
                let diff = LineDiff.compute(old: text, new: current)
                return Prepared(diff: diff, highlights: LineDiff.inlineHighlights(diff.lines),
                                segments: LineDiff.segments(diff.lines))
            }.value
        } catch {
            loadError = "读不了这一版：\(error.localizedDescription)"
        }
    }
}

/// 「…」→「版本历史」但记不了：总开关关着（给「去设置开启」）/ 这段文字还没有固定 id（新建的条目）
struct FileVersionHistoryUnavailableView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @State private var showsSettings = false
    #endif
    let recordingOff: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(Theme.textMuted)
                Text(recordingOff ? "版本记录已关闭" : "还不能记录版本")
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text(recordingOff
                     ? "打开后每次保存都存一份快照，在这里对比、恢复。"
                     : "这段文字还没有固定的位置（比如刚新建的条目），暂时记不了版本。")
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                if recordingOff {
                    Button("去设置开启") { openFileLibrarySettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: Theme.F.secondary, weight: .semibold))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.top, 6)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.mainBg)
            .navigationTitle("版本历史")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.mainBg, for: .navigationBar)
            // 设置是 ContentView 根上的 sheet，编辑器这层 sheet 里够不着：直接推同一个「设置 → 文件库」页，开关那张卡闪一下
            .navigationDestination(isPresented: $showsSettings) {
                FileLibrarySettingsTab()
                    .tint(Theme.branchIndicator)
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 320)
        #endif
    }

    private func openFileLibrarySettings() {
        #if os(macOS)
        // mac 设置是独立窗口：编辑器不用关，设置窗口跳到文件库页
        SettingsView.requestMacTab(.fileLibrary)
        openSettings()
        dismiss()
        #else
        SettingsSearchRouter.shared.request(anchor: "leaf-file-versions")
        showsSettings = true
        #endif
    }
}
