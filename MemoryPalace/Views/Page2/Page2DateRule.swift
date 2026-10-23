import Foundation

/// page2 桌面日期（`Page2SceneState.date`）只在跨天时写（plan-paging-decouple §3.4 B-7）：
/// 读者（单词 / 话题盒小组件、日历图标、文件库、组件宿主）全按「天」用；@Observable 同值写也会通知所有读者
enum Page2DateRule {
    static func shouldWrite(old: Date, now: Date, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(old, inSameDayAs: now)
    }
}
