import SwiftUI

/// 开发调试页：一份 body 两端共用（plan-settings-merge-x 刀 3，E 形态——原 mac 是 `SettingsView` 里的内联块）。
/// 五块 iOS-only 内容（浮球 / 输入框字号 F2 / 流光胶囊 / 缓存诊断 F1 / cc-bridge 清理）逐个包回第 2 类；
/// 弹泡调音台是 B12 宿主差异（mac 内联 `DisclosureGroup` / iOS push），第 5 类。
/// A4：反馈控制区已从本页搬到 mac 侧栏底部入口（`SettingsView.macOSSettingsBody`），本页不再有反馈卡。
struct DebugPage: View {
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var hangSummary = HangProbe.Summary(groups: [], error: nil)
    @State private var hangLoading = true
    #endif
    #if os(iOS) && DEBUG
    @AppStorage("debugOrbEnabled") private var debugOrbEnabled = false
    @AppStorage(UIKitChatSpike.defaultsKey) private var spikeUIKitChatMode = ""
    #endif
    #if os(iOS) && DEBUG
    @AppStorage("perfProbeOn") private var perfProbeOn = false
    #endif
    @Environment(\.settingsMetrics) private var m
    #if os(macOS) && DEBUG
    @State private var xiaoyaGalleryOpen = false
    #endif
    #if DEBUG
    private func replayXiaoyaOnboarding() {
        AssistantEngine.shared.script.start()
        XiaoyaApp.open()
    }
    #endif

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

            // 分组和读盘只在进入页面时走后台，不随 body 重算同步读日志。
            Section {
                if hangLoading {
                    ProgressView()
                } else if let error = hangSummary.error {
                    Text("卡顿记录读取失败：\(error)")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                } else if hangSummary.groups.isEmpty {
                    Text("最近没有卡顿观测")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(hangSummary.groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(group.kind.title) · \(group.context)")
                            Text("\(group.count)条 · 最大\(String(format: "%.2fs", group.maximumSeconds)) · \(group.date)")
                            Text(group.package)
                                .foregroundColor(Theme.textMuted)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mac-hang-group-\(group.kind.rawValue)")
                    }
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
                Text("最近128KiB内最多50条完整日志，按包和上下文分组。心跳响应、采样下界与CPU窗口分开；后台响应含调度延迟，都不等同系统hang时长。只存在本机。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            .task {
                hangSummary = await HangProbe.shared.recentSummary()
                hangLoading = false
            }
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

            #if DEBUG
            // 小芽新引导 P3（plan-onboarding-xiaoya-impl §3）：不接剧本，摆出每张引导卡的各状态对照小样；不进设置搜索
            Section {
                #if os(macOS)
                Button("小芽卡片样张") { xiaoyaGalleryOpen = true }
                    .font(m.body)
                    .buttonStyle(.plain)
                    .sheet(isPresented: $xiaoyaGalleryOpen) {
                        NavigationStack { XiaoyaCardGalleryView() }
                            .frame(minWidth: 480, minHeight: 720)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { xiaoyaGalleryOpen = false } } }
                    }
                #else
                NavigationLink(destination: XiaoyaCardGalleryView()) {
                    Text("小芽卡片样张")
                        .font(m.body)
                }
                #endif
                // P4：剧本接在小芽对话后面从开场白放起，打开小芽 app。不碰新装判定
                Button("从头放一遍引导") { replayXiaoyaOnboarding() }
                    .font(m.body)
                    .buttonStyle(.plain)
                #if os(iOS)
                // §11-5：开机 hello 占位只放一次，这里直接盖在当前画面上重放（不改「放过了」的标记）
                Button("重放开机 hello") { GardenHello.replay() }
                    .font(m.body)
                    .buttonStyle(.plain)
                #endif
            } footer: {
                Text("小芽引导里的每张卡片、每种状态摆在一页，深浅色可切。按钮能点，测试和保存都是假的。「从头放一遍引导」是真的：会写园丁类型、钥匙、新楼层，和新装走一遍一样。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
            #endif

            ParamAdaptSection()

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

/// 开发调试 → 参数自适配（#094 Q6）：400 自愈记下的「这个地址 + 模型不收哪些参数」，能看能清。
/// 清掉后下次照常发，再被拒会再学一次；单条也能在 API 卡模型池那行清
private struct ParamAdaptSection: View {
    @Environment(\.settingsMetrics) private var m
    private let store = ParamAdaptStore.shared

    var body: some View {
        Section {
            let rows = store.all
            if rows.isEmpty {
                Text("还没有记下的——遇到接口拒收参数会自动记在这里")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text([row.entry.host, row.entry.modelId, row.entry.typeLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(row.entry.summary) · \(row.entry.learnedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))")
                                .font(m.caption)
                                .foregroundColor(Theme.textSecondary)
                            if !row.entry.rawError.isEmpty {
                                Text(row.entry.rawError)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("清除") { store.remove(key: row.key) }
                            .font(m.secondary)
                            .foregroundColor(Theme.branchIndicator)
                            .buttonStyle(.plain)
                    }
                }
                Button("全部清空") { store.removeAll() }
                    .font(m.secondary)
                    .foregroundColor(Theme.branchIndicator)
                    .buttonStyle(.plain)
            }
        } header: {
            Text("参数自适配")
        } footer: {
            Text("接口拒收某个参数（比如 temperature）时自动去掉重发，并按「地址 + 模型」记住，以后直接不发。清掉后下次照常发。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)
    }
}
