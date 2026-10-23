import Foundation
import Security

#if os(macOS)
import CryptoKit
import ObjectiveC
#endif

/// #035：mac 单测宿主就是产品 app 本体（`TEST_HOST`），不隔离就是在粟粟的真库 / 真偏好 / 真钥匙串上跑完整启动链。
/// 家目录由 scheme 测试环境变量 `CFFIXED_USER_HOME` 在进程创建时就改道到本工位 DerivedData 下（docs/plan-test-host-isolation.md）；
/// 这里在 `AppEntry.main` 第一行只核对、清空本工位临时家、换偏好 suite、洗子进程环境，并打开适配层的闸。
/// 任何一项核不上 → exit 78，绝不回落到真环境。iOS 不做（UI 测试本就在模拟器沙盒里）。
enum TestHostIsolation {
    enum Gate: String, CaseIterable {
        case notifications, hub, mcp, ccHook, windowPrefs
    }

    static let failureExitCode: Int32 = 78
    static private(set) var active = false
    /// 临时家目录路径的短哈希：偏好 suite / 钥匙串 service 后缀用
    static private(set) var runTag = ""
    static private(set) var home: URL?
    static private(set) var defaultsSuiteName = ""
    /// main 时 XCTestCase 类是否已可见（现有 `NSClassFromString("XCTestCase")` 闸靠它）
    static private(set) var xcTestVisibleAtMain = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var blocked: [Gate: Int] = [:]

    /// 测试宿主下返回 true（调用方直接 return，不碰系统 / 网络）并计数
    static func blocks(_ gate: Gate) -> Bool {
        guard active else { return false }
        lock.lock(); blocked[gate, default: 0] += 1; lock.unlock()
        return true
    }

    static func blockedCount(_ gate: Gate) -> Int {
        lock.lock(); defer { lock.unlock() }
        return blocked[gate] ?? 0
    }

    // MARK: 钥匙串

    static var keychainSuffix: String { ".xctest.\(runTag)" }

    /// 幂等加后缀：已带后缀不再加
    static func keychainService(_ service: String) -> String {
        guard active, !service.hasSuffix(keychainSuffix) else { return service }
        return service + keychainSuffix
    }

