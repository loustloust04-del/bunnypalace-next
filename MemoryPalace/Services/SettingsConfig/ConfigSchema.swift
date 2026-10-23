import Foundation

// MARK: - Config Schema (粟粟批了 C-D1~D6：JSON / 不含 Keychain / 全替换 / base64 / 直接上 / 存文件库)
//
// 设置一键导入导出的 schema 定义。白名单显式列出每个 key 类型，避免：
// - wildcard 兜底带出迁移标记等系统 key
// - 类型推断错（JSON Number 在 Swift 解码可能 Int/Double 混淆）

enum ConfigSchema {

    /// 当前 schema 版本。未来加新字段不需要升；改字段含义/删字段才升。
    static let currentVersion = 1

    /// 按界面/功能分段
    enum Section: String, CaseIterable {
        case general        // 通用：用户名、助手名、字号、字体
        case appearance     // 外观：气泡、显示项
        case memory         // 记忆系统
        case api            // API（不含 keychain key）
        case claudeCode     // CC bridge / nudge
        case tts            // 朗读
        case chat           // 聊天行为
        case fileLibrary    // 文件库
        case prompt         // Prompt 编辑模式等
        case permissions    // 权限档位（perm.*，AI 不可写）
        case dev            // 缓存/调试展开状态
    }

    enum Kind {
        case bool, int, double, string
    }

