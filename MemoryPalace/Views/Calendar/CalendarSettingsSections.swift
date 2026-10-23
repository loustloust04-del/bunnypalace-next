import SwiftUI

// MARK: - 设置 → 日历（plan-calendar §六）
// iOS 设置 List 与 mac MacSettingsForm 共用。隐私开关按楼层（CalendarPrivacy），不走全局 PermissionCenter。

struct CalendarSettingsSections: View {
    let profileId: String

    @AppStorage(CalendarLook.storageKey) private var lookRaw = CalendarLook.paper.rawValue
    @AppStorage("calendar_monthStyle") private var monthStyle = "pencil"
    @AppStorage("calendar_cardColor") private var cardColor = StarCardColor.white.rawValue
    @AppStorage("calendar_lightDots") private var lightDots = true
    @AppStorage("calendar_metric") private var metricRaw = ActivityMetric.messages.rawValue
    @AppStorage("assistantName") private var assistantName = "助手"

    /// 楼层开关不是 AppStorage（键带楼层后缀），用 State 镜像
    @State private var journalVisible = false
    @State private var injectToday = false
    @State private var anniversaryInject = true

    private var privacy: CalendarPrivacy { CalendarPrivacy() }

    var body: some View {
        Group {
            Section {
                Picker("页面样子", selection: $lookRaw) {
                    ForEach(CalendarLook.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                if lookRaw != CalendarLook.ios.rawValue {
                    Picker("月历样子", selection: $monthStyle) {
                        Text("铅笔纸").tag("pencil")
                        Text("星孔卡片").tag("card")
                    }
                    if monthStyle == "card" {
                        Picker("星孔外卡颜色", selection: $cardColor) {
                            ForEach(StarCardColor.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                    }
                    Toggle("聊一点的日子画一个小点", isOn: $lightDots)
                    Picker("涂深按", selection: $metricRaw) {
                        Text("条数").tag(ActivityMetric.messages.rawValue)
                        Text("字数").tag(ActivityMetric.chars.rawValue)
                    }
                }
            } header: {
                Text("月历")
            } footer: {
                if lookRaw == CalendarLook.ios.rawValue {
                    Text("日期下面的小点：薄荷色是聊过，粉色是纪念日，玫瑰色是经期。纪念日卡片两种样子里都一样。")
                } else {
                    Text("聊得越多，那天的格子用铅笔涂得越深。深浅按你自己过去 90 天的量来分。")
                }
            }

            Section {
                Toggle("\(assistantName)能看到我的日记", isOn: Binding(
                    get: { journalVisible },
                    set: { journalVisible = $0; privacy.setJournalVisible($0, profileId) }
                ))
                Toggle("把今天的日记告诉\(assistantName)", isOn: Binding(
                    get: { injectToday },
                    set: { injectToday = $0; privacy.setInjectTodayJournal($0, profileId) }
                ))
                .disabled(!journalVisible)
                Toggle("快到的纪念日告诉\(assistantName)", isOn: Binding(
                    get: { anniversaryInject },
                    set: { anniversaryInject = $0; privacy.setAnniversaryInject($0, profileId) }
                ))
            } header: {
                Text("日记与纪念日")
            } footer: {
                Text("只对这个楼层生效。关着时，\(assistantName)用文件工具看不到你的日记文件夹；打开了也只能读，不能改。开了「终端」或连着 Claude Code 的对话，仍然能读到文件库里的所有文件。已经说进对话里的内容，关掉也不会被抹掉。")
            }

            Section {
                Button("重新统计聊天") {
                    CalendarActivityModel.shared.refresh(profileId: profileId, force: true)
                }
            } footer: {
                Text("月历的深浅来自一份本机统计，平时会自己更新。数字对不上时可以重新统计一次。")
            }
        }
        .onAppear(perform: loadFloorSwitches)
        .onChange(of: profileId) { _, _ in loadFloorSwitches() }
    }

    private func loadFloorSwitches() {
        journalVisible = privacy.journalVisible(profileId)
        injectToday = privacy.injectTodayJournal(profileId)
        anniversaryInject = privacy.anniversaryInject(profileId)
    }
}

/// 日历页底铅笔齿轮点开的设置（和 设置 → 日历 是同一套）
struct CalendarSettingsSheet: View {
    let profileId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            #if os(iOS)
            List { CalendarSettingsSections(profileId: profileId) }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.sidebarBg)
                .navigationTitle("日历")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            #else
            MacSettingsForm { CalendarSettingsSections(profileId: profileId) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }
}

#if os(iOS)
struct CalendarSettingsTab: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        List {
            CalendarSettingsSections(profileId: profileManager?.currentProfile.id ?? "")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("日历")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
