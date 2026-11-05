import Foundation

/// 设置二级页标识，两端可见：mac 进 `MacSettingsPage` 的值驱动 path（页顶 ‹ › 靠它回退），iOS 只当标签，导航仍走 destination。
/// 新二级页加 case 后在 `MacSettingsPage.swift` 的 `SettingsRoute` 扩展里补 `title` / `macDestination`。
enum SettingsRoute: String, Hashable {
    case healthPermissions
    case memoryExtractPrompt
    /// 记忆 v5：写入编号的二级页（A2 / A3 / A4 / B1 / B4 / C / C2 / C3）
    case memoryWriterA2, memoryWriterA3, memoryWriterA4, memoryWriterB1, memoryWriterB4, memoryWriterC, memoryWriterC2, memoryWriterC3
    /// C3 二级页 › 不触发的词
    case memoryCatalogStopWords
    /// 记忆 v5：写入预算 / 开窗口带什么 / 待续 / 档案列表 / {助手}的记忆列表 / 审计台
    case memoryWriteBudget, memoryOpenWindow, memoryPending, memoryArchiveList, memorySelfList, memoryAudit
    /// 审计台「整理提案」› 一份提案的详情；mac 上打开哪份看 `WikiProposalSelection`
    case memoryProposal
    /// 一份提案 › 一个目录项的详情和原料；mac 上打开哪一项看 `WikiProposalSelection.item`
    case memoryProposalItem
    case themeLibrary
    case themeColors
    case chatBackground
    case appearanceFont
    case appearanceWaiting
    case appearanceAdvanced
    case highlightColors
    /// 宽屏布局（面板四项）：只 iPad 有入口；mac 的同一组在 Mac 工作区
    case wideLayout
    /// 开源致谢：mac 关于页的二级页（iOS 在 `IOSAboutPage` 里直接推 `IOSAcknowledgementsPage`）
    case acknowledgements
    case voiceServices
    /// 导入历史 › 一次导入的详情（#061）；mac 上打开哪条记录看 `ImportRecordSelection`
    case importRecordDetail
    /// Prompt › 工具抽屉（#093）：mac 设置窗里推入；聊天右栏 / page2 走 sheet
    case toolDrawer
}

extension SettingsRoute {
    /// 写入编号二级页对应的编号（别的页 nil）
    var memoryWriterID: MemoryWriterID? {
        switch self {
        case .memoryWriterA2: return .a2
        case .memoryWriterA3: return .a3
        case .memoryWriterA4: return .a4
        case .memoryWriterB1: return .b1
        case .memoryWriterB4: return .b4
        case .memoryWriterC: return .c
        case .memoryWriterC2: return .c2
        case .memoryWriterC3: return .c3
        default: return nil
        }
    }

    /// 编号 → 它的二级页（还没做的没有）
    static func memoryWriter(_ id: MemoryWriterID) -> SettingsRoute? {
        switch id {
        case .a2: return .memoryWriterA2
        case .a3: return .memoryWriterA3
        case .a4: return .memoryWriterA4
        case .b1: return .memoryWriterB1
        case .b4: return .memoryWriterB4
        case .c: return .memoryWriterC
        case .c2: return .memoryWriterC2
        case .c3: return .memoryWriterC3
        case .b2, .b3: return nil
        }
    }

    /// 页名里的{助手}：取 @AppStorage("assistantName") 同一个键，没填叫「助手」
    static var assistantName: String {
        let n = (UserDefaults.standard.string(forKey: "assistantName") ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "助手" : n
    }
}
