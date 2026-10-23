import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

/// 单词组件（page2 仪表盘）。
///
/// 三档：
/// - 小方：今日推词（词 + band 标签 + 刷新键）
/// - 长条：今日推词（词 + band + 释义 2 行 + 刷新键）
/// - 大方：缺口提醒（最近 反应慢 / 不认识 的词列表）
///
/// 交互（iOS 原生 widget 模式）：整块 tap 跳 vocab tool。今日推词的两档点进去会直接打开那个词。
/// 刷新键 tap 不触发整块跳转（@AppStorage nonce 累加 → 重选词）。
struct VocabWidgetView: View {
    @Environment(\.isPage2Active) private var desktopActive
    @Environment(\.page2Date) private var desktopDate
    @Environment(\.usesSystemDesktop) private var systemDesktop
    var size: WidgetSize = .medium
    @Environment(\.pinnedOnDesktop) private var pinnedOnDesktop

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \VocabProgress.markedAt, order: .reverse)
    private var allProgress: [VocabProgress]

    @State private var wordOfDay: VocabWord? = nil
    @State private var libraryLoaded = false

    /// 推词偏移 nonce —— 刷新按钮 +1。跨天 dayOfEra 自然变；nonce 不重置无所谓。
    @AppStorage("vocabWidgetWordNonce") private var nonce: Int = 0

    private let slowColor = Color(hex: 0xE89B47)

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if os(macOS)
            .modifier(MacShellWidgetSurface())
            #else
            .modifier(Page2LegacySurface())
            #endif
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { openVocabTool(withWord: wordOfDay?.word) }
            .task(id: "\(dayOfEra)-\(nonce)-\(desktopActive)") {
                guard desktopActive else { return }
                await ensureLibraryLoaded()
                await pickWordOfDay()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch size {
        case .small:  smallBody
        case .medium: mediumBody
        case .large:  largeBody
        }
    }

    // MARK: - 小方：今日推词（精简版）

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.branchIndicator)
                Text("今日推词")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                Spacer()
                refreshButton(small: true)
            }
            Spacer(minLength: 0)
            if let w = wordOfDay {
                Text(w.word)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(w.band)
                    .font(.system(size: 9))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent.opacity(0.55)))
            } else if !libraryLoaded {
                Text("加载…")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    // MARK: - 长条：今日推词（详细版）

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.branchIndicator)
                Text("今日推词")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                Spacer()
                Text(todayShort)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                    .monospacedDigit()
                refreshButton(small: false)
            }

            if let w = wordOfDay {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(w.word)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(w.band)
                        .font(.system(size: 9))
                        .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent.opacity(0.55)))
                    Spacer(minLength: 0)
                }
                Text(w.definition)
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(systemDesktop ? .primary.opacity(0.8) : Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else if !libraryLoaded {
                Text("加载词库…")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    // MARK: - 大方：缺口提醒

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(slowColor)
                Text("缺口提醒")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                Spacer()
                let counts = aggregateCounts()
                Text("慢 \(counts.slow) · 不会 \(counts.unknown)")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                    .monospacedDigit()
            }

            let recent = recentGapWords(limit: 5)
            if recent.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.branchIndicator)
                    Text("没有缺口")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                    Text("先去标几个词试试")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recent, id: \.word) { p in
                        gapRow(p)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func gapRow(_ p: VocabProgress) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(p.status == .slow ? slowColor : Theme.danger)
                .frame(width: 6, height: 6)
            Text(p.word)
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(p.status == .slow ? "反应慢" : "不认识")
                .font(.system(size: 9))
                .foregroundColor(p.status == .slow ? slowColor : Theme.danger)
        }
        // 大方里每行单独可点：点 word 直接跳那一词（盖过外层 widget tap）
        .contentShape(Rectangle())
        .onTapGesture { openVocabTool(withWord: p.word) }
    }

    // MARK: - 刷新按钮（小方/长条共用）

    private func refreshButton(small: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                nonce &+= 1
            }
            #if os(iOS)
            let g = UIImpactFeedbackGenerator(style: .soft)
            g.prepare(); g.impactOccurred()
            #endif
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: small ? 10 : 12, weight: .medium))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                .frame(width: small ? 18 : 22, height: small ? 18 : 22)
                .background(Circle().fill(Theme.accent.opacity(0.55)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 数据 / 选词

    private struct Counts {
        var slow: Int = 0
        var unknown: Int = 0
    }

    private func aggregateCounts() -> Counts {
        var c = Counts()
        for p in allProgress {
            switch p.status {
            case .slow:    c.slow += 1
            case .unknown: c.unknown += 1
            case .known:   break
            }
        }
        return c
    }

    private func recentGapWords(limit: Int) -> [VocabProgress] {
        allProgress.lazy.filter { $0.status == .slow || $0.status == .unknown }.prefix(limit).map { $0 }
    }

    /// day-of-era 数字：跨天才变；同一天稳定。
    private var dayOfEra: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: systemDesktop ? desktopDate : Date()) ?? 0
    }

    private var todayShort: String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f.string(from: Date())
    }

    private func ensureLibraryLoaded() async {
        guard !libraryLoaded else { return }
        try? await VocabLibrary.shared.load()
        libraryLoaded = true
    }

    private func pickWordOfDay() async {
        let words = await VocabLibrary.shared.words
        guard !words.isEmpty else { return }
        let idx = abs(dayOfEra &+ nonce) % words.count
        wordOfDay = words[idx]
    }

    // MARK: - 跳 vocab tool

    private func openVocabTool(withWord word: String?) {
        // 关键：UserDefaults 中转 —— widget tap 时 VocabPanelView 还没渲染，
        // 直接 post 通知会丢（onReceive 还没绑）。VocabPanelView 上来后从
        // UserDefaults 自取 pending word + 消费 + 清空。已显示状态下 onReceive
        // 兜底接也行。
        if let word, !word.isEmpty {
            UserDefaults.standard.set(word, forKey: "pendingVocabJumpWord")
        }
        let userInfo: [String: Any] = word.map { ["word": $0] } ?? [:]
        NotificationCenter.default.post(name: .openVocabTool, object: nil, userInfo: userInfo)
        #if os(iOS)
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare(); g.impactOccurred()
        #endif
    }
}

// MARK: - Notification key

extension Notification.Name {
    /// Widget tap 时 post。可在 userInfo["word"] 传词面 → VocabPanelView 接收后 jumpToWord。
    static let openVocabTool = Notification.Name("openVocabTool")
    /// R3-3 考古按钮回投到达（userInfo: word/ok）→ 词详情刷新语料。
    static let vocabCorpusArrived = Notification.Name("vocabCorpusArrived")
}
