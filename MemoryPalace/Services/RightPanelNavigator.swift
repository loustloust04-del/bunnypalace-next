import Foundation

/// 搜索结果点击后，协调「打开右栏 + 切 tool + 滚动到条目 + 高亮闪烁」的跳板。
/// 各面板 onChange(pendingTarget) 消费后置 nil，并自行做 scrollTo + 1.5s 高亮动画。
@Observable
final class RightPanelNavigator {
    struct Target: Equatable {
        let tool: String     // "memory" / "worldBook" / "cardLibrary"
        let id: String       // 面板内滚动目标 id（要和 row 的 `.id(...)` 对齐）
    }

    var pendingTarget: Target? = nil

    /// 卡墙切楼层会重建 ContentView；只跨这次重建保留返回意图，不持久化。
    var cardLibraryReturnProfileId: String? = nil
    struct CharacterHome: Equatable {
        let profileId: String
        let cardId: String?
        /// 卡库设置「点卡直接进最近的聊天」：角色页出现后续一次最近的非回收站聊天（⑥）
        var autoResume = false
    }
    var characterHome: CharacterHome?

    func openCharacterHome(profileId: String, cardId: String?, autoResume: Bool = false) {
        characterHome = CharacterHome(profileId: profileId, cardId: cardId, autoResume: autoResume)
        cardLibraryReturnProfileId = profileId
    }

    /// 卡库世界书页要打开的书 / 条目（`floor:<bookId>[:<entryId>]` / `global:…`）。
    /// 跨楼层书「切到这个楼层」会重建 ContentView，靠它把人带回那本书；卡库消费后置 nil，不持久化（⑥）
    var cardLibraryWorldBookTarget: String? = nil
    /// 设置搜索跳卡库「设置」页签用的 pendingTarget id（tool = "cardLibrary"）
    static let cardLibrarySettingsTargetId = "tab:settings"
}
