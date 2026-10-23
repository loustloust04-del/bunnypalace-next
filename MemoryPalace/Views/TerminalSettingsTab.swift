import SwiftUI

/// CC 终端设置：键盘工具条的布局（主行 / 抽屉 / 已隐藏）+ 抽屉行为 + 自定义键。
/// 改完经 `TerminalToolbarStore` 即时同步到工具条。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3）：容器走 `SettingsSectionList(.list)`，两端逐字重复的
/// 两个 sheet + 一个 alert 只留一份。剩下四组平台差异按 plan v2 §2.4 保留：
/// 按键布局（iOS UIKit 拖拽编辑器）、抽屉两行（mac 自画右对齐）、自定义键行（mac 行内删除钮，`.onDelete` 在
/// `MacSettingsForm` 无手势）、三处 `MacSettingsButton`（宿主没下发按钮样式）。
struct TerminalSettingsTab: View {
    @ObservedObject private var store = TerminalToolbarStore.shared

    @State private var editingKey: TerminalCustomKey?
    @State private var creatingKey = false
    @State private var confirmReset = false

    var body: some View {
        SettingsSectionList(.list) {
            #if os(iOS)
            Section {
                NavigationLink {
                    TerminalToolbarLayoutEditorView()
                        .navigationTitle("按键布局")
                        .navigationBarTitleDisplayMode(.inline)
                        .ignoresSafeArea(edges: .bottom)
                } label: {
                    Label("按键布局", systemImage: "keyboard")
                        .foregroundColor(Theme.textPrimary)
                }
            } footer: {
                Text("长按拖动跨区搬键（主行 ↔ 抽屉 ↔ 已隐藏），拖不动就长按选菜单。主行放不下的会挤到抽屉 1。")
            }
            #endif

            Section("抽屉") {
                #if os(macOS)
                // 行左标题、行右「数值 + 步进器」，跟单词页的每日新卡同款
                HStack {
                    Text("行数")
                    Spacer(minLength: 8)
                    Text("\(store.layout.drawerRows.count)")
                        .foregroundStyle(ShellStyle.secondaryText)
                    Stepper(
                        "",
                        value: Binding(
                            get: { store.layout.drawerRows.count },
                            set: { store.setDrawerRowCount($0) }
                        ),
                        in: 1...5
                    )
                    .labelsHidden()
                }
                HStack {
                    Text("展开方式")
                    Spacer()
                    Picker("展开方式", selection: $store.drawerToggleMode) {
                        ForEach(TerminalDrawerToggleMode.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                #else
                Stepper(
                    "行数 \(store.layout.drawerRows.count)",
                    value: Binding(
                        get: { store.layout.drawerRows.count },
                        set: { store.setDrawerRowCount($0) }
                    ),
                    in: 1...5
                )
                Picker("展开方式", selection: $store.drawerToggleMode) {
                    ForEach(TerminalDrawerToggleMode.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                #endif
            }

            Section {
                ForEach(store.customKeys) { key in
                    #if os(macOS)
                    // mac 没有左滑手势（`MacSettingsForm` 是 ScrollView + VStack），删除给行内钮
                    HStack(spacing: 12) {
                        Button { editingKey = key } label: {
                            HStack {
                                Text(key.label)
                                Spacer()
                                Text(summary(key))
                                    .font(ShellStyle.secondaryFont.monospaced())
                                    .foregroundStyle(ShellStyle.secondaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("删除") {
                            var keys = store.customKeys
                            keys.removeAll { $0.id == key.id }
                            store.setCustomKeys(keys)
                        }
                        .buttonStyle(MacSettingsButton())
                        .foregroundStyle(ShellStyle.secondaryText)
                    }
                    #else
                    Button {
                        editingKey = key
                    } label: {
                        HStack {
                            Text(key.label)
                                .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(summary(key))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    #endif
                }
                .onDelete { offsets in
                    var keys = store.customKeys
                    keys.remove(atOffsets: offsets)
                    store.setCustomKeys(keys)
                }

                Button {
                    creatingKey = true
                } label: {
                    Label("新建按键", systemImage: "plus")
                        .foregroundColor(Theme.branchIndicator)
                }
                #if os(macOS)
                .buttonStyle(MacSettingsButton())
                #endif
            } header: {
                Text("自定义键")
            } footer: {
                Text("新建的键会放进抽屉 1 的末尾。定义跟布局是分开存的 —— 把键从布局里拿掉，定义还在。")
            }

            Section {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Text("恢复默认布局")
                }
                #if os(macOS)
                .buttonStyle(MacSettingsButton())
                #endif
                .disabled(!store.isCustomized)
            } footer: {
                Text("只把布局恢复成默认，**自定义键的定义会保留**，去「已隐藏」里还能放回来。")
            }
        }
        .navigationTitle("终端")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $creatingKey) {
            TerminalCustomKeyEditor(existing: nil) { key in
                store.setCustomKeys(store.customKeys + [key])
                // 新建的键落进抽屉 1 末尾（物料表 §10.3）
                var layout = store.layout
                layout.drawerRows[0].append(.custom(key.id))
                store.setLayout(layout)
            }
        }
        .sheet(item: $editingKey) { key in
            TerminalCustomKeyEditor(existing: key) { updated in
                var keys = store.customKeys
                if let i = keys.firstIndex(where: { $0.id == updated.id }) {
                    keys[i] = updated
                    store.setCustomKeys(keys)
                }
            }
        }
        .alert("恢复默认布局？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) { store.resetToDefaults() }
        } message: {
            Text("主行和抽屉回到出厂顺序。自定义键的定义不会删。")
        }
    }

    private func summary(_ key: TerminalCustomKey) -> String {
        guard let first = key.sequence.first else { return "空" }
        if key.sequence.count > 1 { return "宏 · \(key.sequence.count) 步" }
        return TerminalCustomKeyEditor.stepLabel(first)
    }
}
