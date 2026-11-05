#if os(macOS)
import Foundation
#if DEBUG || PERF_BENCH
import Darwin
import CoreFoundation
import MachO
#endif

enum BenchIsolation {
    #if DEBUG || PERF_BENCH
    static let bundleIdentifier = "com.susu.MemoryPalace.perfbench"
    static let profileID = "perf-bench-profile"
    static let requested = Bundle.main.bundleIdentifier == bundleIdentifier
        || getenv("MP_PERF_RUN") != nil
        || getenv("MP_PERF_SEED") != nil
    static private(set) var configuration: Configuration?
    static var active: Bool { configuration != nil }
    static var root: URL? { configuration?.root }
    private static var preparedProfileID: String?

    struct Configuration {
        let root: URL
        let home: URL
        let temporary: URL
        let role: String
        let switches: [String: Bool]
        private let rootComponents: [String]

        init(environment: [String: String], bundleID: String?) throws {
            guard bundleID == BenchIsolation.bundleIdentifier else { throw Violation.identity }
            let run = environment["MP_PERF_RUN"] == "1"
            let seed = !(environment["MP_PERF_SEED"] ?? "").isEmpty
            guard run != seed, run || environment["MP_PERF_RUN"] == nil else { throw Violation.role }
            guard environment["MP_PERF_WINDOW_APPROVED"] == "1" else { throw Violation.window }
            guard let path = environment["MP_PERF_ROOT"], path.hasPrefix("/") else { throw Violation.root }
            let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let allowed = try Self.canonicalPath(URL(fileURLWithPath: "/tmp/mp-macperf-sol", isDirectory: true))
            let canonical = try Self.canonicalPath(candidate)
            guard canonical.deletingLastPathComponent() == allowed,
                  canonical.lastPathComponent.hasPrefix("bench-"),
                  canonical.lastPathComponent.count > "bench-".count else { throw Violation.root }
            root = canonical
            rootComponents = canonical.pathComponents
            home = canonical.appendingPathComponent("home", isDirectory: true)
            temporary = canonical.appendingPathComponent("tmp", isDirectory: true)
            for (key, expected) in [("HOME", home), ("CFFIXED_USER_HOME", home), ("TMPDIR", temporary)] {
                guard let raw = environment[key], raw.hasPrefix("/"),
                      try Self.canonicalPath(URL(fileURLWithPath: raw, isDirectory: true)) == expected else {
                    throw Violation.environment(key)
                }
            }
            guard Self.contains(home, in: root), Self.contains(temporary, in: root) else { throw Violation.root }
            role = run ? "run" : "seed"
            var effective: [String: Bool] = [:]
            for (name, key) in Self.switchKeys {
                if let value = environment[name] {
                    guard value == "0" || value == "1" else { throw Violation.switchValue(name) }
                    effective[key] = value == "1"
                } else { effective[key] = true }
            }
            switches = effective
        }

        static let switchKeys = [
            "MP_PERF_H1": "mp.stanch.H1", "MP_PERF_S1": "mp.stanch.S1", "MP_PERF_P1": "mp.stanch.P1",
            "MP_PERF_K1_DIRTY": "mp.stanch.K1-dirty", "MP_PERF_R_TAB": "mp.stanch.R-tab",
            "MP_PERF_K0_MIN": "mp.stanch.K0-min"
        ]

        fileprivate static func canonicalPath(_ url: URL) throws -> URL {
            guard url.isFileURL else { throw Violation.path }
            var ancestor = url
            var missing: [String] = []
            while true {
                let (resolved, error) = ancestor.withUnsafeFileSystemRepresentation { path -> (URL?, Int32) in
                    guard let path else { return (nil, EINVAL) }
                    return withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(PATH_MAX)) { buffer in
                        guard realpath(path, buffer.baseAddress) != nil else { return (nil, errno) }
                        return (URL(fileURLWithPath: String(cString: buffer.baseAddress!)), 0)
                    }
                }
                if var resolved {
                    for component in missing.reversed() { resolved.appendPathComponent(component) }
                    return resolved
                }
                guard error == ENOENT || error == ENOTDIR else { throw Violation.path }
                var info = stat()
                // 悬空/循环软链不能退回父目录后当成普通缺失段。
                guard lstat(ancestor.path, &info) != 0, errno == ENOENT || errno == ENOTDIR,
                      ancestor.path != "/" else { throw Violation.path }
                let component = ancestor.lastPathComponent
                guard component != ".", component != ".." else { throw Violation.path }
                missing.append(component)
                ancestor.deleteLastPathComponent()
            }
        }

