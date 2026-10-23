// MP fork（perf M4，MemoryPalace docs/plan-chat-list-perf.md §1）：测量台注入的 TextKit / UITextView 计量钩子。
// 只在 DEBUG / PERF_BENCH 的 iOS 构建里存在（普通 Release 不编）；app 的严格测量角色才设置回调，
// 回调为 nil 时各插入点只做一次 nil 判断、行为不变。包不依赖 app。
#if (DEBUG || PERF_BENCH) && os(iOS)
import QuartzCore

public enum MarkdownPerfProbe {
  /// 被动 Air 计数独立于严格测量 span；nil 时不读时钟、不访问正文。
  public enum Call: String { case paragraphInit, paragraphSetContents, paragraphSizeThatFits }
  nonisolated(unsafe) public static var call: ((Call) -> Void)?
  /// Air 探针区段（宿主 AirProbeSections）：(区段名, 同步体)，宿主在体前后进出区段；nil 时直接跑、不读时钟
  nonisolated(unsafe) public static var section: ((StaticString, () -> Void) -> Void)?

  /// ParagraphUIView 一次 TextKit 排版（sizeThatFits / layoutSubviews）落在哪类（R12-06 修正）：
  /// first = 换内容后的首遍（firstGuess = 首遍是 intrinsicContentSize 在 bounds 宽 0 时按屏宽猜的）；guess = 之后的猜宽遍；
  /// zeroToReal = 上次观测到的 bounds 宽确实是 0、这次 > 0 的 layoutSubviews；widthChanged = 目标宽和上一遍不同的重排；other = 同宽重排
  public enum Pass: String { case first, firstGuess, guess, zeroToReal, widthChanged, other }

  /// L1a：ParagraphUIView 正文 / 几何入口（与 Pass 共用嵌套深度，最外层才报，各类互斥可相加）。
  /// setContents = setParagraphContents 除 attributedText 赋值外的部分（剧透 / 无障碍 / 划线 / 淡入）；
  /// setAttr = attributedText 赋值本身（UITextView 在这里按当时 frame 排版）；
  /// frame = frame / bounds setter（宿主摆放；宽高变了 UITextView 重排、容器尺寸通知、选区可见性）；
  /// recycle = 回池重置、prewarm = 空闲预热一批（L1 ①）；dismantle / leaveWindow / deinitView = 计数用的零时长事件
  /// （SwiftUI 拆段落视图 / 视图离开窗口 / 视图释放：回池路径通不通的证据）
  public enum Span: String { case setContents, setAttr, frame, recycle, prewarm, dismantle, leaveWindow, deinitView }

  /// (类别, 开始, 结束)，CACurrentMediaTime 秒；只报最外层（sizeThatFits 套在 layoutSubviews 里不重复计）
  nonisolated(unsafe) public static var layout: ((Pass, CFTimeInterval, CFTimeInterval) -> Void)?
  /// ParagraphUIViewCache 发出一个 UITextView：(池命中, 开始, 结束)；新建的耗时含 ParagraphUIView.init
  nonisolated(unsafe) public static var vend: ((Bool, CFTimeInterval, CFTimeInterval) -> Void)?
  /// L1a：(入口, 开始, 结束)，最外层；setContents 报的是扣掉内层 setAttr 之后的自身时长（开始 = 入口开始，结束 = 开始 + 自身）
  nonisolated(unsafe) public static var span: ((Span, CFTimeInterval, CFTimeInterval) -> Void)?
  /// L1 产品开关实际取值（进 run JSON，臂对账用）
  public static var l1Switches: [String: Bool] {
    ["pool": ParagraphL1Switch.pool]
  }
  /// 主线程嵌套深度（只报最外层）
  nonisolated(unsafe) static var depth = 0
}
#endif
