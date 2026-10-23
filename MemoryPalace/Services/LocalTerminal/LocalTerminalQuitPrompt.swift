#if os(macOS)
import Foundation

/// 退出 / 关 tab 前的确认（plan-mp-local-terminal §8，R-I8）：**判定与文案都是纯函数**，NSAlert / confirmationDialog 只负责把它摆出来。
/// 口径 = 挂在这条终端上的所有非 shell 进程（她 09-15「接受」噪音，R-I8 I3 闭合档）：挂起的、后台的、vim / npm 一并拦——
/// 杀的时候是整条终端一起挂断，问的口径就得跟杀的口径一样
enum LocalTerminalQuitPrompt {
    /// 一个 tab 投影出来的判定输入（不带 session 对象，纯函数可测）
    struct Item: Equatable {
        /// 前台认出来的那家（徽章上那个）
        let agent: CodingAgent?
        /// 挂在这条终端上、除 shell 外的进程名：挂起的 / 后台的 / vim / npm 都算（R-I8 I3 闭合档）
        let job: String?
        let directory: String
        /// 带命令起的 tab，进程还没起来（拿到像样尺寸之前）——「你刚要它跑」，这时 `agent` 必然还是 nil（R-I8 I1）
        let startingWithCommand: Bool

        var isRunning: Bool { agent != nil || job != nil || startingWithCommand }
        /// 在跑的是什么：认出来的那家优先，其次进程名，都没有（刚起还没跑起来）就叫「命令」
        var name: String { agent?.displayName ?? job ?? "命令" }
        /// 弹窗里列的那一行：用目录而不是 `title`——后者是 agent 实时改写的 OSC 标题（R-I8 I5）
        var label: String {
            let dir = (directory as NSString).lastPathComponent
            return dir.isEmpty ? name : name + " · " + dir
        }
    }

    struct Text: Equatable {
        let title: String
        let body: String
    }

    /// 谁在要求退出（R-I8 B1）：注销 / 关机绝不能挡，自动化不弹窗直接拒，只有她本人的动作才问
    enum QuitSource: Equatable {
        /// 真 ⌘Q / 菜单 / app 内 `NSApp.terminate` / Dock 的「退出」
        case userGesture
        /// osascript 之类的脚本
        case automation
        /// 注销 / 关机 / 重启
        case system
    }

    /// 最多列几条
    static let listLimit = 3

    static func blocking(_ items: [Item]) -> [Item] { items.filter(\.isRunning) }

    /// ⌘Q 的文案；nil = 不用问
    static func quit(_ items: [Item]) -> Text? {
        let running = blocking(items)
        guard !running.isEmpty else { return nil }
        let title = running.count == 1 ? "有 1 个终端在跑 \(running[0].name)" : "还有 \(running.count) 个终端在跑东西"
        return Text(title: title, body: "退出后会被挂断：\n" + list(running))
    }

    /// 关 tab 的文案；nil = 不用问
    static func closeTab(_ item: Item) -> Text? {
        guard item.isRunning else { return nil }
        return Text(title: "这个终端在跑 \(item.name)", body: "关掉会挂断它：\(item.label)")
    }

    /// AE 的 quit 带原因 = 注销 / 关机 / 重启；发信方是 Dock 或压根不是 AE = 她本人的动作；其余 AE = 脚本
    static func source(isAppleEventQuit: Bool, hasQuitReason: Bool, senderName: String?) -> QuitSource {
        guard isAppleEventQuit else { return .userGesture }
        if hasQuitReason { return .system }
        return senderName == "Dock" ? .userGesture : .automation
    }

    private static func list(_ items: [Item]) -> String {
        let shown = items.prefix(listLimit).map(\.label).joined(separator: "\n")
        guard items.count > listLimit else { return shown }
        return shown + "\n…等 \(items.count) 个"
    }
}
#endif
