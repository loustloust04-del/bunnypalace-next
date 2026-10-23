import SwiftUI

// MARK: - 小芽 v2 · 提案卡（plan-小芽-v2 §4.2；设计 design-小芽-v2.html §03）
// 待盖章：旧的划掉、新的荧光笔；盖章后按钮收起，椭圆邮戳落下，左下「撤销」。

struct AssistantProposalCard: View {
    let action: AssistantAction
    let skin: XiaoyaSkin
    let canUndo: Bool
    let beyondRetention: Bool
    /// 盖章时间（账本里那笔的日期），邮戳上印这个
    let stampDate: Date
    let onStamp: () -> Void
    let onDiscard: () -> Void
    let onUndo: () -> Void

    @State private var confirmDestructive = false
    /// 旧提案提示里的名字读 AssistantPrompts。B-8（plan-paging-decouple B-0 表 1）：翻页不再重交 rootView 后，这个值要自带失效通道——声明即订阅
    @AppStorage(AssistantPrompts.nameKey) private var xiaoyaNameSubscription = ""
    @AppStorage("settings.proMode") private var proModeSubscription = false
    private static let fieldLimit = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(action.change?.category ?? "提案")
                .font(.system(size: 11))
                .tracking(1.2)
                .foregroundStyle(skin.inkMuted)
            Text(action.change?.title ?? action.title)
                .font(.system(size: Theme.F.body + 1, weight: .semibold))
                .foregroundStyle(skin.ink)
                .padding(.top, 1)
                .padding(.bottom, 8)
            if action.status == .pending {
                tryOn.padding(.bottom, 8)
            }
            if showsDiff {
                diff
                    .padding(.top, 8)
                    .overlay(alignment: .top) { DashedRule().stroke(skin.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1) }
            }
            footer.padding(.top, 12)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(skin.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(skin.line, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if action.status == .approved || action.status == .undone {
                ApprovalSeal(text: action.status == .approved ? "已批准" : "已撤销",
                             date: stampDate, color: action.status == .approved ? skin.ink : skin.inkMuted)
                    .frame(width: 104, height: 70)
                    .rotationEffect(.degrees(-12))
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
                    .transition(.scale(scale: 1.5).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .opacity(action.status == .discarded || action.status == .legacy ? 0.5 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: action.status)
        .confirmationDialog("确定删除这条？", isPresented: $confirmDestructive, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onStamp)
            Button("再想想", role: .cancel) {}
        } message: {
            Text("删掉之后在账本里还能撤回。")
        }
    }

    // MARK: 试穿（P3 外观提案）：改前 / 盖章后两块小样，直接渲染真实的舞台 / 主屏，不走全局预览

    @ViewBuilder
    private var tryOn: some View {
        switch action.change {
        case .stageTheme(let before, let after):
            beforeAfter(miniStage(before), miniStage(after))
        #if os(iOS)
        case .page2Appearance(_, let after):
            let current = Page2AppearanceStore.shared.value
            beforeAfter(miniDesktop(current), miniDesktop(after.applied(to: current)))
        case .appIcon(let toolId, _, _, let after):
            let current = Page2AppearanceStore.shared.value
            let changed: Page2Appearance = { var a = current; a.icons[toolId] = after; return a }()
            beforeAfter(miniIcon(toolId, current), miniIcon(toolId, changed))
        #endif
        default:
            EmptyView()
        }
    }

    private func beforeAfter<A: View, B: View>(_ before: A, _ after: B) -> some View {
        HStack(alignment: .center, spacing: 10) {
            labeled(before, "现在")
            Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(skin.inkMuted)
            labeled(after, "盖章后")
        }
        .frame(maxWidth: .infinity)
    }

    private func labeled<V: View>(_ view: V, _ label: String) -> some View {
        VStack(spacing: 4) {
            view
            Text(label).font(.system(size: 11)).foregroundStyle(skin.inkMuted)
        }
    }

    private func miniStage(_ raw: String) -> some View {
        XiaoyaStageBackdrop(theme: XiaoyaStageTheme(rawValue: raw) ?? .mint, dark: Theme.activeScheme == .dark, collapsed: false)
            .overlay(alignment: .bottomLeading) {
                Image(XiaoyaMood.smirk.assetName).resizable().scaledToFit().frame(height: 34)
                    .shadow(color: .black.opacity(0.28), radius: 0, x: 1, y: 2)
                    .padding(.leading, 8).padding(.bottom, XiaoyaStageBackdrop.edgeDepth + 3)
            }
            .frame(width: 118, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    #if os(iOS)
    private static let desktopSize = CGSize(width: 390, height: 520)
    private static let desktopScale: CGFloat = 0.29

    /// 迷你主屏：真实壁纸 + 前 12 个 app 的真实图标，按传入的外观渲染
    private func miniDesktop(_ appearance: Page2Appearance) -> some View {
        ZStack(alignment: .top) {
            Page2WallpaperView(appearance: appearance)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 18), count: 4), spacing: 26) {
                ForEach(Array(RightPanelToolManager.builtInTools.prefix(12))) { tool in
                    Page2AppIcon(tool: tool, side: 60, interactive: false, decorative: true, appearanceOverride: appearance)
                }
            }
            .padding(.top, 90)
        }
        .frame(width: Self.desktopSize.width, height: Self.desktopSize.height)
        .environment(\.colorScheme, scheme(for: appearance))
        .scaleEffect(Self.desktopScale, anchor: .topLeading)
        .frame(width: Self.desktopSize.width * Self.desktopScale, height: Self.desktopSize.height * Self.desktopScale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }

    private func miniIcon(_ toolId: String, _ appearance: Page2Appearance) -> some View {
        ZStack {
            Page2WallpaperView(appearance: appearance)
            if let tool = RightPanelToolManager.builtInTools.first(where: { $0.id == toolId }) {
                Page2AppIcon(tool: tool, side: 56, interactive: false, decorative: true, appearanceOverride: appearance)
            }
        }
        .frame(width: 96, height: 96)
        .environment(\.colorScheme, scheme(for: appearance))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private func scheme(for appearance: Page2Appearance) -> ColorScheme {
        switch appearance.luminosity {
        case "dark": .dark
        case "light": .light
        default: Theme.activeScheme
        }
    }
    #endif

    /// 盖过章 / 撤过的卡只留新内容，不再摊开整张对照
    private var showsDiff: Bool { action.change != nil }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(action.change?.fields ?? []) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).font(.system(size: 11.5)).foregroundStyle(skin.inkMuted)
                    if let old = field.old, action.status == .pending || action.status == .failed {
                        Text(clip(old.isEmpty ? "（空）" : old))
                            .font(.system(size: Theme.F.secondary))
                            .foregroundStyle(skin.inkMuted)
                            .strikethrough(true, color: Color(red: 0.71, green: 0.40, blue: 0.29).opacity(0.6))
                    }
                    if let new = field.new {
                        Text(clip(new.isEmpty ? "（空）" : new))
                            .font(.system(size: Theme.F.secondary))
                            .foregroundStyle(skin.ink)
                            .padding(.horizontal, 1)
                            .background(alignment: .bottom) {
                                Theme.branchIndicator.opacity(action.status == .pending ? 0.28 : 0).frame(height: 7)
                            }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, action.status == .approved ? 60 : 0)
    }

    @ViewBuilder
    private var footer: some View {
        switch action.status {
        case .pending:
            HStack(spacing: 8) {
                Spacer()
                Button(action: onDiscard) {
                    Text("不要")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundStyle(skin.inkSoft)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .overlay(Capsule().stroke(skin.line, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    if action.tier == .destructive { confirmDestructive = true } else { onStamp() }
                } label: {
                    Label("盖章", systemImage: "checkmark")
                        .font(.system(size: Theme.F.secondary, weight: .semibold))
                        .foregroundStyle(skin.paper)
                        .padding(.horizontal, 15).padding(.vertical, 7)
                        .background(skin.ink, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        case .approved:
            HStack(spacing: 10) {
                if canUndo {
                    Button("撤销", action: onUndo)
                        .buttonStyle(.plain)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundStyle(skin.inkSoft)
                        .underline()
                } else if beyondRetention {
                    note("超出撤销保留范围")
                }
                if let failure = action.failure { note(failure) }
            }
            .frame(minHeight: 22)
        case .discarded:
            note("没要")
        case .undone:
            note("已撤销")
        case .failed:
            note(action.failure ?? "没能落地", color: Theme.danger)
        case .legacy:
            note("旧版提案，已失效——让\(AssistantPrompts.assistantName)重新提一次")
        }
    }

    private func note(_ text: String, color: Color? = nil) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color ?? skin.inkMuted)
    }

    private func clip(_ s: String) -> String {
        s.count <= Self.fieldLimit ? s : String(s.prefix(Self.fieldLimit)) + "…"
    }
}

/// 椭圆双线邮戳：已批准 / 已撤销 + 日期
struct ApprovalSeal: View {
    let text: String
    let date: Date
    let color: Color

    var body: some View {
        ZStack {
            Ellipse().stroke(color, lineWidth: 2.5)
            Ellipse().inset(by: 6).stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2, 2.5]))
            VStack(spacing: 1) {
                Text(text).font(.system(size: 16, weight: .heavy)).tracking(3)
                Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))).font(.system(size: 9)).tracking(1.5)
            }
            .foregroundStyle(color)
        }
        .opacity(0.9)
    }
}

private struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}