        static func contains(_ url: URL, in root: URL) -> Bool {
            guard let canonical = try? canonicalPath(url) else { return false }
            return canonical.pathComponents.starts(with: root.pathComponents)
        }

        func check(_ url: URL) throws -> URL {
            let canonical = try Self.canonicalPath(url)
            guard canonical.pathComponents.starts(with: rootComponents) else { throw Violation.path }
            return canonical
        }

        func probeKernelWriteDenial(at path: String?) throws -> KernelWriteProbe {
            guard let path, path.hasPrefix("/") else { throw Violation.kernelWriteProbe }
            let candidate = try Self.canonicalPath(URL(fileURLWithPath: path))
            guard candidate.path == path,
                  candidate.deletingLastPathComponent().pathComponents == root.deletingLastPathComponent().pathComponents,
                  candidate.lastPathComponent.hasPrefix("marker-"),
                  candidate.lastPathComponent.count > "marker-".count else { throw Violation.kernelWriteProbe }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & S_IWUSR != 0 else { throw Violation.kernelWriteProbe }
            // 只请求写句柄，不创建、截断或修改根外marker；意外放行也立即关闭并拒绝出证。
            let descriptor = Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            let error = errno
            guard descriptor < 0 else {
                close(descriptor)
                throw Violation.kernelWriteProbe
            }
            guard error == EPERM || error == EACCES else { throw Violation.kernelWriteProbe }
            return KernelWriteProbe(pid: getpid(), path: path, errno: error, operation: "file-write-data")
        }

