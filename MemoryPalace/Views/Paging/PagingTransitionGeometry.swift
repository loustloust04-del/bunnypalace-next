import Foundation

struct PagingTransitionGeometry {
    struct Presentation {
        var x: CGFloat
        var dimOpacity: CGFloat = 0
        var hidden = false
    }

    static func presentation(page: Int, position: CGFloat, width: CGFloat, pageCount: Int, enabled: Bool) -> Presentation {
        let q = min(max(position, 0), CGFloat(max(pageCount - 1, 0)))
        var result = Presentation(x: (CGFloat(page) - q) * width)
        guard enabled, q < CGFloat(pageCount - 1) else { return result }
        let left = Int(floor(q))
        let progress = q - CGFloat(left)
        result.hidden = page != left && page != left + 1
        if page == left {
            result.x = 0
            result.dimOpacity = 0.46 * progress
        } else if page == left + 1 {
            result.x = (1 - progress) * width
        }
        return result
    }

    /// 叠牌姿态（plan-paging-decouple §1.2 A-deck）：三页的真实位置都是 x=0、叠在一起，谁在最上由 rank 定；
    /// 只有这次在动的那张（主角）有 layer 平移。整数 q（停靠）：当前页最上、平移全 0；
    /// 非整数 q：主角 = floor(q)+1，平移 W(1−p)；它下面是 floor(q)（静止页，暗罩 0.46p）。
    /// 过整数 q 那一帧交换主角和 z，换下来的那张此刻要么在屏外（+W）要么被盖住，画面连续（反向越过 q / 0↔2 连续 q 同理）。
    struct DeckPose: Equatable {
        var tx: CGFloat = 0
        var dimOpacity: CGFloat = 0
        /// 2 = 最上，1 = 其下，0 = 垫底
        var rank = 0
    }

    static func deck(page: Int, position: CGFloat, width: CGFloat, pageCount: Int) -> DeckPose {
        let last = CGFloat(max(pageCount - 1, 0))
        let q = min(max(position, 0), last)
        let base = Int(floor(q))
        let progress = q - CGFloat(base)
        var pose = DeckPose()
        guard progress > 0.0001, base + 1 < pageCount else {
            let top = Int(q.rounded())
            pose.rank = page == top ? 2 : (page == top - 1 ? 1 : 0)
            return pose
        }
        if page == base + 1 {
            pose.rank = 2
            pose.tx = (1 - progress) * width
        } else if page == base {
            pose.rank = 1
            pose.dimOpacity = 0.46 * progress
        }
        return pose
    }

    /// 叠牌下这次在动的那张（阴影跟它）：停靠时没有
    static func deckActor(position: CGFloat, pageCount: Int) -> Int? {
        let last = CGFloat(max(pageCount - 1, 0))
        let q = min(max(position, 0), last)
        let base = Int(floor(q))
        guard q - CGFloat(base) > 0.0001, base + 1 < pageCount else { return nil }
        return base + 1
    }

    static func shadowStrength(position: CGFloat, pageCount: Int, enabled: Bool) -> CGFloat {
        guard enabled, position > 0, position < CGFloat(pageCount - 1) else { return 0 }
        let wave = sin(.pi * (position - floor(position)))
        return wave * wave
    }
}
