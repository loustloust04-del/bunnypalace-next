import SwiftUI

// MARK: - 日历页的字和墨（plan-calendar-page §〇）
// 字体 3 族：手写 = 数字 / 页标题 / 英文月名；打字机 = 英文导航和元信息；苹方（.system）= 一切中文。
// 手写体和打字机体都没有中文字形，旁边不放中文（会回退成楷体）。
// 字号 5 档：d 34 · n 22 · b 16 · s 13 · m 11（页签例外 16）。
// 墨 3 种 + 1 种装饰灰：文字最浅到 ink3；graphite 只给装饰线，不给字、不给能点的东西。

enum CalType {
    static let d: CGFloat = 34
    static let n: CGFloat = 22
    static let b: CGFloat = 16
    static let s: CGFloat = 13
    static let m: CGFloat = 11
    static let tab: CGFloat = 16

    static func hand(_ size: CGFloat) -> Font { CalendarInk.hand(size) }
    static func type(_ size: CGFloat) -> Font { .custom("AmericanTypewriter-Light", size: size) }
}

enum CalInk {
    static let ink = Color(red: 0.184, green: 0.184, blue: 0.176)       // #2f2f2d
    static let ink2 = Color(red: 0.361, green: 0.361, blue: 0.349)      // #5c5c59
    static let ink3 = Color(red: 0.435, green: 0.431, blue: 0.416)      // #6f6e6a
    static let graphite = Color(red: 0.725, green: 0.722, blue: 0.698)  // #b9b8b2
    static let paper = Color(red: 0.965, green: 0.965, blue: 0.953)     // #f6f6f3
    /// 当天区三块的手绘波浪框：比按钮的铅笔方框淡
    static let frame = Color(red: 0.663, green: 0.659, blue: 0.635)     // #a9a8a2
}

/// 日历页面样子（设置 → 日历 → 页面样子）。纪念日墙两种样子里都一样。
enum CalendarLook: String, CaseIterable {
    case paper, ios

    static let storageKey = "calendar_look"

    var label: String {
        switch self {
        case .paper: "纸"
        case .ios: "iOS"
        }
    }
}
