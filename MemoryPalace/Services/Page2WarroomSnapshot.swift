import Foundation
import Observation


@MainActor
@Observable
final class Page2SceneState {
    static let shared = Page2SceneState()
    var isActive = false
    var prefersLightStatusBar = false
    var isEditing = false
    /// page2 开着全屏应用：藏状态栏，左上角的回桌面弧线才按得到（plan-page2-app-shell §2.6）
    var hidesStatusBarForApp = false
    /// 开着的全屏应用自己要系统状态栏（终端：rootshell 样式把时间电量还给系统，D2）。
    /// 跟上面那个分开：「应用盖住桌面」照旧算盖住（壁纸照停），只是状态栏不藏、改浅色字
    var appShowsStatusBar = false
    /// 右边竖条开着（#085）：内容被糊住，花园停（翻页1mac 审：模糊每帧重算太贵）
    var stripOpen = false
    var stripTransitioning = false
    var stripSceneActive = true
    /// page2 这一页此刻的横向位移（翻页时逐帧写）；nil = 整页不在屏幕上。回桌面弧线跟着它走
    var pageOffset: CGFloat?
    var date = Date()
}
