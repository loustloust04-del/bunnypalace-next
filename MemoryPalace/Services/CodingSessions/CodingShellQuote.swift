#if os(macOS)
import Foundation

/// shell 引号（只依赖 Foundation）：远程同步的探测脚本要用 POSIX quote，W-N N6 的 `mp-code` 不能因此链上 AppKit（原来长在带 AppKit 的续跑文件里）
enum CodingShellQuote {
    /// 无条件单引号转义（本机续跑脚本用）
    static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// POSIX quote（Wake `sh_quote`）：安全字符集免引号，其余同 single。远程 ssh 命令与同步探测脚本用（逐字对齐 Wake）
    static func posix(_ s: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@")
        if !s.isEmpty, s.allSatisfy({ safe.contains($0) }) { return s }
        return single(s)
    }
}
#endif
