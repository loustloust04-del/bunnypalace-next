import Foundation

/// 手机里的小电脑开交互 shell 用的那几样（plan-terminal-t2 §2.3）。纯函数，放共用 sources 好让 Mac 单测锚住；
/// 真正起进程在 `Sandbox/ish/ISHTerminalSession.swift`（只 iOS）。
enum LocalShellLaunch {
    /// 会话令牌的命名空间（ASCII "MPPT"）。令牌写进 guest 进程组的 `fs_context`，fork 时整份继承，
    /// 用来认「这个进程属于哪个终端」。iSH 只有装了路径钩子才会读 fs_context —— 将来谁装钩子要避开这个前缀。
    static let tokenNamespace: UInt64 = 0x4D50_5054_0000_0000

    static func token(sequence: UInt64) -> UInt64 {
        tokenNamespace | (sequence & 0xFFFF_FFFF)
    }

    static func isToken(_ value: UInt64) -> Bool {
        value & 0xFFFF_FFFF_0000_0000 == tokenNamespace
    }

    /// 先进起点（挂不上 / 进不去就 /root），再换成登录 shell（读 /etc/profile 拿 PS1）
    static func arguments(startDirectory: String) -> [String] {
        ["/bin/sh", "-c", "cd \(singleQuoted(startDirectory)) 2>/dev/null || cd /root; exec /bin/sh -l"]
    }

    /// run_command 那份白名单（不继承 App 环境、不带任何密钥），换成交互终端该有的：
    /// 有真终端了 → TERM=xterm-256color、不再 NO_COLOR
    static func environment(base: [String: String]) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = nil
        return env
    }

    static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 新终端开头那几行灰字（D3）。宿主直接写进终端视图，不经 guest
    static func banner(note: String?) -> Data {
        var lines = ["手机里的小电脑 · 断网也能用。切到后台会暂停，回来接着跑；App 被关掉后要重开，文件都还在。"]
        if let note { lines.append(note) }
        return Data(lines.map { "\u{1b}[2m\($0)\u{1b}[0m\r\n" }.joined().utf8)
    }

    /// 宿主写给人看的一行（灰字），比如「shell 已退出」
    static func notice(_ text: String) -> Data {
        Data("\r\n\u{1b}[2m\(text)\u{1b}[0m\r\n".utf8)
    }
}

/// 往小电脑的 tty 里灌输入（plan-terminal-t2 §2.3）：同步循环、吃不完就等一下重试同一块，保持先进先出。
/// 计数按重试次数而不是墙钟——App 挂起时线程一起停，回来不会误判超时。
enum TerminalInputPump {
    /// 排队中的输入上限，超了拒收
    static let maxQueuedBytes = 1 << 20
    /// 连续这么多次一个字节都没吃进去就放弃（每次等 10ms ≈ 3 秒运行时间）
    static let maxStalls = 300

    enum Outcome: Equatable {
        case done
        /// 太久没吃进去，丢掉剩下的字节数
        case gaveUp(remaining: Int)
        case cancelled
        /// write 回了「再试也没用」的错误
        case failed(code: Int)
    }

    /// - write：返回吃进去的字节数（0 = 满了），负数 = 错误码；`again` 这个错误码按「满了」处理
    static func drain(
        _ data: Data,
        again: Int,
        write: (UnsafeRawBufferPointer) -> Int,
        isCancelled: () -> Bool,
        pause: () -> Void
    ) -> Outcome {
        var offset = 0
        var stalls = 0
        while offset < data.count {
            if isCancelled() { return .cancelled }
            let n = data.withUnsafeBytes { raw in
                write(UnsafeRawBufferPointer(rebasing: raw[offset...]))
            }
            if n > 0 {
                offset += n
                stalls = 0
                continue
            }
            if n < 0 && n != again { return .failed(code: n) }
            stalls += 1
            if stalls >= maxStalls { return .gaveUp(remaining: data.count - offset) }
            pause()
        }
        return .done
    }
}
