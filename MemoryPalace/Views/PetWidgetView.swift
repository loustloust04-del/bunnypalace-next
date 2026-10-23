import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 桌面宠物小组件 —— 迷你终端卡里养一只 ASCII 猫。支持三档尺寸。
struct PetWidgetView: View {
    @Environment(\.isPage2Active) private var desktopActive
    @Environment(\.page2Date) private var desktopDate
    @Environment(\.usesSystemDesktop) private var systemDesktop
    var size: WidgetSize = .large
    @Environment(\.pinnedOnDesktop) private var pinnedOnDesktop
    @State private var pet = PetManager.shared
    @State private var showRename = false
    @State private var draftName = ""

    // 互动时从猫脸往上飘的反馈符号（<>< 鱼 / ♥ 爱心 / zzz）
    @State private var reactionID: UUID?
    @State private var reactionText = ""
    @State private var reactionColor = Color.clear

    private let rose = Color(red: 0.82, green: 0.54, blue: 0.55)
    private var s: PetState { pet.state }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if os(macOS)
            .modifier(MacShellWidgetSurface())
            #else
            .modifier(Page2LegacySurface())
            #endif
            .overlay(alignment: .top) {
                if let id = reactionID {
                    FloatingReaction(text: reactionText, color: reactionColor)
                        .id(id)
                        .padding(.top, 34)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { if desktopActive { pet.wakeUp() } }
            .onChange(of: desktopActive) { _, active in if active { pet.wakeUp() } }
            .alert("给它起个名字", isPresented: $showRename) {
                TextField("名字", text: $draftName)
                Button("取消", role: .cancel) {}
                Button("好") { pet.rename(draftName) }
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

    // 小方：只露脸 + 名（glance）
    private var smallBody: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            catFace(17)
            Text(s.name)
                #if os(macOS)
                .font(ShellStyle.bodyFont)
                .foregroundColor(Theme.textPrimary)
                #else
                .font(.system(size: Theme.F.secondary, weight: .semibold, design: systemDesktop ? .default : .monospaced))
                .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                #endif
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
    }

    // 长条：脸在左，右边名+条+按钮
    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            HStack(alignment: .center, spacing: 14) {
                catFace(16)
                VStack(alignment: .leading, spacing: 7) {
                    nameRow
                    bars
                    actions
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    // 大方：完整版
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    catFace(18)
                    nameRow
                    Spacer(minLength: 0)
                }
                bars
                Text("“\(pet.currentLine)”")
                    .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                    .foregroundColor(faceColor)
                    .animation(.easeInOut(duration: 0.2), value: pet.currentLine)
                actions
            }
            .padding(14)
        }
    }

    // MARK: - 复用片段

    private var titleBar: some View {
        HStack(spacing: 6) {
            if !systemDesktop {
            Circle().fill(rose).frame(width: 8, height: 8)
            Circle().fill(Theme.branchIndicator).frame(width: 8, height: 8)
            Circle().fill(Theme.textMuted.opacity(0.5)).frame(width: 8, height: 8)
            }
            Spacer()
            Text(systemDesktop ? "宠物" : "pet")
                .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(systemDesktop ? Color.clear : Theme.sidebarBg.opacity(0.7))
    }

    private func catFace(_ fontSize: CGFloat) -> some View {
        Group {
            if systemDesktop {
                Image(systemName: "cat.fill").font(.system(size: 44, weight: .light))
            } else {
        VStack(alignment: .leading, spacing: 1) {
            Text(" /\\_/\\")
            Text(face)
            Text(" > ^ <")
        }
            }
        }
        .font(.system(size: fontSize, weight: .medium, design: systemDesktop ? .default : .monospaced))
        .foregroundColor(faceColor)
        .contentShape(Rectangle())   // ASCII 脸有空隙，整块可点
        .onTapGesture {              // 摸头
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pet.headpat() }
            react("♥", rose)
        }
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { draftName = s.name == "？" ? "" : s.name; showRename = true } label: {
                HStack(spacing: 4) {
                    Text(s.name)
                        .font(.system(size: Theme.F.body, weight: .semibold, design: systemDesktop ? .default : .monospaced))
                        .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                    Image(systemName: "pencil").font(.system(size: 9)).foregroundColor(Theme.textMuted.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            Text("第 \(pet.ageDays) 天")
                .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
        }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 4) {
            barRow("饿", s.hunger, rose)
            barRow("心", s.happy, Color(red: 0.78, green: 0.55, blue: 0.62))
            barRow("力", s.energy, Theme.branchIndicator)
        }
    }

    private func barRow(_ label: String, _ value: Double, _ color: Color) -> some View {
        let n = Int((value / 10).rounded())
        return HStack(spacing: 8) {
            Text(label).foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
            if systemDesktop { ProgressView(value: value, total: 100).tint(color) }
            else {
                Text(String(repeating: "▓", count: n)).foregroundColor(color)
                + Text(String(repeating: "░", count: 10 - n)).foregroundColor(Theme.textMuted.opacity(0.4))
            }
        }
        .font(.system(size: Theme.F.caption, design: systemDesktop ? .default : .monospaced))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            actionChip("喂") { pet.feed();  react("<><", rose) }
            actionChip("玩") { pet.play();  react("♥", rose) }
            actionChip("睡") { pet.sleep(); react("zzz", Theme.textMuted) }
        }
    }

    /// 触发一次往上飘的反馈符号 + iOS 轻震
    private func react(_ text: String, _ color: Color) {
        reactionText = text
        reactionColor = color
        reactionID = UUID()   // 换 id 重建 FloatingReaction → 重跑飘起动画
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }

    private func actionChip(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { run() }
        } label: {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: .medium, design: systemDesktop ? .default : .monospaced))
                .foregroundColor(systemDesktop ? .primary.opacity(0.8) : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.branchIndicator.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private var face: String {
        switch pet.mood {
        case .happy:  return "( ^ω^ )"
        case .ok:     return "( ・ω・ )"
        case .hungry: return "( >﹏< )"
        case .sleepy: return "( ◡‿◡ )"
        case .sad:    return "( ╥﹏╥ )"
        }
    }

    private var faceColor: Color {
        switch pet.mood {
        case .happy:  return Theme.branchIndicator
        case .ok:     return Theme.textSecondary
        case .hungry: return rose
        case .sleepy: return Theme.textMuted
        case .sad:    return rose
        }
    }

}

/// 互动时从猫脸往上飘起、淡出的 ASCII 反馈符号。靠 .id() 重建触发 onAppear 动画。
private struct FloatingReaction: View {
    let text: String
    let color: Color
    @State private var up = false

    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .offset(y: up ? -50 : -6)
            .opacity(up ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.9)) { up = true } }
    }
}