        func writeAtomically(_ data: Data, to url: URL) throws {
            let destination = try check(url)
            var temporary = Array((destination.deletingLastPathComponent().path + "/.mp-atomic-XXXXXX").utf8CString)
            let descriptor = mkstemp(&temporary)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer {
                close(descriptor)
                unlink(temporary)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: count == 0 ? EIO : errno) ?? .EIO)
                    }
                    offset += count
                }
            }
            let error = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return EINVAL }
                return rename(temporary, path) == 0 ? 0 : errno
            }
            guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        }
    }

    struct KernelWriteProbe: Encodable {
        let pid: Int32
        let path: String
        let errno: Int32
        let operation: String
    }

    enum Violation: Error, CustomStringConvertible {
        case identity, role, window, root, path, kernelWriteProbe
        case environment(String), switchValue(String)

        var description: String {
            switch self {
            case .identity: return "只允许独立 perfbench bundle"
            case .role: return "必须且只能指定一个 RUN/SEED 角色"
            case .window: return "等粟粟说现在测；尚未给本轮窗口授权"
            case .root: return "独立根必须位于 /tmp/mp-macperf-sol/bench-* 且不可逃逸"
            case .path: return "数据路径越出独立根"
            case .kernelWriteProbe: return "内核根外写拒绝探针无效或未被拒绝"
            case .environment(let key): return "家目录/临时目录改道无效：\(key)"
            case .switchValue(let key): return "对照开关只接受0/1：\(key)"
            }
        }
    }

    static func installIfRequested() {
        guard requested else { return }
        do {
            let environment = ProcessInfo.processInfo.environment
            guard environment["XCTestConfigurationFilePath"] == nil else { throw Violation.role }
            let config = try Configuration(environment: environment, bundleID: Bundle.main.bundleIdentifier)
            let fm = FileManager.default
            for url in [fm.homeDirectoryForCurrentUser, URL.homeDirectory,
                        URL(fileURLWithPath: NSHomeDirectory()), URL(fileURLWithPath: ("~" as NSString).expandingTildeInPath)] {
                guard try Configuration.canonicalPath(url).pathComponents == config.home.pathComponents else { throw Violation.environment("Foundation.home") }
            }
            for kind in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory, .documentDirectory] {
                for url in fm.urls(for: kind, in: .userDomainMask) { _ = try config.check(url) }
            }
            configuration = config
            for (key, value) in config.switches { UserDefaults.standard.set(value, forKey: key) }
            NSLog("[perfbench] isolated pid=%d role=%@ bundle=%@", getpid(), config.role, bundleIdentifier)
        } catch { fail(String(describing: error)) }
    }

    static func checked(_ url: URL) -> URL {
        guard requested else { return url }
        guard let configuration else { fail("隔离安装前访问数据路径") }
        do { return try configuration.check(url) }
        catch { fail(String(describing: error)) }
    }

    static func notePreparedProfile(_ id: String) {
        guard active else { return }
        guard id == profileID else { fail("当前楼层不是测试楼层") }
        preparedProfileID = id
    }

    @MainActor private final class StartupObservation {
        var callbackOrders: [Int] = []
        var observerOrders: [Int] = []
        var description = ""
    }

    private struct StartupReport: Encodable {
        let `protocol`: String
        let bundleID: String
        let pid: Int32
        let root, home, applicationSupport, caches, documents, temporary: String
        let role, profileID, binaryUUID, codeUUID: String
        let switches: [String: Bool]
        let observerOrders, callbackOrders: [Int]
        let observerDescription: String
        let kernelWriteProbe: KernelWriteProbe
    }

    @MainActor static func recordAfterLaunch(codeUUID: String?) {
        guard let config = configuration, config.role == "seed",
              ProcessInfo.processInfo.environment["MP_PERF_SEED"] == "isolation" else { return }
        let state = StartupObservation()
        let low = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.min) { observer, _ in
            MainActor.assumeIsolated { state.callbackOrders.append(CFRunLoopObserverGetOrder(observer)) }
        }!
        let high = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { observer, _ in
            MainActor.assumeIsolated {
                state.callbackOrders.append(CFRunLoopObserverGetOrder(observer))
                writeStartupReport(config, codeUUID: codeUUID, observation: state)
            }
        }!
        state.observerOrders = [CFRunLoopObserverGetOrder(low), CFRunLoopObserverGetOrder(high)]
        CFRunLoopAddObserver(CFRunLoopGetMain(), low, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), high, .commonModes)
        guard let description = CFCopyDescription(CFRunLoopGetMain()) else { fail("主runloop描述不可用") }
        state.description = String((description as String).prefix(65_536))
    }

    @MainActor private static func writeStartupReport(_ config: Configuration, codeUUID: String?, observation: StartupObservation) {
        guard preparedProfileID == profileID, let binaryUUID = mainBinaryUUID(), let codeUUID else {
            fail("启动楼层或代码镜像身份未就绪")
        }
        var switches: [String: Bool] = [:]
        for (key, expected) in config.switches {
            guard let actual = UserDefaults.standard.object(forKey: key) as? Bool, actual == expected else {
                fail("对照开关未生效：\(key)")
            }
            switches[key] = actual
        }
        do {
            let probe = try config.probeKernelWriteDenial(at: ProcessInfo.processInfo.environment["MP_PERF_WRITE_DENY_PROBE_PATH"])
            let report = StartupReport(protocol: "macIsolationV1", bundleID: Bundle.main.bundleIdentifier ?? "", pid: getpid(),
                root: config.root.path, home: try config.check(AppPaths.home).path,
                applicationSupport: try config.check(AppPaths.applicationSupport).path,
                caches: try config.check(AppPaths.caches).path, documents: try config.check(AppPaths.documents).path,
                temporary: try config.check(AppPaths.temporaryDirectory).path,
                role: config.role, profileID: profileID, binaryUUID: binaryUUID, codeUUID: codeUUID, switches: switches,
                observerOrders: observation.observerOrders, callbackOrders: observation.callbackOrders,
                observerDescription: observation.description, kernelWriteProbe: probe)
            let directory = try config.check(config.root.appendingPathComponent("perf", isDirectory: true))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = try config.check(directory.appendingPathComponent("isolation-configuration.json"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try config.writeAtomically(encoder.encode(report), to: file)
        } catch { fail("启动隔离证据写入失败：\(error)") }
    }

    private static func mainBinaryUUID() -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("[perfbench] 隔离失败：\(reason)\n".utf8))
        exit(78)
    }
    #else
    static let requested = false
    static let active = false
    static var root: URL? { nil }
    static func checked(_ url: URL) -> URL { url }
    #endif
}
#endif
