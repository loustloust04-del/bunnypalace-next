import SwiftUI


/// iMessage 式弹泡参数（plan-bubble-pop-tuner）。聊天动画与调音台面板共用同一组真值：
/// 面板滑条写 UserDefaults，transition 工厂构造时读——行插入/重放时取到最新值，即调即生效。
///
/// v2（粟粟：还不够舒服，加参数）：换自定义 Animatable modifier 插值器——
/// spring 过冲时 progress>1，缩放/位移/倾斜/形变全部自然反向过冲，真果冻。
enum BubblePopTuning {
    static let bounceKey = "popBounce"
    static let durationKey = "popDuration"
    static let scaleFromKey = "popScaleFrom"
    static let offsetYKey = "popOffsetY"
    static let velocityKey = "popVelocity"
    static let jellyKey = "popJelly"
    static let tiltKey = "popTilt"
    static let offsetXKey = "popOffsetX"
    static let settleKey = "popSettle"

    // 出厂默认 = 粟粟 2026-07-09 真机调音定稿（devicectl 拉 plist 取证）——
    // 灵魂改动：冲劲 4→10（"跳出来"的爆发感）、起点 0.55→0.43、时长 0.40→0.36
    static let defaultBounce = 0.43
    static let defaultDuration = 0.36
    static let defaultScaleFrom = 0.43
    static let defaultOffsetY = 41.0
    static let defaultVelocity = 10.0
    static let defaultJelly = 0.25
    static let defaultTilt = 4.0
    static let defaultOffsetX = 17.0
    static let defaultSettle = 1.7

    private static func read(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    static var bounce: Double { read(bounceKey, defaultBounce) }
    static var duration: Double { read(durationKey, defaultDuration) }
    static var scaleFrom: Double { read(scaleFromKey, defaultScaleFrom) }
    static var offsetY: Double { read(offsetYKey, defaultOffsetY) }
    static var velocity: Double { read(velocityKey, defaultVelocity) }
    static var jelly: Double { read(jellyKey, defaultJelly) }
    static var tilt: Double { read(tiltKey, defaultTilt) }
    static var offsetX: Double { read(offsetXKey, defaultOffsetX) }
    static var settle: Double { read(settleKey, defaultSettle) }

    /// 弹泡 spring：bounce=果冻回弹（0 不弹 0.3 轻快 0.5 Q弹 0.7 夸张），
    /// initialVelocity=起手冲劲（被「抛出来」的初速度感）
    static var popAnimation: Animation {
        .interpolatingSpring(duration: duration, bounce: bounce, initialVelocity: velocity)
    }

    /// 旧行推移专用：无冲劲的柔和 spring——新泡插入时旧泡腾位置的动画。
    /// 若与 popAnimation 共用事务，initialVelocity 会把旧行也「甩」出去过冲（粟粟：倒数第二条被干扰）。
    static var pushAnimation: Animation {
        .spring(duration: duration, bounce: min(bounce * 0.6, 0.25))
    }

    /// 弹入 transition：自定义插值器（offset 斜抛 + 出生角缩放 + 倾斜 + squash 形变 + 淡入）。
    /// user=右下（输入框方向）出生，assistant=左下。removal 淡出不弹（删除/重生成别跳）。
    /// ⚠️ 反转列表：必须挂在 cell 翻回正之后的内容上（.flippedUpsideDown() 的内侧）。
    static func popTransition(isUser: Bool) -> AnyTransition {
        .asymmetric(
            // ⚠️ 不要给 transition 绑 .animation(popAnimation) 自带动画：interpolatingSpring 是
            // additive（文档："adding the effects of each animation"）——自带动画与事务动画
            // 双驱动同一 progress 会叠加，冲劲 10 变 20，泡放大数倍飞出容器（录屏 f648 铁证，
            // 粟粟报"诡异"全案根因）。插入动画一律由事务驱动（容器 .animation / withAnimation）。
            insertion: .modifier(
                active: BubblePopModifier(progress: 0, isUser: isUser),
                identity: BubblePopModifier(progress: 1, isUser: isUser)
            ),
            removal: .opacity
        )
    }

    static func resetToDefaults() {
        let d = UserDefaults.standard
        [bounceKey, durationKey, scaleFromKey, offsetYKey,
         velocityKey, jellyKey, tiltKey, offsetXKey, settleKey].forEach { d.removeObject(forKey: $0) }
    }
}

/// 弹入插值器：spring 驱动 progress 0→1（过冲时 >1，全成分自然反向过冲=果冻感）。
/// 参数在构造时快照（调音台改完下一次插入生效）。
struct BubblePopModifier: ViewModifier, Animatable {
    var progress: Double
    let isUser: Bool
    private let scaleFrom = BubblePopTuning.scaleFrom
    private let offX = BubblePopTuning.offsetX
    private let offY = BubblePopTuning.offsetY
    private let tilt = BubblePopTuning.tilt
    private let jelly = BubblePopTuning.jelly
    private let settle = BubblePopTuning.settle

    init(progress: Double, isUser: Bool) {
        self.progress = progress
        self.isUser = isUser
    }

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // inv：距离定位还差多少（过冲时为负 → 反向回摆）——驱动位移/缩放
        let inv = 1 - progress
        // 相位分离（粟粟：回落有点呆）：形变/倾斜按 settle 倍提前回正，位移殿后单独落位——
        // 真实果冻物理里形变恢复（高频）快于位移（低频），同相回落=「一坨飘下来」的呆感。
        // 过冲段（progress>1）反向拉伸保留但减幅，落定点两支都归零（连续）。
        let shapeAmount: Double = progress < 1
            ? max(0, 1 - progress * settle)
            : (1 - progress) * 0.6
        let anchor: UnitPoint = isUser ? .bottomTrailing : .bottomLeading
        let baseScale = scaleFrom + (1 - scaleFrom) * progress
        let side: Double = isUser ? 1 : -1
        return content
            // squash & stretch：入场横宽竖扁，过冲自然反转成竖长
            .scaleEffect(
                x: max(0.01, baseScale * (1 + jelly * 0.35 * shapeAmount)),
                y: max(0.01, baseScale * (1 - jelly * 0.35 * shapeAmount)),
                anchor: anchor
            )
            .rotationEffect(.degrees(tilt * shapeAmount * side), anchor: anchor)
            // 斜抛：从输入框角落方向（user 右下 / assistant 左下）跳入
            .offset(x: offX * inv * side, y: offY * inv)
            // 前半程淡入，过冲段保持不透明
            .opacity(progress <= 0 ? 0 : min(1, progress * 2.5))
    }
}
