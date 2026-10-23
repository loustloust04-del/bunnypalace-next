import SwiftUI

/// 面（聊天页消息面 / 输入条 / 右栏工具）两端共用的度量表（plan-mac-face §2-3，仿 `SettingsMetrics`）：
/// 页面写 `metrics.listInsetH`，不写 `#if os`。**只收两端值真不同的量**，值一律抄合流前的现值（面 1 不改任何数字）；
/// 两端相同的（输入条顶内距 6、回底钮边距 16）和键盘态公式（iOS 底内距 `kbUp ? 5 : -6`）留在原宿主，材质 / 玻璃留短平台修饰符。
/// 环境默认值按平台取（同 `SettingsMetrics.platform`），挪到父级的 Pin bar / 独立 sheet 不注入也对。
struct ChatMetrics {
    // MARK: 消息面
    /// 消息列表内距：iOS 16/16，mac 28/20（`CardFlowView` LazyVStack）
    var listInsetH: CGFloat
    var listInsetV: CGFloat
    /// Pin bar 外边距：mac 20/6/4 对齐 HoverButtons 外边缘（LazyVStack 16 + HoverButtons 4）；iOS 由 `iOSChatTopBar` 的 HStack 管布局，0
    var pinBarInsets: EdgeInsets
    /// 读书引用 sheet 最小尺寸：mac 700×600；iOS 系统给尺寸（nil = 不约束）
    var bookReaderMinSize: CGSize?

    // MARK: 输入条
    /// VStack { 附件条, 输入框, 控制行 } 的间距：iOS 10（始终 10：focused 时同样保留「附件条 ↔ 输入框」的间距），mac 6
    var composerStackSpacing: CGFloat
    /// 输入条水平内距：iOS 16，mac 28
    var composerInsetH: CGFloat
    /// 发送 / 停止 / 排队钮：图标字号 iOS 14 / mac 11，圆底 iOS 32 / mac 24（iOS 另有 44pt 外热区，留原宿主）
    var sendIconSize: CGFloat
    var sendFrame: CGFloat

    // MARK: 右栏
    /// 记忆卡正文行数：iOS 4，mac 3
    var memoryCardLines: Int
    /// 文件库头部按钮字号：iOS 12，mac 11；头部内距：iOS 16·10，mac 12·8
    var fileLibHeaderFontSize: CGFloat
    var fileLibHeaderInsetH: CGFloat
    var fileLibHeaderInsetV: CGFloat
    /// 贴纸选框删除钮：iOS 22pt 圆 + offset 16（另有 44pt 热区留原宿主），mac 14pt + offset 10
    var stickerDeleteSize: CGFloat
    var stickerDeleteOffset: CGFloat
    /// 文件库编辑器分屏方向：mac 左右、iOS 上下（宽高比决定；编辑器是 720×640 的 sheet，不受 tab 组宽限制）
    var fileLibSplitAxis: Axis

    static let iOS = ChatMetrics(
        listInsetH: 16, listInsetV: 16,
        pinBarInsets: EdgeInsets(),
        bookReaderMinSize: nil,
        composerStackSpacing: 10, composerInsetH: 16,
        sendIconSize: 14, sendFrame: 32,
        memoryCardLines: 4,
        fileLibHeaderFontSize: 12, fileLibHeaderInsetH: 16, fileLibHeaderInsetV: 10,
        stickerDeleteSize: 22, stickerDeleteOffset: 16,
        fileLibSplitAxis: .vertical
    )

    static let mac = ChatMetrics(
        listInsetH: 28, listInsetV: 20,
        pinBarInsets: EdgeInsets(top: 6, leading: 20, bottom: 4, trailing: 20),
        bookReaderMinSize: CGSize(width: 700, height: 600),
        composerStackSpacing: 6, composerInsetH: 28,
        sendIconSize: 11, sendFrame: 24,
        memoryCardLines: 3,
        fileLibHeaderFontSize: 11, fileLibHeaderInsetH: 12, fileLibHeaderInsetV: 8,
        stickerDeleteSize: 14, stickerDeleteOffset: 10,
        fileLibSplitAxis: .horizontal
    )

    static var platform: ChatMetrics {
        #if os(macOS)
        mac
        #else
        iOS
        #endif
    }
}

extension EnvironmentValues {
    @Entry var chatMetrics: ChatMetrics = .platform
}

extension View {
    /// 右栏 List 的平台样式：iOS `.insetGrouped` / mac `.plain`——六处完全同构的两分支收成一处；只换样式，不换 List / Form，不动 selection / delete 契约
    @ViewBuilder
    func panelListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.plain)
        #endif
    }
}
