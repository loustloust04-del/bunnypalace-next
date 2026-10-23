#if os(macOS)
import Foundation

/// stdio MCP 传输（plan-wake-mcp §2.2）：起子进程 `/bin/zsh -c "exec <command>"`，
/// stdin 一行一条 JSON-RPC 写入，stdout 按行读回，stderr 攒尾巴当错误说明。
/// - SIGPIPE：stdin 写端 `F_SETNOSIGPIPE` + Darwin `write(2)`，子进程先死只得 EPIPE，不杀 MP（R-WM #2）
/// - 早退：terminationHandler 先把 stderr 读尽再上报，连不上几秒内给出原因（R-WM #3）
/// - 关闭：关 stdin → server 读到 EOF 自退；2 s 后还活着再 terminate（`npx` 类的孙进程只能靠 EOF）
final class MCPStdioTransport: MCPTransport {
    var onMessage: ((Any) -> Void)?
    var onClose: ((Error?) -> Void)?

    static let maxLineBytes = 16 * 1024 * 1024
    private static let stderrTailBytes = 4096

    private let command: String
    private let extraEnv: [String: String]
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "mp.mcp.stdio.write")
    private var process: Process?
    private var stdinPipe: Pipe?
    private var closed = false
    private var stdoutBuffer: [UInt8] = []
    private var stderrTail: [UInt8] = []

    init(command: String, env: [String: String]) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPError.serverError("本地命令为空") }
        self.command = trimmed
        self.extraEnv = env
    }

    deinit {
        if process != nil { close() }
    }

    /// 子进程 pid（测试核进程确实退出）
    var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    func connect() async throws {
        lock.lock()
        let running = process != nil
        lock.unlock()
        guard !running else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "exec " + command]
        var env = MacShellBackend().environment()
        for (key, value) in extraEnv { env[key] = value }
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStderr(data)
        }
        p.terminationHandler = { [weak self] proc in
            self?.handleTermination(status: proc.terminationStatus, stdout: outPipe, stderr: errPipe)
        }

        lock.lock()
        closed = false
        stdoutBuffer.removeAll()
        stderrTail.removeAll()
        lock.unlock()
        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw MCPError.serverError("启动本地命令失败：\(error.localizedDescription)")
        }
        lock.lock()
        process = p
        stdinPipe = inPipe
        lock.unlock()
    }

    func send(_ message: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MCPError.connectionClosed)
                    return
                }
                self.lock.lock()
                let fd = self.closed ? -1 : (self.stdinPipe?.fileHandleForWriting.fileDescriptor ?? -1)
                self.lock.unlock()
                guard fd >= 0 else {
                    continuation.resume(throwing: MCPError.connectionClosed)
                    return
                }
                let err = Self.writeAll(fd, data)
                if err == 0 {
                    continuation.resume()
                } else if err == EPIPE {
                    continuation.resume(throwing: MCPError.connectionClosed)
                } else {
                    continuation.resume(throwing: MCPError.serverError("写入本地 MCP 失败（errno \(err)）"))
                }
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let p = process
        let input = stdinPipe
        process = nil
        stdinPipe = nil
        lock.unlock()
        guard let p else { return }
        // 在写队列上关 stdin：不会和正在进行的 write 抢同一个 fd
        writeQueue.async {
            try? input?.fileHandleForWriting.close()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if p.isRunning { p.terminate() }
        }
    }

    // MARK: - 读

    private func consumeStdout(_ data: Data) {
        var lines: [[UInt8]] = []
        var overflow = false
        lock.lock()
        stdoutBuffer.append(contentsOf: data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            lines.append(Array(stdoutBuffer[..<newline]))
            stdoutBuffer.removeSubrange(...newline)
        }
        if stdoutBuffer.count > Self.maxLineBytes {
            stdoutBuffer.removeAll()
            overflow = true
        }
        lock.unlock()
        for line in lines { emit(line) }
        if overflow {
            fail(MCPError.serverError("本地 MCP 单行输出超过 16 MB，已断开"))
        }
    }

    private func emit(_ bytes: [UInt8]) {
        var line = bytes
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { return }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line)) else {
            CacheDiagLog.shared.log("🔌 MCP stdio 丢弃非 JSON 行：\(String(decoding: line.prefix(200), as: UTF8.self))")
            return
        }
        Task { @MainActor in
            self.onMessage?(json)
        }
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        stderrTail.append(contentsOf: data)
        if stderrTail.count > Self.stderrTailBytes {
            stderrTail.removeFirst(stderrTail.count - Self.stderrTailBytes)
        }
        lock.unlock()
    }

    // MARK: - 退出

    private func handleTermination(status: Int32, stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        // 退出瞬间最后一段输出可能还在管道里没回调：非阻塞读尽（孙进程握着写端时阻塞读会挂死）
        let restErr = Self.drainNonBlocking(stderr.fileHandleForReading.fileDescriptor)
        if !restErr.isEmpty { appendStderr(restErr) }
        let restOut = Self.drainNonBlocking(stdout.fileHandleForReading.fileDescriptor)
        if !restOut.isEmpty { consumeStdout(restOut) }

        lock.lock()
        let wasClosed = closed
        closed = true
        process = nil
        stdinPipe = nil
        let reason = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        guard !wasClosed else { return }
        let message = reason.isEmpty
            ? "本地 MCP 进程已退出（code \(status)）"
            : "本地 MCP 进程已退出（code \(status)）：\(reason)"
        Task { @MainActor in
            self.onClose?(MCPError.serverError(message))
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let wasClosed = closed
        lock.unlock()
        guard !wasClosed else { return }
        close()
        Task { @MainActor in
            self.onClose?(error)
        }
    }

    // MARK: - 系统调用

    private static func writeAll(_ fd: Int32, _ data: Data) -> Int32 {
        data.withUnsafeBytes { raw -> Int32 in
            guard var pointer = raw.baseAddress else { return 0 }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return 0
        }
    }

    private static func drainNonBlocking(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                result.append(contentsOf: buffer[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return result
    }
}
#endif
