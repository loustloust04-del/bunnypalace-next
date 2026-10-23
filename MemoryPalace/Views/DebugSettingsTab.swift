import SwiftUI

/// 开发调试页：一份 body 两端共用（plan-settings-merge-x 刀 3，E 形态——原 mac 是 `SettingsView` 里的内联块）。
/// 五块 iOS-only 内容（浮球 / 输入框字号 F2 / 流光胶囊 / 缓存诊断 F1 / cc-bridge 清理）逐个包回第 2 类；
/// 弹泡调音台是 B12 宿主差异（mac 内联 `DisclosureGroup` / iOS push），第 5 类。
/// A4：反馈控制区已从本页搬到 mac 侧栏底部入口（`SettingsView.macOSSettingsBody`），本页不再有反馈卡。
struct DebugPage: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    #if os(iOS) && DEBUG
    @AppStorage("debugOrbEnabled") private var debugOrbEnabled = false
    @AppStorage(UIKitChatSpike.defaultsKey) private var spikeUIKitChatMode = ""
    #endif
    #if os(iOS) && DEBUG
    @AppStorage("perfProbeOn") private var perfProbeOn = false
    #endif
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        SettingsSectionList(.list) {
            #if os(macOS)
            Section {
                Button {
                    openWindow(id: "mac-appearance-console")
                } label: {
                    HStack {
                        Label("外观控制台", systemImage: "slider.horizontal.3")
                        Spacer()
                        Text("点击打开")
                            .foregroundColor(Theme.textSecondary)
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(Theme.textSecondary)
                    }
                    .font(m.body)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("独立窗口实时调整 mac 边距、正文宽度和各组件位置。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 长期卡顿探针（plan-mac-hang-probe）：最近 50 条，新的在上
            Section {
                let lines = HangProbe.recentLines()
                if lines.isEmpty {
                    Text("还没有记录")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                } else {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    NSWorkspace.shared.open(HangProbe.directory)
                } label: {
                    Label("在 Finder 中打开", systemImage: "folder")
                        .font(m.body)
                }
                .buttonStyle(.plain)
            } header: {
                Text("卡顿记录")
            } footer: {
                Text("主线程卡超过 0.25 秒记一条；卡超过 1 秒或 CPU 连续 10 秒占满，会自动存一份调用栈。只存在本机。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif

            #if os(iOS)
            #if DEBUG
            Section {
                Toggle("翻页探针", isOn: $perfProbeOn)
                    .tint(Theme.branchIndicator)
                    .searchAnchor("leaf-debug-airprobe")
                Text("开启或关闭后需完全退出并重新打开 App。记录翻页、聊天滚动与全局卡顿，日志保存在本机 Documents/perf-probe。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                Toggle("悬浮调试球", isOn: $debugOrbEnabled)
                    .tint(Theme.branchIndicator)
            } footer: {
                Text("屏幕浮球点开是调试面板，可录屏(20fps/10s)+逐帧 scrub 看交互。可拖动到任意位置。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // P1a-0 spike 隐藏入口（docs/spike-uikit-chat-page.md）：不进设置搜索，spike 删除时一并删
            Section {
                Picker("UIKit 聊天页 spike", selection: $spikeUIKitChatMode) {
                    Text("关").tag("")
                    ForEach(UIKitChatSpike.CellMode.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            } footer: {
                Text("重启 App 后生效。a = hosting 包现有气泡；b = 原生 cell + ParagraphUIView；c = b + 后台预排版高度缓存；d = c 但纯绘制。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif
            #endif

            Section {
                #if os(macOS)
                // B12：mac 折叠头当行、展开内容也在卡内（J2b 第 6 条）
                DisclosureGroup("弹泡调音台") {
                    BubblePopTunerView()
                        .padding(.top, 8)
                }
                .tint(ShellStyle.secondaryText)
                #else
                NavigationLink(destination: BubblePopTunerPage()) {
                    Text("弹泡调音台")
                        .font(m.body)
                }
                #endif
            } footer: {
                Text("iMessage 式弹泡动画的参数面板，调完即全局生效。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            #if os(iOS)
            // F2 输入框字号：iOS-only（第 2 类）
            Section {
                InputFontSizeTuner()
            } footer: {
                Text("输入框字号基准 × 外观里的字体缩放 = 实际字号。正文基准是 13.5，滑到一样就和正文同大。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                HStack {
                    Spacer()
                    Text("✦ AI 生成")
                        .font(m.action)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(RainbowFlowCapsule())
                    Spacer()
                }
            } footer: {
                Text("「帮我写」生成按钮的流光退役版，留这看着玩。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)


            // F1 缓存诊断：iOS-only（第 2 类）
            Section {
                let log = CacheDiagLog.shared
                if log.entries.isEmpty {
                    Text("还没有记录——发一轮消息就有")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(log.entries.reversed()) { e in
                        Text("\(e.time.formatted(.dateTime.hour().minute().second())) \(e.text)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                    Button("复制全部") {
                        UIPasteboard.general.string = log.fullText
                    }
                    .font(m.secondary)
                    .foregroundColor(Theme.branchIndicator)
                }
            } header: {
                Text("缓存诊断（→ 挂标/session · ← prompt/读/写/上游）")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        #endif
        .navigationTitle("开发调试")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if os(iOS)
/// 开发调试 → 输入框字号（research-input-field §二①）
private struct InputFontSizeTuner: View {
    @AppStorage("inputFontBase") private var inputFontBase: Double = 13.5
    @AppStorage("fontScale") private var fontScale = 1.2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("输入框字号")
                    .font(.system(size: Theme.F.body))
                Spacer()
                Text(String(format: "%.1f × %.1f = %.1f pt", inputFontBase, fontScale, inputFontBase * fontScale))
                    .font(.system(size: Theme.F.secondary, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                Button("重置") { inputFontBase = 13.5 }
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.branchIndicator)
                    .buttonStyle(.plain)
            }
            Slider(value: $inputFontBase, in: 11...20, step: 0.5)
                .tint(Theme.branchIndicator)
            Text("预览：记忆花园 the quick brown fox")
                .font(FontManager.font(size: inputFontBase))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.vertical, 4)
    }
}
#endif
