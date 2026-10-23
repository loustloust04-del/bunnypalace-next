import SwiftUI

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
#if os(iOS)

// MARK: - Settings Search Panel (iOS)

/// 设置搜索的展开态：暗背景 + 玻璃胶囊输入框 + 「推荐 / 结果」列表。
/// 结构照搬 rootshell（MIT）`UI/Settings/SettingsView.swift:1074-1263`（spring 0.34/0.9、
/// 回车直达第一条、空态带建议词），视觉换成项目的淡雾玻璃 + 暖奶白。
/// 收起态就是根列表底部原有的 `SettingsSearchBar` 胶囊（视觉没动）。
struct SettingsSearchPanel: View {
    @Binding var isPresented: Bool
    /// 只在有跳转目标时回调；占位条目在面板内自己消化（Toast）
    let onSelect: (SettingsSearchEntry) -> Void

    @State private var searchText = ""
    @State private var toast: String? = nil
    @FocusState private var focused: Bool

    private var entries: [SettingsSearchEntry] {
        SettingsSearchEntry.filtered(for: searchText)
    }

    private var isEmptyQuery: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                    .transition(.opacity)

                panel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    // 宽窗（iPad）下面板夹宽居中，不再拉成一条满屏横带
                    .frame(maxWidth: Theme.contentMaxWidth)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: isPresented)
        .onChange(of: isPresented) { _, presented in
            if presented {
                // 同帧聚焦吃不到（面板还没上树），延一拍——rootshell :1116-1125 同款
                DispatchQueue.main.async { focused = true }
            } else {
                focused = false
                searchText = ""
                toast = nil
            }
        }
    }

    // MARK: 面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let toast {
                Text(toast)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.branchIndicator))
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }

            searchField

            Text(isEmptyQuery ? "推荐" : "结果")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 4)

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            resultRow(entry)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 340)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .padding(14)
        // 粟粟 08-31：「灰灰的不够透明」——ultraThinMaterial 换真液态玻璃。
        // 玻璃只上这一层（内层输入框/行改白雾填充，避免玻璃套玻璃，穿模旧案在案）；
        // 非 interactive，穿模的弹缩场景不涉及。
        .glassEffect(.regular.tint(Color.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Theme.accent.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: Theme.cardShadow, radius: 18, y: 8)
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    /// 输入框：面板本体已是玻璃，这里退成白雾胶囊（玻璃不套玻璃）
    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textMuted)
                TextField("搜索设置", text: $searchText)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        if let first = entries.first { select(first) }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.38)))
            .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 0.8))

            Button("取消") { isPresented = false }
                .font(.system(size: 16))
                .foregroundColor(Theme.branchIndicator)
                .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26))
                .foregroundColor(Theme.textMuted.opacity(0.6))
            Text("没有找到")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("换个说法试试：外观、记忆、权限、快捷键")
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: 结果行

    /// 行背景走 material 不上 glassEffect：玻璃在 iPhone 14 是热点，只给胶囊和选项单用
    private func resultRow(_ entry: SettingsSearchEntry) -> some View {
        Button {
            select(entry)
        } label: {
            HStack(spacing: 12) {
                AppIconView(name: entry.systemImage, size: 15, tint: Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent.opacity(0.55)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 15))
                        .foregroundColor(entry.isPlaceholder ? Theme.textMuted : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if entry.isPlaceholder {
                    Text("敬请期待")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            // 面板换玻璃后 thinMaterial 显灰，行改白雾填充（同输入框语言）
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.32)))
        }
        .buttonStyle(.plain)
    }

    private func select(_ entry: SettingsSearchEntry) {
        guard !entry.isPlaceholder else {
            // 全局 ToastCenter 挂在 ContentView 根上，被设置 sheet 盖住（ToastCenter.swift:6 记着这条），
            // 所以面板自己出一颗
            toast = "敬请期待"
            return
        }
        isPresented = false
        onSelect(entry)
    }
}

// MARK: - Help Menu (iOS)

/// 搜索胶囊右端「？」弹的玻璃选项单（浮层，不是 sheet）：新手引导 / App 文档（未写，占位）。
/// 按钮走 `.buttonStyle(.glass)` —— iOS 26 铁律，`.glassEffect()+.plain` 会吞 hit test
/// （`ScrollToBottomButton.swift:5-8` 与 `CardFlowView.swift:1553` 两处独立记载）。
struct SettingsHelpMenu: View {
    @Binding var isPresented: Bool
    let onOnboarding: () -> Void
    let onManual: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isPresented {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        isPresented = false
                        onOnboarding()
                    } label: {
                        HStack(spacing: 8) {
                            AppIconView(name: "ri-compass-3", size: 14, tint: nil)
                            Text("新手引导")
                                .font(.system(size: 15))
                        }
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)

                    Button {
                        isPresented = false
                        onManual()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "book")
                                .font(.system(size: 14))
                            Text("App 文档")
                                .font(.system(size: 15))
                        }
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                }
                .padding(10)
                .frame(width: 220)
                // 跟搜索面板同语言：液态玻璃（非 interactive；里面按钮自己是 .glass，层级各弹各的）
                .glassEffect(.regular.tint(Color.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Theme.accent.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: Theme.cardShadow, radius: 14, y: 6)
                .padding(.trailing, 28)
                .padding(.bottom, 58)   // 让开底部那颗搜索胶囊
                .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isPresented)
    }
}

#endif
