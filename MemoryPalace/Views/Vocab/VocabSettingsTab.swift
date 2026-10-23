import SwiftUI

/// 单词功能的设置面板。
///
/// 双入口（D8=C）：
/// - vocab panel 顶部齿轮按钮 → sheet
/// - 全局设置 → 单词 tab → NavigationStack push
///
/// 目前只有一项：「问 {{char}}」按钮的 prompt 模板。
/// 一份 body 两端共用（plan-settings-merge 刀 1）：容器走 `SettingsSectionList(.form)`，字号走 `settingsMetrics`；
/// Journal 皮肤（cream 行底 / faint 组头 / sage 页底）是这页自己的，保留。
struct VocabSettingsTab: View {
    @AppStorage("vocabAskPromptTemplate") private var template: String = VocabPromptDefaults.template
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage("vocabShuffleByDefault") private var shuffleByDefault: Bool = false
    @AppStorage("vocabReviewDailyQuota") private var reviewDailyQuota: Int = 10

    /// build 戳（可执行文件 mtime）——"到底装没装上"一眼可见，不再猜进程新旧。
    private var buildStamp: String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "build \(f.string(from: date))"
    }
    @AppStorage("vocabReviewDailyCap") private var reviewDailyCap: Int = 50
    @AppStorage("vocabReviewAutoFromReading") private var reviewAutoFromReading: Bool = true
    #if PERSONAL_APPS
    @AppStorage(VocabArcheologyRoute.storageKey) private var archeologyRoute: String = VocabArcheologyRoute.mac.rawValue
    #endif
    @State private var showResetConfirm = false
    @Environment(\.settingsMetrics) private var m

    /// 组头色：iOS 沿用 Journal 的极淡字，mac 跟系统设置一样是深色（J2b）——皮肤例外，只此一处 `#if`
    private var headerColor: Color {
        #if os(macOS)
        ShellStyle.text
        #else
        JournalTheme.faint
        #endif
    }

    var body: some View {
        // 搜索锚点：命中叶子条目时滚到那一行
        ScrollViewReader { anchorProxy in
            SettingsSectionList(.form) {
                orderSection
                reviewSection
                #if PERSONAL_APPS
                archeologySection
                #endif
                placeholderSection
                templateSection
                previewSection
                resetSection

                Section {
                } footer: {
                    Text(buildStamp)
                        .font(m.caption)
                        .foregroundColor(JournalTheme.faint.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .scrollContentBackground(.hidden)
            #if os(macOS)
            .background(ShellStyle.windowBackground)
            #else
            .background(JournalTheme.sage)
            #endif
            .navigationTitle("单词")
            .settingsAnchorScroll(anchorProxy)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: - 出词顺序

    private var orderSection: some View {
        Section {
            Toggle("默认随机出词", isOn: $shuffleByDefault)
                .tint(JournalTheme.mint)
                .listRowBackground(JournalTheme.cream)
                .searchAnchor("leaf-vocab-order")
        } header: {
            Text("出词顺序")
                .foregroundColor(headerColor)
        } footer: {
            Text("关：按 priority 推荐学习顺序出词（高频先）。\n开：每次重新筛选/切设置时洗牌，每轮都是新随机。")
                .font(m.caption)
                .foregroundColor(JournalTheme.faint)
        }
    }

    // MARK: - 复习

    private var reviewSection: some View {
        Section {
            Stepper(value: $reviewDailyQuota, in: 0...50) {
                HStack {
                    Text("每日新卡")
                    Spacer()
                    Text("\(reviewDailyQuota)")
                        .foregroundColor(JournalTheme.pencil)
                        .monospacedDigit()
                }
            }
            .listRowBackground(JournalTheme.cream)
            .searchAnchor("leaf-vocab-newquota")

            Stepper(value: $reviewDailyCap, in: 0...300, step: 10) {
                HStack {
                    Text("每日复习上限")
                    Spacer()
                    Text(reviewDailyCap == 0 ? "不限" : "\(reviewDailyCap)")
                        .foregroundColor(JournalTheme.pencil)
                        .monospacedDigit()
                }
            }
            .listRowBackground(JournalTheme.cream)
            .searchAnchor("leaf-vocab-cap")

            Toggle("划词收词进复习", isOn: $reviewAutoFromReading)
                .tint(JournalTheme.mint)
                .listRowBackground(JournalTheme.cream)
                .searchAnchor("leaf-vocab-collect")
        } header: {
            Text("复习")
                .foregroundColor(headerColor)
                .searchAnchor("leaf-vocab-review")
        } footer: {
            Text("每日新卡：复习页每天自动从所选词书按顺序补充这么多张新卡，0 = 不自动补。\n每日复习上限：今天最多复习这么多张（新卡+到期都算），到量出完成页；没排进今天的到期卡明天照常出现，0 = 不限。\n划词收词进复习：开了之后，阅读器或聊天里划词收进生词本的词自动加入复习牌堆。\n\n题型随熟悉度爬坡：新卡出认读（先猜后看），答对两次后出拼写（按释义或原句挖空默写），间隔拉到 7 天以上出造句（AI 判分）；答错会跌回认读重学。长按卡片可从牌堆移除。")
                .font(m.caption)
                .foregroundColor(JournalTheme.faint)
        }
    }

    // MARK: - 考古（#054，私用版才有 Mac 这条路）

    #if PERSONAL_APPS
    private var archeologySection: some View {
        Section {
            Picker("考古用", selection: $archeologyRoute) {
                Text("Mac 上的 Claude").tag(VocabArcheologyRoute.mac.rawValue)
                Text("App 里的模型").tag(VocabArcheologyRoute.app.rawValue)
            }
            .listRowBackground(JournalTheme.cream)
            .searchAnchor("leaf-vocab-archeology")
        } header: {
            Text("考古")
                .foregroundColor(headerColor)
        } footer: {
            Text("Mac 上的 Claude：经桥接在 Mac 上跑 claude -p，结果也写进仓库语料库，需要 Mac 在线。\nApp 里的模型：用当前聊天模型直接写，结果存在这台设备上，按模型计费。")
                .font(m.caption)
                .foregroundColor(JournalTheme.faint)
        }
    }
    #endif

    // MARK: - 占位符说明

    private var placeholderSection: some View {
        Section {
            ForEach(VocabPromptDefaults.placeholderDocs, id: \.key) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Text("{\(entry.key)}")
                        .font(m.body.monospaced())
                        .foregroundColor(JournalTheme.mint)
                        .frame(width: 110, alignment: .leading)
                    Text(entry.desc)
                        .font(m.secondary)
                        .foregroundColor(JournalTheme.pencil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowBackground(JournalTheme.cream)
            }
        } header: {
            Text("可用占位符")
                .foregroundColor(headerColor)
        } footer: {
            Text("`{forms}` 或 `{status}` 为空时整行自动隐藏，不会出现空冒号。")
                .font(m.caption)
                .foregroundColor(JournalTheme.faint)
        }
    }

    // MARK: - 模板编辑

    private var templateSection: some View {
        Section {
            TextEditor(text: $template)
                .font(m.body.monospaced())
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                #if os(macOS)
                // 卡内输入区要有自己的底，否则跟卡融成一片看不出是可编辑区（mac 皮肤例外）
                .padding(8)
                .background(ShellStyle.windowBackground, in: RoundedRectangle(cornerRadius: ShellStyle.controlRadius))
                #endif
                .listRowBackground(JournalTheme.cream)
                .searchAnchor("leaf-vocab-template")
        } header: {
            Text("模板")
                .foregroundColor(headerColor)
        } footer: {
            Text("按下「问 {{char}}」按钮时这套模板会被渲染成 prompt 发给当前楼层 AI。")
                .font(m.caption)
                .foregroundColor(JournalTheme.faint)
        }
    }

    // MARK: - 预览（拿假数据渲染一下让用户看效果）

    private var previewSection: some View {
        Section {
            Text(previewText)
                .font(m.secondary)
                .foregroundColor(JournalTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(JournalTheme.cream)
        } header: {
            Text("预览（带词形 + 已标 反应慢）")
                .foregroundColor(headerColor)
        }
    }

    private var previewText: String {
        VocabPromptDefaults.render(template: template, vars: [
            "word": "ephemeral",
            "definition": "短暂的；瞬息的",
            "band": "Specialized / overlap",
            "categories": "Academic NAWL",
            "forms": "ephemerals, ephemerally",
            "status": "反应慢",
            "assistantName": assistantName,
        ])
    }

    // MARK: - 恢复默认

    private var resetSection: some View {
        Section {
            Button {
                showResetConfirm = true
            } label: {
                Text("恢复默认模板")
                    .foregroundColor(JournalTheme.clay)
            }
            .listRowBackground(JournalTheme.cream)
        }
        .confirmationDialog("把模板恢复成默认？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                template = VocabPromptDefaults.template
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前编辑的模板会被覆盖。")
        }
    }
}
