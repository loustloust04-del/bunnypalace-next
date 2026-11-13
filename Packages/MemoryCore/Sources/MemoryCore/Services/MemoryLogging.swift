public protocol MemoryLog {
    func log(_ line: String)
}

public enum MemoryLogging {
    nonisolated(unsafe) public static var shared: any MemoryLog = SilentLog()

    private struct SilentLog: MemoryLog {
        func log(_ line: String) {}
    }
}