    /// @AppStorage key 全量白名单（按 section 分组；数量以数组为准，别在注释里写死——2026-08 已被 verify 抓过一次口径漂移）。
    /// 给 Exporter 用来 dump、Importer 用来 apply。
    static let appStorageKeys: [AppStorageEntry] = {
        var keys: [AppStorageEntry] = [
        // MARK: general
        .init("userName",                    .string, .general),
        .init("assistantName",               .string, .general),
        .init("selectedFont",                .string, .general),
        .init("fontScale",                   .double, .general),
        .init("lineSpacingScale",            .double, .general),
        .init("paragraphSpacingScale",       .double, .general),
        .init("blurRadius",                  .double, .general),
        .init("gardenSceneEnabled",          .bool,   .general),
        .init("feedbackGestureEnabled",      .bool,   .general),
        .init("exportMode",                  .string, .general),

        // MARK: appearance
        .init("showAvatar",                  .bool,   .appearance),
        .init("hideRoleName",                .bool,   .appearance),
        .init("hideTimestamp",               .bool,   .appearance),
        .init("hideActionBar",               .bool,   .appearance),
        .init("showFlagBlocks",              .bool,   .appearance),
        .init("showMessageUsage",            .bool,   .appearance),
        .init("chatBubbleMode",              .string, .appearance),
        .init("disableAutoTransparentBubblesOnWallpaper", .bool, .appearance),
        .init("bubbleCornerRadius",          .double, .appearance),
        .init("bubbleModeCornerRadius",      .double, .appearance),
        .init("bubblePaddingH",              .double, .appearance),
        .init("bubblePaddingV",              .double, .appearance),
        .init("bubbleSpacing",               .double, .appearance),
        .init("showStyleChip",               .bool,   .appearance),
        // 日历（按楼层的隐私开关 calendar.*.{pid} 不进导出：楼层 id 换机不通用）
        .init("calendar_monthStyle",         .string, .appearance),
        .init("calendar_cardColor",          .string, .appearance),
        .init("calendar_lightDots",          .bool,   .appearance),
        .init("calendar_metric",             .string, .appearance),

        // MARK: memory
        .init("mem_master",                  .bool,   .memory),
        .init("mem_inject_budget",           .int,    .memory),
        .init("mem_inject_full",             .bool,   .memory),
        .init("mem_inject_keyword",          .bool,   .memory),
        .init("mem_inject_vector",           .bool,   .memory),
        .init("mem_inject_tag",              .bool,   .memory),
        .init("mem_inject_graph",            .bool,   .memory),
        .init("mem_inject_catalog",          .bool,   .memory),
        .init("mem_content_facts",           .bool,   .memory),
        .init("mem_content_profile",         .bool,   .memory),
        .init("mem_inject_profile",          .bool,   .memory),
        .init("mem_self_recent_count",       .int,    .memory),
        .init("mem_self_daily_limit",        .int,    .memory),
        .init("mem_self_budget_percent",     .int,    .memory),
        .init("mem_self_body_limit",         .int,    .memory),
        .init("mem_content_summary",         .bool,   .memory),
        .init("mem_content_timeline",        .bool,   .memory),
        .init("mem_content_convhistory",     .bool,   .memory),
        .init("mem_content_filehistory",     .bool,   .memory),
        .init("mem_content_heartvoice",      .bool,   .memory),
        .init("mem_decay_enabled",           .bool,   .memory),
        .init("mem_extract_firstperson",     .bool,   .memory),
        .init("mem_infra_gateway",           .bool,   .memory),
        .init("mem_extract_interval",        .int,    .memory),
        .init("mem_supersede_soft",          .bool,   .memory),
        .init("customMemoryExtractionPrompt", .string, .memory),
        .init("memoryExtractModelId",        .string, .memory),
        .init("memoryExplanationExpanded",   .bool,   .memory),
        .init("imageTranscriptionEnabled",   .bool,   .memory),

        // MARK: api
        .init("apiKeyCloudSync",             .bool,   .api),
        .init("selectedChatModel",           .string, .api),

        // MARK: claudeCode
        .init("ccBindLan",                   .bool,   .claudeCode),
        .init("ccBindTailscale",             .bool,   .claudeCode),
        .init("ccNudgeEnabled",              .bool,   .claudeCode),
        .init("ccNewSessionStream",          .bool,   .claudeCode),
        .init("ccNudgeIdleMin",              .int,    .claudeCode),
        .init("ccNudgeIdleMax",              .int,    .claudeCode),
        .init("ccNudgeQuietStartMin",        .int,    .claudeCode),
        .init("ccNudgeQuietEndMin",          .int,    .claudeCode),
        .init("ccNudgeCooldown",             .int,    .claudeCode),
        .init("ccNudgeTemplate",             .string, .claudeCode),
        .init("ccShowThinking",              .bool,   .claudeCode),
        .init("ccHubEnabledByUser",          .bool,   .claudeCode),

        // MARK: tts
        .init("ttsEnabled",                  .bool,   .tts),
        .init("ttsRate",                     .double, .tts),

        // MARK: chat
        .init("ctx_compress_interval",       .int,    .chat),
        .init("sendImagesToModel",           .bool,   .chat),
        .init("maxImagesToModel",            .int,    .chat),
        .init("heartvoice_show_in_chat",     .bool,   .chat),

        // MARK: fileLibrary
        .init("fileLibraryEnabled",          .bool,   .fileLibrary),
        .init("fileLibraryInjectionTemplate", .string, .fileLibrary),
        .init("fileLibrarySortMode",         .string, .fileLibrary),
        .init("fileLibraryViewMode",         .string, .fileLibrary),
        .init("fileLibraryICloudEnabled",    .bool,   .fileLibrary),
        .init("attachmentCompressImages",    .bool,   .fileLibrary),

        // MARK: prompt
        .init("personaEditMode",             .string, .prompt),
        // 卡库设置（⑥，CardLibraryPreferences）；网页脚本开关 AI 不可写
        .init("cardLibrary.autoResume",      .bool,   .prompt),
        .init("cardLibrary.allowWebScripts", .bool,   .prompt, aiWritable: false),
        .init("cardLibrary.worldBookMaxEntries", .int, .prompt),
        .init("cardLibrary.sampleCardDismissed", .bool, .prompt),
        .init("wb_inject_budget",            .int,    .prompt),

        // MARK: dev（展开状态/调试）
        .init("cacheDashboardExpanded",      .bool,   .dev),

        // MARK: permissions（plan-权限管理 P1；AI 不可写黑名单）
        .init("perm.healthApple",         .int,    .permissions, aiWritable: false),
        .init("perm.healthWeight",        .int,    .permissions, aiWritable: false),
        .init("perm.healthMeds",          .int,    .permissions, aiWritable: false),
        .init("perm.healthCycle",         .int,    .permissions, aiWritable: false),
        .init("perm.healthIntimacy",      .int,    .permissions, aiWritable: false),
        ]
        #if PERSONAL_APPS
        keys += [
        .init("perm.trading",             .int,    .permissions, aiWritable: false),
        ]
        #endif
        keys += [
        .init("perm.memory",              .int,    .permissions, aiWritable: false),
        .init("perm.images",              .int,    .permissions, aiWritable: false),
        .init("perm.fileLibrary",         .int,    .permissions, aiWritable: false),
        .init("perm.topicBox",            .int,    .permissions, aiWritable: false),
        .init("perm.toolsMaster",         .int,    .permissions, aiWritable: false),
        .init("perm.webSearch",           .int,    .permissions, aiWritable: false),
        .init("perm.voiceProactive",      .int,    .permissions, aiWritable: false),
        .init("perm.pocket",              .int,    .permissions, aiWritable: false),
        .init("perm.calendar",            .int,    .permissions, aiWritable: false),
        .init("perm.reminders",           .int,    .permissions, aiWritable: false),
        .init("perm.clipboard",           .int,    .permissions, aiWritable: false),
        .init("perm.notifications",       .int,    .permissions, aiWritable: false),
        .init("perm.shell",               .int,    .permissions, aiWritable: false),
        .init("perm.twitter",             .int,    .permissions, aiWritable: false),
        // W-N N5 编程会话（域只在 mac 上有；数组字面量里写不了 #if，iOS 只是多一个用不到的键）
        .init("perm.codingSessions",      .int,    .permissions, aiWritable: false),
        ]
        return keys
    }()