    /// 所有 SecItem 查询 / 属性过这里：service 加本工位后缀，同步强制关
    static func keychainQuery(_ query: [String: Any]) -> [String: Any] {
        guard active else { return query }
        var mapped = query
        if let service = query[kSecAttrService as String] as? String {
            mapped[kSecAttrService as String] = keychainService(service)
        }
        // 写入 true / 查询 Any / 缺省一律钉成不同步：测试宿主只碰本机条目
        mapped[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        return mapped
    }

    // MARK: 入口

    static func installIfTestHost() {
        #if os(macOS)
        let env = ProcessInfo.processInfo.environment
        let hasXCTest = env["XCTestConfigurationFilePath"] != nil
        let hasFlag = env["MP_TEST_HOST"] == "1"
        guard hasXCTest || hasFlag else { return }
        guard hasXCTest, hasFlag else {
            fail("标记不全（XCTestConfigurationFilePath=\(hasXCTest) MP_TEST_HOST=\(hasFlag)）")
        }
        guard let raw = env["CFFIXED_USER_HOME"], !raw.isEmpty, !raw.contains("$(") else {
            fail("CFFIXED_USER_HOME 缺失或没展开：\(env["CFFIXED_USER_HOME"] ?? "nil")")
        }
        let tempHome = trustedHome(raw)
        holdHomeLock(tempHome)

        let outside = probedPaths().filter { !contains(canonical($0.url), tempHome) }
        guard outside.isEmpty else {
            fail("改道没生效：" + outside.map { "\($0.name)=\($0.url.path)" }.joined(separator: " "))
        }

        resetHome(tempHome)
        washEnvironment(home: tempHome)

        runTag = String(SHA256.hash(data: Data(tempHome.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
        defaultsSuiteName = "com.susu.MemoryPalace.xctest.\(runTag)"
        swapStandardDefaults(suiteName: defaultsSuiteName)

        disableKeychainInteraction()
        installPrivateKeychain(home: tempHome)
        xcTestVisibleAtMain = NSClassFromString("XCTestCase") != nil
        home = tempHome
        active = true
        NSLog("[test-host] home=%@ suite=%@ keychain=%@ xctestVisible=%d",
              tempHome.path, defaultsSuiteName, keychainSuffix, xcTestVisibleAtMain ? 1 : 0)
        #endif
    }

    #if os(macOS)
    struct ProbedPath {
        let name: String
        let url: URL
    }

    /// 启动链会用到的全部家目录派生路径（只算不建：都用不 mkdir 的 getter）
    static func probedPaths() -> [ProbedPath] {
        let fm = FileManager.default
        func first(_ dir: FileManager.SearchPathDirectory) -> URL {
            fm.urls(for: dir, in: .userDomainMask).first ?? URL(fileURLWithPath: "/")
        }
        func search(_ dir: FileManager.SearchPathDirectory) -> URL {
            URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(dir, .userDomainMask, true).first ?? "/")
        }
        return [
            ProbedPath(name: "NSHomeDirectory", url: URL(fileURLWithPath: NSHomeDirectory())),
            ProbedPath(name: "homeDirectoryForCurrentUser", url: fm.homeDirectoryForCurrentUser),
            ProbedPath(name: "URL.homeDirectory", url: URL.homeDirectory),
            ProbedPath(name: "tilde", url: URL(fileURLWithPath: ("~" as NSString).expandingTildeInPath)),
            ProbedPath(name: "URL.applicationSupportDirectory", url: URL.applicationSupportDirectory),
            ProbedPath(name: "URL.documentsDirectory", url: URL.documentsDirectory),
            ProbedPath(name: "URL.cachesDirectory", url: URL.cachesDirectory),
            ProbedPath(name: "urls.applicationSupport", url: first(.applicationSupportDirectory)),
            ProbedPath(name: "urls.documents", url: first(.documentDirectory)),
            ProbedPath(name: "urls.caches", url: first(.cachesDirectory)),
            ProbedPath(name: "urls.library", url: first(.libraryDirectory)),
            ProbedPath(name: "urls.desktop", url: first(.desktopDirectory)),
            ProbedPath(name: "search.applicationSupport", url: search(.applicationSupportDirectory)),
            ProbedPath(name: "search.documents", url: search(.documentDirectory)),
            ProbedPath(name: "unifiedStorePath", url: ProfileManager.unifiedStorePath),
            ProbedPath(name: "BlobStore", url: BlobStore.path(forKey: "savedProfiles")),
            ProbedPath(name: "iCloudDocuments", url: fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/iCloud~com~susu~MemoryPalace/Documents", isDirectory: true)),
        ]
    }

    /// 解符号链接（/var → /private/var）+ 标准化；不存在的尾段原样保留
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// 按路径分量比较，不用字符串前缀（/a/xctest-home2 不算在 /a/xctest-home 里）
    static func contains(_ path: URL, _ root: URL) -> Bool {
        let p = canonical(path).pathComponents, r = canonical(root).pathComponents
        return p.count >= r.count && Array(p.prefix(r.count)) == r
    }

    /// 要删的根必须正好是「本次构建」的 TARGET_TEMP_DIR/xctest-home：从宿主 app 自己的位置
    /// `<DerivedData>/<项目>/Build/Products/<配置>/记忆花园.app` 推出期望路径，逐字相等才放行；
    /// 路径链上有符号链接、相对路径、不在真家目录的 Xcode DerivedData 下，一律退出
    private static func trustedHome(_ raw: String) -> URL {
        guard raw.hasPrefix("/") else { fail("CFFIXED_USER_HOME 不是绝对路径：\(raw)") }
        let given = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        guard canonical(given).path == given.path else { fail("CFFIXED_USER_HOME 路径链上有符号链接：\(raw)") }
        guard let realHome = realUserHome() else { fail("取不到真家目录，无法核对 CFFIXED_USER_HOME") }
        let derivedData = realHome.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        guard contains(given, derivedData) else { fail("CFFIXED_USER_HOME 不在 Xcode DerivedData 下：\(given.path)") }
        guard let expected = expectedHome(bundle: canonical(Bundle.main.bundleURL)), given.path == expected.path else {
            fail("CFFIXED_USER_HOME 不是本次构建的 xctest-home：\(given.path)")
        }
        return given
    }

    static func expectedHome(bundle: URL) -> URL? {
        let parts = bundle.pathComponents
        guard parts.count >= 4, let products = parts.lastIndex(of: "Products"), products >= 1,
              parts[products - 1] == "Build", products + 2 == parts.count - 1 else { return nil }
        let config = parts[products + 1]
        let build = NSString.path(withComponents: Array(parts[...(products - 1)]))
        return URL(fileURLWithPath: build, isDirectory: true)
            .appendingPathComponent("Intermediates.noindex/MemoryPalace.build/\(config)/MemoryPalace.build/xctest-home", isDirectory: true)
    }

    /// 同一个临时家同时只给一个宿主：锁文件在家目录旁边（家目录会被整个删），进程活着锁就在
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1

    private static func holdHomeLock(_ home: URL) {
        let path = home.deletingLastPathComponent().appendingPathComponent("xctest-home.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { fail("临时家锁文件打不开：\(path) errno=\(errno)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { fail("本工位已有测试宿主在跑（\(path) 被占）") }
        lockDescriptor = fd
    }

    /// 真家目录：从用户数据库取，不受 CFFIXED_USER_HOME / HOME 影响
    private static func realUserHome() -> URL? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return canonical(URL(fileURLWithPath: String(cString: dir), isDirectory: true))
    }

    static let homeSkeleton = ["Library/Application Support", "Library/Caches", "Library/Preferences", "Documents", "Desktop"]

    /// 上一次的残留必须删干净（只有「本来就不存在」算正常），删不掉就退出，不带旧库 / 旧标记启动
    private static func resetHome(_ home: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: home.path) {
            do { try fm.removeItem(at: home) } catch { fail("清不掉上次的临时家：\(error.localizedDescription)") }
        }
        guard !fm.fileExists(atPath: home.path) else { fail("临时家删完还在：\(home.path)") }
        for sub in homeSkeleton {
            do {
                try fm.createDirectory(at: home.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
            } catch {
                fail("临时家目录建不起来：\(error.localizedDescription)")
            }
        }
        let top = Set((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
        guard top == ["Library", "Documents", "Desktop"] else { fail("临时家重建后不是空骨架：\(top.sorted())") }
    }

    /// 子进程（终端 / CLI / MCP stdio）继承的环境：家目录类指向临时家，外部工具根清掉
    static let redirectedHomeVariables = ["HOME", "ZDOTDIR"]
    static let redirectedXDGVariables = ["XDG_CONFIG_HOME": ".config", "XDG_DATA_HOME": ".local/share",
                                         "XDG_CACHE_HOME": ".cache", "XDG_STATE_HOME": ".local/state"]
    static let clearedVariables = ["CODEX_HOME", "HERMES_HOME", "OPENCODE_DB", "OPENCLAW_STATE_DIR", "QODER_CONFIG_DIR",
                                   "CLAUDE_CONFIG_DIR", "MP_CODE_HOME", "MP_CODE_STATE", "MP_CC_WORKDIR"]

    private static func washEnvironment(home: URL) {
        for name in redirectedHomeVariables { setenv(name, home.path, 1) }
        for (name, sub) in redirectedXDGVariables { setenv(name, home.appendingPathComponent(sub).path, 1) }
        for name in clearedVariables { unsetenv(name) }
    }

    /// Security 按 `$HOME` 找用户钥匙串：HOME 改道后进程里没有默认钥匙串（-25307），读写全挂。
    /// 在临时家里建本工位专属的 login 钥匙串，它自动成为本进程唯一的用户钥匙串，她的 login 钥匙串不在搜索列表里
    private static func disableKeychainInteraction() {
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { fail("关不掉钥匙串交互") }
        var allowed = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess, !allowed.boolValue else {
            fail("钥匙串交互读回仍是开着")
        }
    }

    /// 用户域搜索列表：建之前必须是空的或全在临时家里，建之后必须只有临时家里这一个
    static func userKeychainPaths() -> [String] {
        var list: CFArray?
        guard SecKeychainCopyDomainSearchList(.user, &list) == errSecSuccess else { return [] }
        return ((list as? [SecKeychain]) ?? []).compactMap(path(of:))
    }

    private static func path(of keychain: SecKeychain) -> String? {
        var length: UInt32 = 1024
        var buffer = [CChar](repeating: 0, count: Int(length))
        guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return nil }
        return String(cString: buffer)
    }

    private static func installPrivateKeychain(home: URL) {
        let before = userKeychainPaths().filter { !contains(URL(fileURLWithPath: $0), home) }
        guard before.isEmpty else { fail("HOME 改道后用户钥匙串列表里还有临时家外的：\(before)") }
        let path = home.appendingPathComponent("Library/Keychains/login.keychain-db")
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            fail("临时钥匙串目录建不起来：\(error.localizedDescription)")
        }
        let password = "xctest"
        var keychain: SecKeychain?
        let status = SecKeychainCreate(path.path, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess else { fail("临时钥匙串建不起来：\(status)") }
        guard let current = defaultKeychainPath(), canonical(URL(fileURLWithPath: current)) == canonical(path) else {
            fail("默认钥匙串不是刚建的那个：\(defaultKeychainPath() ?? "nil")")
        }
        let after = userKeychainPaths()
        guard after.count == 1, canonical(URL(fileURLWithPath: after[0])) == canonical(path) else {
            fail("用户钥匙串列表不是只有临时家这一个：\(after)")
        }
    }

    static func defaultKeychainPath() -> String? {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return nil }
        return path(of: keychain)
    }

    /// `+[NSUserDefaults standardUserDefaults]` 换成本工位专属 suite（`@AppStorage` 默认 store 跟着走）。
    /// 直接 CFPreferences + bundle id 的代码不受影响，那些在适配层单独闸
    private static func swapStandardDefaults(suiteName: String) {
        guard let suite = UserDefaults(suiteName: suiteName) else { fail("偏好 suite 建不出来：\(suiteName)") }
        suite.removePersistentDomain(forName: suiteName)
        let selector = #selector(getter: UserDefaults.standard)
        guard let method = class_getClassMethod(UserDefaults.self, selector) else { fail("找不到 standardUserDefaults") }
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in suite }
        method_setImplementation(method, imp_implementationWithBlock(block))
        guard UserDefaults.standard === suite else { fail("standardUserDefaults 没换成 suite") }
    }

    private static func fail(_ reason: String) -> Never {
        let line = "[test-host] 隔离失败，退出 \(failureExitCode)：\(reason)\n"
        FileHandle.standardError.write(Data(line.utf8))
        NSLog("%@", line)
        exit(failureExitCode)
    }
    #endif
}
