/// 一轮记忆参与度的唯一真值：一处算、处处传（plan `plan-memory-participation.md` §2.1）。
///
/// app 侧把四个开关源的快照填进 `Switches`，X 自动注入 / Z 插槽 / Y 工具下发 / A2 写侧 /
/// 检查器 / 测试台都只读这个值，不再各自拼 `master && memoryEnabled && …`。
/// 纯函数：不读进程偏好、不碰持久化模型、不落盘（每次现算）。
/// 两道闸：`participates`（Z 段 / 工具 / 写侧 / recall 执行层）与 `on`（X + Z7，含记忆槽）。
/// 真值表见 plan §2.2；本文件字段与那张表逐格对应。
public struct EffectiveMemoryParticipation: Sendable, Equatable {
    /// 四个开关源的快照，由 app 填。
    public struct Switches: Sendable, Equatable {
        /// `mem_master`
        public var master: Bool
        /// `Conversation.memoryEnabled`
        public var window: Bool
        /// 预设记忆槽 `isEnabled && isMarker`
        public var slot: Bool
        /// 本窗六项；nil = 老窗 → 用 `legacy`
        public var choices: Choices?
        /// `legacy(profileId:)`：timeline = pending = A4 勾、selfMemory = B4 勾、
        /// archive = pinned = C 勾、previousWindow = false
        public var legacy: Choices
        /// `MemoryOpenWindow.isChecked(.a2)`
        public var a2Checked: Bool
        /// `RecallTuning.archiveTriggerEnabled`
        public var archiveTrigger: Bool

        public init(master: Bool, window: Bool, slot: Bool, choices: Choices?,
                    legacy: Choices, a2Checked: Bool, archiveTrigger: Bool) {
            self.master = master
            self.window = window
            self.slot = slot
            self.choices = choices
            self.legacy = legacy
            self.a2Checked = a2Checked
            self.archiveTrigger = archiveTrigger
        }
    }

    /// 本窗六项（`MemoryWindowChoices` 的读侧快照）。
    public struct Choices: Sendable, Equatable {
        public var timeline: Bool
        public var pending: Bool
        public var selfMemory: Bool
        public var archive: Bool
        public var previousWindow: Bool
        public var pinned: Bool

        public init(timeline: Bool, pending: Bool, selfMemory: Bool,
                    archive: Bool, previousWindow: Bool, pinned: Bool) {
            self.timeline = timeline
            self.pending = pending
            self.selfMemory = selfMemory
            self.archive = archive
            self.previousWindow = previousWindow
            self.pinned = pinned
        }
    }

    /// 整体关的原因：master → window → slot 先到先记。
    public enum Off: String, Sendable {
        case master, window, slot
    }

    /// 原料原样保留（检查器要未闸的 slot / 勾）。
    public let switches: Switches
    /// 解析后的 `choices ?? legacy`（未闸）。
    public let choices: Choices
    public var isLegacy: Bool { switches.choices == nil }
    /// 整体关的原因（master → window → slot 先到先记）；nil = 开。
    public let off: Off?
    /// = `participates && slot`：X + Z7 的闸。
    public var on: Bool { off == nil }
    /// = `master && window`：Z 段 / 工具 / 写侧 / recall 执行层的闸（不看槽——
    /// 时间轴 / A2 是独立插槽，`PromptAssembler` 各自管）。
    public let participates: Bool

    // X 自动注入（都已含 on）
    /// C 碎片 + 根索引
    public let archive: Bool
    /// 钉住
    public let pinned: Bool
    /// 触发词命中的 wiki 页：`on && (isLegacy || choices.archive) && archiveTrigger`
    /// ← `MemoryInjector.roundInputs` 的 `triggerOn` 现状
    public let pages: Bool
    /// 原文兜底候选 = `pages`（VM 预热段的 `windowArchive != false` 写法并入同一式）
    public let fullText: Bool
    public let selfMemory: Bool
    /// Z7，只判这一次（老窗钉死为假，不信任 legacy 传值）
    public let previousWindow: Bool

    // Z 插槽（吃 participates，不吃槽）
    public let timeline: Bool
    public let pending: Bool
    /// `timeline || pending`（决策 1：归「记忆」，master 关 / 本窗关不带）
    public let anniversary: Bool
    /// `participates && a2Checked`（本窗无 A2 项，照楼层勾）
    public let a2Summary: Bool

    // Y 闸（工具下发）
    /// remember / edit / forget / pending_notes / suggest 下发 = `participates`（不看槽）；
    /// 各工具楼层开关照旧在 `ToolRegistry` 里 AND。
    /// recall 照旧下发，执行层只留 messages / search（决策 2，现状）。
    public let writeTools: Bool

    // 写侧
    /// A2 API 回合 / idle / 手动压缩 = `participates`（决策 3；楼层
    /// `contextSummaryEnabled` 照旧在原处 AND）
    public let a2Write: Bool

    public init(_ s: Switches) {
        participates = s.master && s.window
        let gate = participates && s.slot
        let c = s.choices ?? s.legacy
        off = !s.master ? .master : (!s.window ? .window : (!s.slot ? .slot : nil))
        switches = s
        choices = c
        archive = gate && c.archive
        pinned = gate && c.pinned
        pages = gate && (s.choices == nil || c.archive) && s.archiveTrigger
        fullText = pages
        selfMemory = gate && c.selfMemory
        previousWindow = gate && s.choices != nil && c.previousWindow
        timeline = participates && c.timeline
        pending = participates && c.pending
        anniversary = timeline || pending
        a2Summary = participates && s.a2Checked
        writeTools = participates
        a2Write = participates
    }

    /// 来源窗隐藏集：`isTrashed || !memoryEnabled` 的窗 id。
    ///
    /// 用隐藏集而非可见集：来源窗**不存在**（被物理删 / 导入丢）的碎片照带（现状），
    /// 只有已删 / 关参与的窗才挡。Y 侧 `ALine` 可见集语义不同（它翻别的窗，本来就该挡不存在的）。
    public static func hiddenSources(_ windows: [ConversationWindow]) -> Set<String> {
        Set(windows.filter { $0.isTrashed || !$0.memoryEnabled }.map(\.id))
    }
}

extension RecallGateSnapshot {
    /// 一轮参与度的读侧投影（plan-memory-receipt §2.1）。碎片 off 时恒 0；时间轴 / 待续只看
    /// `participates`（时间轴是独立插槽，本窗关着槽照样注入、照样按来源窗挡）。
    public init(_ p: EffectiveMemoryParticipation, hiddenFragments: Int, hiddenTimeline: Int) {
        self.init(off: p.off?.rawValue, participates: p.participates,
                  triggerOff: !p.switches.archiveTrigger, legacy: p.isLegacy,
                  choices: ["timeline": p.choices.timeline, "pending": p.choices.pending,
                            "selfMemory": p.choices.selfMemory, "archive": p.choices.archive,
                            "previousWindow": p.choices.previousWindow, "pinned": p.choices.pinned],
                  a2Checked: p.switches.a2Checked,
                  hiddenFragments: p.off == nil ? hiddenFragments : 0,
                  hiddenTimeline: p.participates ? hiddenTimeline : 0)
    }
}
