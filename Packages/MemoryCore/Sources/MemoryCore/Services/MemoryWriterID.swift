import Foundation

/// 记忆 v5 的写入编号（`记忆系统v5.md` §1）：A 对话一层层往下压 / B {助手}自己的主观 / C 客观事实。
/// 设置页「写入 · 记什么」一个编号一行，点进去是这一项的二级页
public enum MemoryWriterID: String, CaseIterable, Identifiable {
    case a2, a3, a4, b1, b2, b3, b4, c, c2, c3

    public var id: String { rawValue }
    public var code: String { rawValue.uppercased() }

    /// 还没做（照样列出，标「还没做」）
    public var isTodo: Bool { [.b2, .b3].contains(self) }
    /// 有开关（C 只是看；还没做的没有）
    public var hasSwitch: Bool { !isTodo && self != .c }
    /// 后台写手：算写入预算、有自己的模型 / 触发（B1 / B4 是{助手}本人调工具，不算）
    public var isBackground: Bool { [.a2, .a3, .a4, .c2, .c3].contains(self) }
    /// 触发三选一（停 N 分钟 / 每 N 回合 / 只手动）；A4 一天一条固定过了 05:00 拼前一天
    public var hasTrigger: Bool { [.a2, .a3].contains(self) }

    public func title(assistant: String) -> String {
        switch self {
        case .a2: return "上下文摘要"
        case .a3: return "窗口总结"
        case .a4: return "时间轴"
        case .b1: return "心声"
        case .b2: return "\(assistant)日记"
        case .b3: return "做梦"
        case .b4: return "\(assistant)的记忆"
        case .c: return "档案"
        case .c2: return "碎片池"
        case .c3: return "整理编目"
        }
    }

    /// 列表行的一句话（小样原文）；还没做的写「还没做」
    public func subtitle(assistant: String) -> String {
        switch self {
        case .a2: return "挤出视野的一段段记下"
        case .a3: return "整个窗口压成一段，长度按段数分档"
        case .a4: return "一天一条，跨所有窗口"
        case .b1: return "\(assistant)聊到触动处写独白"
        case .b4: return "\(assistant)自己记、改、划掉的"
        case .c: return "关键词 + 原文"
        case .c2: return "小模型填表，格式不对不收"
        case .c3: return "碎片和聊天整理成 wiki 页，先过目再写"
        case .b2, .b3: return "还没做"
        }
    }

}
