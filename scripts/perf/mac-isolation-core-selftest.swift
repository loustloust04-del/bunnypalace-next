import Foundation
import Darwin

@main enum MacIsolationCoreSelfTest {
    static func main() throws {
        let fm = FileManager.default
        let liveEnv = ProcessInfo.processInfo.environment
        guard let home = liveEnv["CFFIXED_USER_HOME"],
              fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path else {
            fatalError("自测须在独立HOME中运行，Foundation家目录改道必须真实生效")
        }
        let base = URL(fileURLWithPath: "/tmp/mp-macperf-sol", isDirectory: true)
        let root = base.appendingPathComponent("bench-core-\(UUID().uuidString)", isDirectory: true)
        let outside = base.appendingPathComponent("outside-core-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        let env = ["MP_PERF_ROOT": root.path, "HOME": root.appendingPathComponent("home").path,
                   "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
                   "TMPDIR": root.appendingPathComponent("tmp").path,
                   "MP_PERF_SEED": "isolation", "MP_PERF_WINDOW_APPROVED": "1"]
        let config = try BenchIsolation.Configuration(environment: env, bundleID: BenchIsolation.bundleIdentifier)
        guard let resolvedRoot = realpath(root.path, nil) else { fatalError("自测根realpath失败") }
        defer { free(resolvedRoot) }
        guard try config.check(root).path == String(cString: resolvedRoot) else {
            fatalError("实际URL必须经POSIX realpath规范，不能由Foundation改回/tmp")
        }
        var rejected = 0
        func mustReject(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("隔离边界错误接受：\(label)") }
            catch is BenchIsolation.Violation { rejected += 1 }
            catch { fatalError("非隔离错误：\(label)") }
        }
        mustReject("缺少内核写拒绝marker") { _ = try config.probeKernelWriteDenial(at: nil) }
        mustReject("根内marker不能冒充根外探针") {
            _ = try config.probeKernelWriteDenial(at: config.root.appendingPathComponent("marker-inside").path)
        }
        let markerLink = config.root.deletingLastPathComponent().appendingPathComponent("marker-core-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: markerLink, withDestinationURL: outside)
        defer { try? fm.removeItem(at: markerLink) }
        mustReject("软链marker不能冒充普通文件") { _ = try config.probeKernelWriteDenial(at: markerLink.path) }
        try fm.removeItem(at: markerLink)
        try fm.createDirectory(at: markerLink, withIntermediateDirectories: false)
        mustReject("目录marker不能冒充普通文件") { _ = try config.probeKernelWriteDenial(at: markerLink.path) }
        mustReject("生产bundle") {
            _ = try BenchIsolation.Configuration(environment: env, bundleID: "com.susu.MemoryPalace")
        }
        mustReject("缺窗口授权") {
            var denied = env; denied.removeValue(forKey: "MP_PERF_WINDOW_APPROVED")
            _ = try BenchIsolation.Configuration(environment: denied, bundleID: BenchIsolation.bundleIdentifier)
        }
        mustReject("冲突进程角色") {
            var denied = env; denied["MP_PERF_RUN"] = "1"
            _ = try BenchIsolation.Configuration(environment: denied, bundleID: BenchIsolation.bundleIdentifier)
        }
        mustReject("HOME越界") {
            var denied = env; denied["HOME"] = outside.path
            _ = try BenchIsolation.Configuration(environment: denied, bundleID: BenchIsolation.bundleIdentifier)
        }
        mustReject("对照值拼错") {
            var denied = env; denied["MP_PERF_K0_MIN"] = "NO"
            _ = try BenchIsolation.Configuration(environment: denied, bundleID: BenchIsolation.bundleIdentifier)
        }
        mustReject("同前缀兄弟根") {
            _ = try config.check(URL(fileURLWithPath: config.root.path + "-other/file"))
        }
        mustReject("相对段逃逸") { _ = try config.check(config.root.appendingPathComponent("../outside/file")) }
        let link = root.appendingPathComponent("home/escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        mustReject("祖先软链逃逸且末端缺失") { _ = try config.check(link.appendingPathComponent("missing/deeper/file")) }
        for path in ["missing/../home/escape/file", "missing/./home/file"] {
            mustReject("缺失后缀点段组合：\(path)") { _ = try config.check(root.appendingPathComponent(path)) }
        }
        let inside = root.appendingPathComponent("home/inside")
        try fm.createSymbolicLink(at: inside, withDestinationURL: root.appendingPathComponent("tmp"))
        let output = try config.check(inside.appendingPathComponent("missing/deeper/file"))
        let expected = config.temporary.appendingPathComponent("missing/deeper/file")
        guard output.path == expected.path else { fatalError("根内软链解析结果错误") }
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("inside-only".utf8).write(to: output)
        guard try String(contentsOf: expected, encoding: .utf8) == "inside-only" else { fatalError("根内软链写入落点错误") }
        try config.writeAtomically(Data("atomic-replacement".utf8), to: output)
        guard try String(contentsOf: expected, encoding: .utf8) == "atomic-replacement" else { fatalError("原子替换没有更新既有内容") }
        let nativeTemporaryRedirected = fm.temporaryDirectory.resolvingSymlinksInPath().path == URL(fileURLWithPath: liveEnv["TMPDIR"]!).resolvingSymlinksInPath().path
        print("MAC_ISOLATION_CORE_SELF_TEST PASS rejected=\(rejected) native_temporary_redirected=\(nativeTemporaryRedirected)；临时入口由AppPaths显式改道，未设置真实窗口授权或启动app")
    }
}
