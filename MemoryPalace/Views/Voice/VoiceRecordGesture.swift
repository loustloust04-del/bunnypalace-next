import CoreGraphics
import Foundation

/// 按住录语音的手势判定（plan-voice-note M5a）。数值照小样 / TG 原值（docs/design-voice-record.html）。
/// 纯函数：手势壳（`VoiceRecordController`）只负责喂事件、执行结果。dx / dy 是相对按下点的位移（左 / 上为负）。
enum VoiceRecordGesture {
    /// 按住这么久才开录；之内抬手 = 点按
    static let holdToRecord: TimeInterval = 0.19
    /// 两次触摸间隔不到这个数的，后一次整个忽略
    static let debounce: TimeInterval = 0.4
    /// 录不到这么久不发
    static let minDuration: TimeInterval = 0.5
    /// 拖动中直接触发
    static let dragCancelX: CGFloat = -150
    static let dragLockY: CGFloat = -110
    /// 松手时判定
    static let releaseCancelX: CGFloat = -100
    static let releaseLockY: CGFloat = -60
    static let flingVelocity: CGFloat = -400

    enum Event: Equatable {
        /// 按下；sinceLastTouchEnd = 距上一次触摸结束
        case down(sinceLastTouchEnd: TimeInterval)
        /// 拖动；recording = 已开录（没开录前的拖动不算）
        case move(dx: CGFloat, dy: CGFloat, recording: Bool)
        /// 抬手；recordedDuration = nil 表示还没开录；vx / vy pt/s
        case up(dx: CGFloat, dy: CGFloat, vx: CGFloat, vy: CGFloat, recordedDuration: TimeInterval?)
    }

    enum Outcome: Equatable {
        /// 这次触摸不管（防连点）
        case ignore
        /// 开始计时，holdToRecord 后开录
        case arm
        /// 继续跟手
        case track
        /// 没到开录就抬手：提示「按住说话」
        case tap
        case cancel
        case lock
        case send
        /// 不到 0.5 秒：不发，错误震动 + 提示
        case tooShort
    }

    static func decide(_ event: Event) -> Outcome {
        switch event {
        case .down(let since):
            return since < debounce ? .ignore : .arm
        case .move(let dx, let dy, let recording):
            guard recording else { return .track }
            // 只认左、上两个方向
            if min(0, dx) < dragCancelX { return .cancel }
            if min(0, dy) < dragLockY { return .lock }
            return .track
        case .up(let dx, let dy, let vx, let vy, let duration):
            guard let duration else { return .tap }
            // 先看左拖还是上拖更多，另一个方向记 0
            var fx = min(0, dx), fy = min(0, dy)
            if abs(fx) > abs(fy) { fy = 0 } else { fx = 0 }
            if vx < flingVelocity || fx < releaseCancelX { return .cancel }
            if vy < flingVelocity || fy < releaseLockY { return .lock }
            return duration < minDuration ? .tooShort : .send
        }
    }

    /// 取消提示的跟手（小样 updateDragVisuals）：过 8pt 死区后以手指一半的速度左移，靠左淡出
    static func hintOffset(dx: CGFloat) -> CGFloat {
        let d = min(0, dx)
        return d < -8 ? (d + 8) / 2 : 0
    }

    static func hintOpacity(dx: CGFloat) -> Double {
        Double(max(0, min(1, 1 - (-min(0, dx) - 50) / 70)))
    }

    /// 上拉锁定进度 0…1（锁高 72→40、锁扣合上）
    static func lockness(dy: CGFloat) -> CGFloat {
        min(1, max(0, -dy / 105))
    }

    /// 大按钮左拖缩小
    static func bigButtonScale(dx: CGFloat) -> CGFloat {
        max(0.4, 1 + min(0, dx) / 300)
    }
}
