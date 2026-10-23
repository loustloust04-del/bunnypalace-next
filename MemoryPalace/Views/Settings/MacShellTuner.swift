#if os(macOS)
import SwiftUI
import AppKit

/// 独立、非模态的 mac 外观控制台；与工作窗口共享实时参数。
struct MacShellTuner: View {
    @Environment(\.dismiss) private var dismiss
    @State private var metrics = MacShellMetrics.shared
    @State private var copied = false

    private var groups: [(String, [MacShellMetrics.Knob])] {
        var order: [String] = []
        var bag: [String: [MacShellMetrics.Knob]] = [:]
        for k in MacShellMetrics.Knob.allCases {
            if bag[k.group] == nil { order.append(k.group) }
            bag[k.group, default: []].append(k)
        }
        return order.map { ($0, bag[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { group, knobs in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group)
                                .font(ShellStyle.secondaryFont.weight(.semibold))
                                .foregroundStyle(ShellStyle.secondaryText)
                            if group == "标题栏" {
                                Toggle("对齐系统红绿灯", isOn: $metrics.followsTrafficLights)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                            ForEach(knobs, id: \.self) { knob in
                                row(knob)
                                    .disabled(knob == .titleBarHeight && metrics.followsTrafficLights)
                            }
                            if group == "标题栏" {
                                Text("栏高 \(Int(metrics.titleBarHeight)) pt · 按钮 \(Int(metrics.titleButtonSide)) × \(Int(metrics.titleButtonSide)) pt · 四周留白 \(Int(metrics.titleControlInset)) pt")
                                    .font(ShellStyle.captionFont)
                                    .foregroundStyle(ShellStyle.mutedText)
                            }
                        }
                    }
                    Text("修改立即生效并自动保存。正文最大宽度只约束阅读区，面板始终填满可用空间。")
                        .font(ShellStyle.captionFont)
                        .foregroundStyle(ShellStyle.mutedText)
                        .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, idealWidth: 540, minHeight: 460, idealHeight: 680)
        .background(ShellStyle.field)
        .onDisappear { metrics.showGuides = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("外观控制台")
                .font(ShellStyle.titleFont)
            Spacer()
            Toggle("留白", isOn: Binding(get: { metrics.showGuides },
                                        set: { metrics.showGuides = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("把各条泳道上色、正文卡描边，看清留白")
            Button("复制参数") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(metrics.exportText(), forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            }
            .help("复制当前精确参数")
            Button("恢复默认") { metrics.reset() }
            Button("完成") {
                metrics.showGuides = false
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .overlay(alignment: .center) {
            if copied {
                Text("已复制 ✓")
                    .font(ShellStyle.captionFont)
                    .foregroundStyle(ShellStyle.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func row(_ knob: MacShellMetrics.Knob) -> some View {
        HStack(spacing: 10) {
            Text(knob.label)
                .font(ShellStyle.secondaryFont)
                .foregroundStyle(ShellStyle.secondaryText)
                .frame(width: 108, alignment: .leading)
                .lineLimit(1)
            Slider(value: metrics.binding(knob), in: knob.range, step: knob.step)
            TextField("", value: metrics.binding(knob), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 54)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
#endif
