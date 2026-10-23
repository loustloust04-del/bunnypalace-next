/// 设置二级页标识，两端可见：mac 进 `MacSettingsPage` 的值驱动 path（页顶 ‹ › 靠它回退），iOS 只当标签，导航仍走 destination。
/// 新二级页加 case 后在 `MacSettingsPage.swift` 的 `SettingsRoute` 扩展里补 `title` / `macDestination`。
enum SettingsRoute: String, Hashable {
    case healthPermissions
    case memoryExtractPrompt
    case dreamPrompt
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
}
