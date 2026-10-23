#if os(iOS)
import SwiftUI

/// 对话内查找顶栏（plan-chat-find 方案 2）：玻璃胶囊输入框 + 圆形 ✕，搜索时替换聊天页顶栏
/// 查找态所有玻璃按钮 / 胶囊统一 44pt（和聊天页顶栏的 ‹ ⋯ 同规格）
enum ChatFindMetrics {
    static let size: CGFloat = 44
}

struct ChatFindTopBar: View {
    @Bindable var viewModel: ConversationViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .opacity(viewModel.inConvSearching ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .opacity(viewModel.inConvSearching ? 1 : 0)
                }
                .frame(width: 18)
                TextField("在对话中查找", text: $viewModel.inConvQuery)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit { focused = false }
                    .onChange(of: viewModel.inConvQuery) { _, _ in viewModel.scheduleInConvSearch() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Capsule())
            .onTapGesture { focused = true }
            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)

            Button {
                focused = false
                viewModel.endInConvSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            // 玻璃按钮只能用 .buttonStyle(.glass)：glassEffect + .plain 会吞点击（feedback_ios26_glass_button，09-26 ✕ 点不掉）
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("退出查找")
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
#endif

#if os(iOS)
/// 对话内查找底部面板（plan-chat-find 方案 3）：搜索时顶替输入栏，跟着键盘走（InputBarStack 分支）
struct ChatFindPanel: View {
    @Bindable var viewModel: ConversationViewModel
    @State private var showDatePicker = false
    @State private var pickedDay = Date()
    @State private var dayRange: ClosedRange<Date>? = nil
    @State private var confirmedDay: Date? = nil

    private var hasHits: Bool { !viewModel.inConvHits.isEmpty }

    private var status: String? {
        if let note = viewModel.inConvSearchNote { return note }
        let total = viewModel.inConvHits.count
        if total > 0 {
            if viewModel.inConvListMode { return "\(total) 条" }
            return "\(total - (viewModel.inConvHitCursor ?? total - 1)) / \(total)"
        }
        let typed = !viewModel.inConvQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return typed && !viewModel.inConvSearching ? "无结果" : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: openDatePicker) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 24, height: ChatFindMetrics.size)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("跳到某天")
                if let status {
                    Text(status)
                        .font(.system(size: 13.5))
                        .foregroundColor(viewModel.inConvSearchNote == nil ? Theme.textPrimary : Theme.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: ChatFindMetrics.size)
            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)

            Spacer(minLength: 0)

            Button {
                viewModel.inConvListMode.toggle()
            } label: {
                Text(viewModel.inConvListMode ? "聊天" : "列表")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .opacity(hasHits ? 1 : 0)
            .allowsHitTesting(hasHits)
        }
        .padding(.horizontal, 12)
        .frame(height: ChatFindMetrics.size)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .sheet(isPresented: $showDatePicker, onDismiss: {
            guard let day = confirmedDay else { return }
            confirmedDay = nil
            viewModel.jumpToDay(day)
        }) {
            datePickerSheet
        }
    }

    /// 初值 = 当前停的那条命中的日期（没有就最后一条消息）；可选范围 = 这条路径第一条到最后一条消息
    private func openDatePicker() {
        let dates = viewModel.currentPath.compactMap(\.createTime)
        if let lo = dates.min(), let hi = dates.max() { dayRange = Calendar.current.startOfDay(for: lo)...hi } else { dayRange = nil }
        let current = viewModel.inConvHitCursor.flatMap { viewModel.inConvHits.indices.contains($0) ? viewModel.inConvHits[$0].date : nil }
        pickedDay = current ?? dates.last ?? Date()
        showDatePicker = true
    }

    private var datePickerSheet: some View {
        VStack(spacing: 12) {
            if let dayRange {
                DatePicker("跳到某天", selection: $pickedDay, in: dayRange, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            } else {
                DatePicker("跳到某天", selection: $pickedDay, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
            Button {
                confirmedDay = pickedDay
                showDatePicker = false
            } label: {
                Text("跳到这天")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .tint(Theme.branchIndicator)
        .padding(20)
        .presentationDetents([.height(500)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.mainBg)
    }
}
#endif

#if os(iOS)
/// 查找上下钮（plan-chat-find 方案 6）：浮在聊天区右下、面板上方；↑ 更旧 ↓ 更新，到最旧 ↑ 置灰
struct ChatFindNavButtons: View {
    let isVisible: Bool
    let canGoOlder: Bool
    let onOlder: () -> Void
    let onNewer: () -> Void

    var body: some View {
        // ↑↓ 合成一个竖胶囊（粟粟 09-25）
        VStack(spacing: 0) {
            navButton("chevron.up", enabled: canGoOlder, action: onOlder)
                .accessibilityLabel("更早的结果")
            Rectangle()
                .fill(Theme.textMuted.opacity(0.25))
                .frame(width: 18, height: 0.5)
            navButton("chevron.down", enabled: true, action: onNewer)
                .accessibilityLabel("更新的结果")
        }
        .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 8)
        .animation(.spring(duration: 0.3), value: isVisible)
        .allowsHitTesting(isVisible)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(enabled ? Theme.textPrimary : Theme.textMuted.opacity(0.5))
                .frame(width: ChatFindMetrics.size, height: ChatFindMetrics.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
#endif

#if os(iOS)
/// 查找列表模式（plan-chat-find 方案 8）：盖在聊天区上，最新在上；点一行 = 跳过去并切回聊天
struct ChatFindListView: View {
    let hits: [InConvFind.Hit]
    let terms: [String]
    let avatars: ChatAvatars
    /// 面板顶到聊天区底的距离（键盘开着时含键盘）
    let bottomInset: CGFloat
    let onSelect: (Int) -> Void

    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(hits.enumerated().reversed()), id: \.element.id) { index, hit in
                    Button { onSelect(index) } label: { row(hit) }
                        .buttonStyle(.plain)
                    Divider().padding(.leading, 60)
                }
            }
        }
        .contentMargins(.top, 60, for: .scrollContent)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .background(Theme.mainBg.ignoresSafeArea())
    }

    private func row(_ hit: InConvFind.Hit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarBox(size: 34, image: hit.isUser ? avatars.user : avatars.assistant)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(hit.isUser ? userName : assistantName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let date = hit.date {
                        Text(MacSearchQuery.dateLabel(date))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                Text(InConvFind.highlighted(hit.excerpt, terms: terms))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
#endif