    /// 结构化 JSON 存档（按 raw Data 复制；导入时整段覆盖）
    /// 只含轻量配置。楼层（带头像图 base64）走「数据与备份」。
    /// credentials 导出时会剥掉 .models 数组（model 列表可一键 fetchModels 重拉，
    /// 没必要导几百个 reranker/embedding；导入时按 presetId 补 preset 自带默认模型）。
    /// themes_v1 保留纯色配置；backgroundImageFileName 引用的图本身存在 Application Support，
    /// 跨机导入找不到图会 fallback 到默认（粟粟："纯色部分保留，背景图另说"）。
    static let structuredKeys: [StructuredEntry] = [
        // API
        .init("credentials",                 .api),         // API 卡 metadata（无 key 无 models）
        .init("favoriteModels",              .api),         // ☆ 收藏的复合 id 列表
        // 外观
        .init("themeDefinitions",            .appearance),  // 自定义主题（纯色配置；背景图文件名引用）
        // 右栏工具 / 仪表盘 widget 布局（这是"哪些工具显示在哪"的布局配置，不是内容）
        .init("rightPanelTools",             .general),     // 右栏工具配置
        .init("dashboardWidgets_v2",         .general),     // Dashboard widget 列表
        // MCP 服务器列表（含 server 配置但不含 token）
        .init("mcp_servers_v1",              .general),     // MCP server 配置
        // CC 终端键位
        .init("ccTerminalKeys",              .claudeCode),  // CC terminal 自定义键
        // 语音服务列表（厂商 / 地址 / 专有参数；key 走加密导出的 voice.<id>）
        .init(VoiceServiceStore.listKey,     .tts),
        // 注意：savedCharacterCards / globalWorldBooks 是【内容】不是设置，不导（粟粟 2026-06-14）
    ]

    /// 标量 UserDefaults（不是 @AppStorage 但也是配置；与 @AppStorage 走同一通道）
    static let extraScalarKeys: [AppStorageEntry] = [
        // CC Bridge URL override 是 UserDefaults 直接读写的
        .init("ccBridgeBaseURLOverride",     .string, .claudeCode),
        .init("ccBridgeBaseURLBackup",       .string, .claudeCode),
        .init("ccBridgeRelayURL",            .string, .claudeCode),   // #068 自建中继 wss 地址
        .init("ccBridgeRelayPin",            .string, .claudeCode),   // #068 中继自签证书 SPKI pin（不是口令）
        // 全局预算（spent 不导，避免还原后金额不对）
        .init("globalBudgetEnabled",         .bool,   .api),
        .init("globalBudgetUSD",             .double, .api),
        // 当前楼层
        .init("lastProfileId",               .string, .general),
        // 本地模式
        .init("localModeEnabled",            .bool,   .general),
        // ThemeManager 的三个标量（亮/暗模式 + 当前选中主题 + 是否走纯背景）
        .init("themeMode",                   .string, .appearance),
        .init("selectedThemeId",             .string, .appearance),
        .init("usePureBackground",           .bool,   .appearance),
        // HealthService：注入开关（"health.authRequested" 是状态标记不导）
        .init("health.injectionEnabled",     .bool,   .general),
        // CC 推送预览模式（full / hidden）
        .init("ccPushPreview",               .string, .claudeCode),
        // 只导开关；录音设备基线和任务代际是本机状态，不随配置跨设备搬运。
        .init("nativeVoiceCalls.enabled.v1", .bool, .tts, aiWritable: false),
        .init(VoiceProsodyStore.enabledKey,   .bool,   .tts, aiWritable: false),
        .init(SpeakerIdentityStore.enabledKey, .bool, .tts, aiWritable: false),
    ]

    /// 全部 scalar entries（@AppStorage + extra）
    static var allScalarEntries: [AppStorageEntry] {
        appStorageKeys + extraScalarKeys
    }

    struct AppStorageEntry {
        let key: String
        let kind: Kind
        let section: Section
        /// P3「AI 改设置」工具的可写面标记（plan-权限管理 §2 防自授权）：
        /// false = AI 永不可写（权限档位本身）。用户自己的导入导出不受此限。
        let aiWritable: Bool
        init(_ key: String, _ kind: Kind, _ section: Section, aiWritable: Bool = true) {
            self.key = key; self.kind = kind; self.section = section; self.aiWritable = aiWritable
        }
    }

    struct StructuredEntry {
        let key: String
        let section: Section
        init(_ key: String, _ section: Section) {
            self.key = key; self.section = section
        }
    }
}
