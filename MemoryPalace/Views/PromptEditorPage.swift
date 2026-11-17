import MemoryCore
import SwiftUI

// MARK: - 提取提示词（C2）：只读看现在在用的那份；Edit 进去改的就是这一份，存了写法不变
// 整段写手的提示词她改了存 `FragmentPool.customWholePromptKey`；选了本机模型（旧写法）时看到、改的是旧写法那份（`customPromptKey`）

/// 每批才有的值在页面上的占位写法
private enum ExtractPromptPlaceholder {
    static let window = "〈窗口名〉"
    static let from = "〈起始日期〉"
    static let to = "〈结束日期〉"
    static let draft = "〈第一次写出的 JSON〉"
    static let day = "〈这一截最后一天〉"
}

/// 旧写法是怎么写的（选了本机模型时那一行的说明）
private func classicWayText() -> String {
    "每满 \(FragmentWatch.every()) 条写一次，每条消息只读前 \(FragmentPool.maxMessageChars) 字，不看前文和已记的卡，不核对，没有置信度"
}

/// C2 二级页「提取提示词」：iOS 推页与 mac 路由（`SettingsRoute.macDestination`）共用
struct ExtractPromptPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage(FragmentPool.customPromptKey) private var storedTemplate = ""
    @AppStorage(FragmentPool.customWholePromptKey) private var storedWholeTemplate = ""
    @AppStorage(FragmentModelRoute.key) private var c2Choice = ""
    @State private var askBack = false
    @State private var copied = false

    /// custom = 现在用的是她改过的那份。写法只看选没选本机模型，和她存没存自定义提示词无关
    private enum Mode { case whole(custom: Bool), classic(local: Bool, custom: Bool) }

    private var local: Bool { FragmentModelRoute.localModelId(choice: c2Choice) != nil }

    private var mode: Mode {
        _ = (storedTemplate, storedWholeTemplate)
        if FragmentWatch.usesWhole(local: local) { return .whole(custom: FragmentPool.activeWholeTemplate() != nil) }
        return .classic(local: local, custom: FragmentPool.activeCustomTemplate() != nil)
    }

    /// 和 C2 真调用时一样：当前楼层的称呼（空的走 `Names` 自己的兜底）
    private var names: MemoryExtractor.Names {
        MemoryExtractor.Names(userName: profileManager?.currentProfile.userName ?? "",
                              assistantName: profileManager?.currentProfile.assistantName ?? "")
    }

    /// 她改过就是她那份，没改是默认模板；和真调用时走同一个渲染
    private var wholeText: String {
        _ = storedWholeTemplate
        return FragmentPool.wholeSystem(names: names, windowTitle: ExtractPromptPlaceholder.window,
                                        from: ExtractPromptPlaceholder.from, to: ExtractPromptPlaceholder.to,
                                        template: FragmentPool.activeWholeTemplate())
    }

    private var verifyText: String {
        FragmentPool.wholeVerifyNote(draft: ExtractPromptPlaceholder.draft, names: names)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var classicText: String {
        FragmentPool.systemPrompt(names: names, day: ExtractPromptPlaceholder.day)
    }

    var body: some View {
        SettingsSectionList(.list) {
            statusSection
            promptSections
            Section {
                Button(copied ? "Copied" : "Copy") { copy() }
                    .foregroundColor(Theme.branchIndicator)
            }
            .panelRowBackground()
            editSection
        }
        .memorySubpage("提取提示词")
        .alert("回到默认？", isPresented: $askBack) {
            Button("Back to default", role: .destructive) {
                UserDefaults.standard.removeObject(forKey: isWhole ? FragmentPool.customWholePromptKey : FragmentPool.customPromptKey)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你改过的提示词会被清掉，换回默认那份")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch mode {
            case .whole(let custom):
                SubRowLabel(title: custom ? "现在用的是你改过的提示词" : "整段读完再写",
                            sub: "攒够一截新对话，连同前文和已记的卡一起写，写完再核对一次")
                if custom { backButton }
            case .classic(let local, let custom):
                SubRowLabel(title: custom ? "现在用的是你改过的提示词（旧写法）" : (local ? "本机模型用旧写法" : "现在用的是旧写法"),
                            sub: classicWayText())
                if custom { backButton }
            }
        }
        .panelRowBackground()
    }

    private var backButton: some View {
        Button("Back to default") { askBack = true }
            .foregroundColor(Theme.branchIndicator)
    }

    @ViewBuilder
    private var promptSections: some View {
        switch mode {
        case .whole:
            Section {
                promptText(wholeText)
            } header: {
                Text("每次写")
            }
            .panelRowBackground()
            Section {
                promptText(verifyText)
            } header: {
                Text("写完再核对一次时追加的话")
            } footer: {
                Text("〈 〉里是每批才有的：窗口名、这一截的起止日期、第一次写出的结果。每次还一起送去已记的卡、前文和这一截新对话；在这里直接聊的窗口，最后再接上聊天时本来就带着的设定。")
                    .font(m.caption)
            }
            .panelRowBackground()
        case .classic:
            Section {
                promptText(classicText)
            } header: {
                Text("每次写")
            } footer: {
                Text("\(ExtractPromptPlaceholder.day)每批换成那一截的日期。每次还一起送去这一截新对话。")
                    .font(m.caption)
            }
            .panelRowBackground()
        }
    }

    /// Edit：改的就是上面在用的那一份（整段写手改整段的，旧写法改旧写法的），存了写法不变
    private var editSection: some View {
        Section {
            SettingsNavRow(.memoryExtractCustomPrompt) {
                ExtractPromptEditorPage()
            } label: {
                SubRowLabel(title: "Edit")
            }
        } footer: {
            Text("改的就是上面这份，存了写法不变")
                .font(m.caption)
        }
        .panelRowBackground()
    }

    private var isWhole: Bool {
        if case .whole = mode { return true }
        return false
    }

    private func promptText(_ text: String) -> some View {
        Text(text)
            .font(m.caption.monospaced())
            .foregroundColor(Theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy() {
        let text = isWhole ? wholeText + "\n\n" + verifyText : classicText
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Prompt Editor Page（学 SlotEditPage 样板，单值编辑）

/// 通用提示词编辑页：title + 大 TextEditor + 原生 toolbar 取消/保存。
/// 用 NavigationLink push 调起（不是 sheet），跟 SlotEditPage 一致。
struct PromptEditorPage: View {
    let title: String
    let storageKey: String
    let defaultTemplate: String
    let hint: String

    /// 页顶那句：这份提示词用在哪
    var note = ""
    /// 存之前那一查：存了会用不了的原因（能存 = nil）。不给 = 不查
    var problem: ((String) -> String?)? = nil

    @State private var edited: String = ""
    @State private var initial: String = ""
    @State private var confirmingDiscard = false
    @State private var saveProblem: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    private var isDirty: Bool { edited != initial }

    /// 和默认模板一字不差就当没存；存了会用不了的（缺了解卡要的字段名）不存，说清原因
    private func requestSave() {
        if edited != defaultTemplate, let why = problem?(edited) {
            saveProblem = why
        } else {
            save()
        }
    }

    private func save() {
        if edited == defaultTemplate {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            UserDefaults.standard.set(edited, forKey: storageKey)
        }
        initial = edited
        dismiss()
    }

    var body: some View {
        // mac 进设置窗 / 右栏面板都是 push 进来的：窗口 toolbar 已被宿主藏掉（会盖住页顶 ‹ › 行），取消 / 保存改画在页内；iOS 仍走原生 toolbar
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { if isDirty { confirmingDiscard = true } else { dismiss() } }
                    .buttonStyle(MacSettingsButton())
                Button("保存") { requestSave() }
                    .buttonStyle(MacSettingsButton())
                    .disabled(!isDirty)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            editor
        }
        .onAppear(perform: load)
        .discardChangesGuard(isDirty: isDirty, confirming: $confirmingDiscard, onDiscard: { dismiss() })
        .alert("存不了", isPresented: savingBlocked) { Button("好", role: .cancel) {} } message: { Text(saveProblem ?? "") }
        #else
        editor
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if isDirty { confirmingDiscard = true } else { dismiss() } }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { requestSave() }
                        .foregroundColor(isDirty ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(!isDirty)
                }
            }
            .onAppear(perform: load)
            .navigationBarBackButtonHidden(isDirty)
            .discardChangesGuard(isDirty: isDirty, confirming: $confirmingDiscard, onDiscard: { dismiss() })
            .alert("存不了", isPresented: savingBlocked) { Button("好", role: .cancel) {} } message: { Text(saveProblem ?? "") }
        #endif
    }

    private var savingBlocked: Binding<Bool> {
        Binding(get: { saveProblem != nil }, set: { if !$0 { saveProblem = nil } })
    }

    private var editor: some View {
        SettingsSectionList(.list) {
            if !note.isEmpty {
                Section {
                    Text(note)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
            }

            Section("内容") {
                TextEditor(text: $edited)
                    .font(m.caption.monospaced())
                    .frame(minHeight: 240)
                    .scrollContentBackground(.hidden)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Text(hint)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        #else
        .scrollContentBackground(.hidden)
        #endif
    }

    /// 没存过 = 从默认模板起步（没改就存不了）
    private func load() {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? ""
        let start = stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTemplate : stored
        edited = start
        initial = start
    }
}

/// 「提取提示词」页的 Edit 推进来的那一页：iOS 推页与 mac 路由（`SettingsRoute.macDestination`）共用。
/// 现在是哪种写法就改哪一份——整段写手改整段的（存新 key），选了本机模型改旧写法的（存旧 key）
struct ExtractPromptEditorPage: View {
    @AppStorage(FragmentModelRoute.key) private var c2Choice = ""

    var body: some View {
        if FragmentWatch.usesWhole(local: FragmentModelRoute.localModelId(choice: c2Choice) != nil) {
            PromptEditorPage.memoryExtractWhole
        } else {
            PromptEditorPage.memoryExtract
        }
    }
}

extension PromptEditorPage {
    /// 整段写手的提示词：编辑框里预填的就是默认模板（发出去的那份就是它渲染的），存 `FragmentPool.customWholePromptKey`
    static var memoryExtractWhole: PromptEditorPage {
        PromptEditorPage(
            title: "Edit",
            storageKey: FragmentPool.customWholePromptKey,
            defaultTemplate: FragmentPool.wholeTemplate,
            hint: "可用占位符：\(FragmentPool.wholeUserToken)（你的称呼）、\(FragmentPool.wholeCharToken)（AI 的名字）、\(FragmentPool.wholeWindowToken)（窗口名）、\(FragmentPool.wholeDateRangeToken)（换成「，这段新对话的时间是 起 到 止」，没有日期时是空的）、\(FragmentPool.wholeFromToken) / \(FragmentPool.wholeToToken)（起止日期）。输出格式里的字段名（\(FragmentPool.wholeRequiredFields.joined(separator: "、"))）不能删，删了解不出卡。聊天时本来就带着的设定由程序接在最后，不用写进来。存的和默认一字不差，就当没存。",
            note: "改的就是现在在用的这份。存了写法不变：整段读完再写，写完再核对一次。",
            problem: FragmentPool.wholeTemplateProblem
        )
    }

    /// 旧写法（选了本机模型时）的提示词，存 `FragmentPool.customPromptKey`。
    /// v5 起是填表提示词（老的 AUDN 自定义模板对不上这张表，不迁移）
    static var memoryExtract: PromptEditorPage {
        PromptEditorPage(
            title: "Edit",
            storageKey: FragmentPool.customPromptKey,
            defaultTemplate: FragmentPool.defaultTemplate,
            hint: "可用占位符：{{CHAR_NAME}}（AI 的名字）、{{USER_NAME}}（你的称呼）、{{DATE}}（这截对话最后一天）。必填的 JSON 字段不能删。存的和默认一字不差，就当没存。",
            note: "这份是旧写法的提示词，只在旧写法下用。"
        )
    }
}
