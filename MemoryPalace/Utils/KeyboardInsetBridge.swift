#if os(iOS)
import SwiftUI
import Combine

/// 键盘避让值桥（research-keyboard-list-inset）：外层 PagingViewController 的
/// applyKeyboardAvoidance 是全 app 唯一键盘信源（bogus 帧过滤/去重齐全），它算好的
/// extra 经此桥发布给聊天列表的 contentMargins——列表避让与输入框避让严格同源，
/// 杜绝第二个键盘 observer 抢时序（上一刀输入框被顶没的教训）。
@MainActor
final class KeyboardInsetBridge: ObservableObject {
    static let shared = KeyboardInsetBridge()
    /// 键盘在 chat HC 里的额外避让量（已扣 systemBottom）。0 = 键盘收起
    @Published var extra: CGFloat = 0 {
        didSet {
            #if DEBUG
            KBProbe.log("[PUB] extra \(oldValue)→\(extra)")
            #endif
        }
    }
    /// 键盘过渡动画进行中（willChangeFrame→didChangeFrame 窗口）。回底按钮显隐不能只看
    /// extra==0：收键盘时 extra 在动画开始就清零，按钮会提前露头压在未落稳的输入条上
    ///（sol 终审 §3 漏窗）。PagingViewController 发布。
    @Published var kbTransitioning: Bool = false {
        didSet {
            #if DEBUG
            KBProbe.log("[PUB] kbTransitioning \(oldValue)→\(kbTransitioning)")
            #endif
        }
    }
    /// 键盘在场（样式驱动专用，与 extra 时序解耦）：willChangeFrame(docked)=true，
    /// willHide 即刻=false——输入条 kbUp 样式（底距/渐变）在下滑**开始**时切换混进
    /// 大位移；extra 清零延到落地（垫块塌焊帧时序），两者不再绑死（2026-08-16
    /// 粟粟「输入框滑到底再坐一下」= 样式切换被 extra 延迟拖到落地后的病根）。
    @Published var kbVisible: Bool = false {
        didSet {
            #if DEBUG
            KBProbe.log("[PUB] kbVisible \(oldValue)→\(kbVisible)")
            #endif
        }
    }
    /// 发送触发的收键盘走瞬收（2026-08-16 发送大跳案）：滑出让位动画的语义是「键盘走了
    /// 内容下移补位」，但发送瞬间新气泡刚在底部插入——动画把视口向历史方向拉 312pt =
    /// 气泡被顶到屏幕中间再复位。发送前置位（1s 窗口），willHide 读到即走无动画一步到终态，
    /// 弹泡动画独占舞台（老版行为等价）。
    var sendDismissUntil: CFTimeInterval = 0
    /// 收键盘 release 握手（research-keyboard-follow-animation §4b）：垫块由 PagingVC hold 到收起流程结束，
    /// release 时它在同一 runloop 里先写这里、再把 extra 发成 0；CardFlowView 的 onChange(extra→0) 在
    /// **同一次 update** 里直写 offset（与塌垫块同帧）。在底 = -inset；离底 = 当前 - hold。控制信号非 @Published。
    var hideReleaseOffset: CGFloat? = nil
    /// 离底弹键盘「冷弹回底」的范围（屏数）：以内回底、以外内容原地（粟粟 08-16「深翻原地」+ 08-26「一屏内才回底」）。
    /// CardFlowView 冷弹判定与 PagingVC farAway 判定共用这一处。
    static let returnToBottomScreens: CGFloat = 1.0
    /// send-scroll-policy（粟粟 09-07 规则 1/2）：发送时刻的回底分档——离底 ≤1.5 屏发送自动回底，
    /// 以外内容锚定不动（新回复靠回底钮徽章）。与键盘冷弹的 returnToBottomScreens(1.0) 是两件事。
    static let sendReturnToBottomScreens: CGFloat = 1.5
    /// 深翻抑制垫块（08-26 research-keyboard-follow-animation §4f）：离底超过 returnToBottomScreens 时弹键盘，
    /// 垫块**不长**（键盘盖住的是底部空白，最新消息不在屏上；零布局变化 → SwiftUI 无事可做，不会再
    /// 用它自己的 offset 补偿跟我们的钉位叠成双份 = 「深翻弹键盘有时候跳」的根因，JUMP 栈实证）。
    /// 滚回 returnToBottomScreens 以内松手/到底 → CardFlowView 调 liftPadSuppression，PagingVC 重发几何 + 回底。
    var padSuppressed = false
    var liftPadSuppression: (() -> Void)?
    /// C-slide（research-input-newline-carrier）：可见输入条栈实高，InputBarStack 根 onGeometryChange
    /// 自报（动画期报终值 F4）。carrier 定高后它取代「容器高=内容高」当真相：publishKeyboardGeometry
    /// 的 containerTop/growth、PassthroughContainerView 的 hitTest 放行线都读它。主线程读写；非 @Published
    ///（发布走 publishKeyboardGeometry 统一出口，带曲线）。
    var barVisibleHeight: CGFloat = 74
    /// 输入条此刻只是 ➕ 面板的透明占位：carrier 整块放行触摸（InputBarStack 写，主线程；astra R6 C1）
    var barIsPlaceholder = false
    /// 录语音锁定态浮在输入条上方的锁 + 大按钮（plan-voice-note M5c）：落在这块里的触摸不放行给聊天列表。
    /// 坐标 = 输入条栈的 `chatInputBar` 空间（原点 = 可见栈顶），hitTest 按 carrier 高 - barVisibleHeight 换成 carrier 坐标。
    /// 只在锁定态有值，其余 nil（VoiceRecordController 写，主线程）。不参与 barVisibleHeight / inset 计算
    var recordingHitRect: CGRect? = nil
    /// C9：字段高度动画时长（提交点 withAnimation 与垫块 publish 同曲线同时长）
    static let fieldHeightAnimation: TimeInterval = 0.22
    /// 输入条容器顶边（chat HC 坐标 ≈ global）。UIKit 侧发布（KVO + 键盘落稳 + layout 兜底）——
    /// 容器被 keyboardLayoutGuide 整体搬动时 SwiftUI 内部无 layout pass，.global 测量会滞留，
    /// 所以容器位移的真值必须由搬动它的 UIKit 层报（sol 终审 §4：KVO 只管容器级终点）。
    @Published var containerTop: CGFloat = 0 {
        didSet {
            #if DEBUG
            KBProbe.log("[PUB] containerTop \(oldValue)→\(containerTop)")
            #endif
        }
    }
    /// 输入字段顶边相对输入条栈根的偏移。SwiftUI 白盒自报（chip 行/引用条把字段推下去多少
    /// 它自己最清楚，不在外面用常数猜——sol 终审 §1：容器顶≠字段顶，差值随 chip 浮动 6~88pt）。
    @Published var fieldOffsetInBar: CGFloat = 0 {
        didSet {
            #if DEBUG
            KBProbe.log("[PUB] fieldOffsetInBar \(oldValue)→\(fieldOffsetInBar)")
            #endif
        }
    }
    /// 回底按钮锚点 = 输入字段真实顶边（B2 前 InputFieldBoundsKey 的语义等价还原）
    var inputFieldTop: CGFloat { containerTop + fieldOffsetInBar }
    /// 输入条超出 compact 单行的增量（chip 行 + 引用条 + 编辑器多行部分）。ChatInputBar
    /// 白盒自报，列表垫块消费——单行无附件时恒 0，列表行为与固定 margin 时代逐像素一致。
    @Published var barGrowth: CGFloat = 0 {
        didSet {
            #if DEBUG
            KBProbe.log("[PUB] barGrowth \(oldValue)→\(barGrowth)")
            #endif
        }
    }
    /// 输入条内容变化 → UIKit 层补一脚 layout 的通道。嵌套 UIHostingView 下
    /// intrinsicContentSize 失效不驱动 Auto Layout re-solve（KB-P3 探针实锤：打字时
    /// intrinsic 55→109 容器钉死 55），SwiftUI 侧在内容变化点 +1，PagingViewController
    /// 收到后 invalidate+layoutIfNeeded 让容器跟上理想高度。
    /// input-jank F1（09-02）：kick 是控制信号，**不走 @Published**——之前每键 `&+= 1` 让 CardFlowView/ChatInputBar/
    /// InputBarStack 三个 @ObservedObject 订阅者整棵 body 重跑（research-input-jank.md §2）。PassthroughSubject 只有
    /// PagingViewController 一个 sink 收，SwiftUI 观察链不感知。
    let barKick = PassthroughSubject<Void, Never>()
    /// chat 输入条抑制：非聊天页（如中庭房间页有自己的 composer）时隐藏常驻输入条——
    /// inputBarHost 是 UIKit 子层永远盖在 chat 页 SwiftUI 之上，不隐藏就双输入框叠层
    ///（07-20 粟粟群消息全进新建私聊的根因：她打字的是被盖着的聊天输入条）。
    @Published var chatInputSuppressed: Bool = false {
        didSet {
            #if DEBUG
            KBProbe.log("[PUB] chatInputSuppressed \(oldValue)→\(chatInputSuppressed)")
            #endif
        }
    }
    private init() {}
}
#endif
