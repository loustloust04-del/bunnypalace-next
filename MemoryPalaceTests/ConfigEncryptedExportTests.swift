import XCTest
@testable import 记忆花园

/// research-magpie 2.8：设置导出「包含 API key（需设口令）」。
/// 口令加密（PBKDF2-SHA256 60 万次 → AES-256-GCM）+ 恢复规则照 magpie：
/// 同 id 替换；备份没带 key 的保留本机 key；OAuth token / CC Hub token 一律不打包。
/// 全程注入内存 secret store + 独立 UserDefaults suite，不碰真实 Keychain / standard defaults。
final class ConfigEncryptedExportTests: XCTestCase {

    private final class MemorySecretStore: ConfigSecretStore {
        var items: [String: String]
        init(_ items: [String: String] = [:]) { self.items = items }
        func allAccounts() -> [String] { Array(items.keys) }
        func get(account: String) -> String? { items[account] }
        func set(_ value: String, account: String) { items[account] = value }
    }

    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "xctest-config-crypto-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private let pass = "correct horse battery staple"
    private let oauthJSON = #"{"accessToken":"at","refreshToken":"rt","expiresAt":1900000000}"#

    /// 源机：一张普通卡 cred-a（有 key）、一张 cred-b（没 key）、ChatGPT OAuth 卡、CC bridge 卡。
    private func seedSource() -> (UserDefaults, MemorySecretStore) {
        let d = makeDefaults()
        let creds: [[String: Any]] = [
            ["id": "cred-a", "name": "A", "emoji": "🅰️", "type": "openaiCompatible", "baseURL": "https://a.example", "extraHeaders": [:], "models": [], "createdAt": 0],
            ["id": "cred-b", "name": "B", "emoji": "🅱️", "type": "anthropic", "baseURL": "https://b.example", "extraHeaders": [:], "models": [], "createdAt": 0],
            ["id": "chatgpt-oauth", "name": "GPT", "emoji": "🤖", "type": "chatgptOAuth", "baseURL": "https://c.example", "extraHeaders": [:], "models": [], "createdAt": 0],
            ["id": "ccbridge", "name": "CC", "emoji": "🧩", "type": "ccBridge", "baseURL": "ws://x", "extraHeaders": [:], "models": [], "createdAt": 0],
        ]
        d.set(try! JSONSerialization.data(withJSONObject: creds), forKey: "credentials")
        d.set("小禾", forKey: "userName")
        let store = MemorySecretStore([
            "cred-a": "sk-secret-a",
            "chatgpt-oauth": oauthJSON,
            "ccbridge": "bridge-token",
            "cc-bridge": "hub-token",
            "cc-bridge-hub-token": "hub-token-2",
            "websearch:tavily": "tvly-key",
            "elevenlabs": "el-key",
        ])
        return (d, store)
    }

    // MARK: - 加解密往返

    func testEncryptedExportRoundTripRestoresApiKeysOnly() throws {
        let (src, srcStore) = seedSource()
        let data = try ConfigExporter.exportWithKeys(passphrase: pass, defaults: src, secrets: srcStore)

        XCTAssertTrue(ConfigCrypto.isEncrypted(data))
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["sk-secret-a", "tvly-key", "el-key", "小禾"] {
            XCTAssertFalse(text.contains(secret), "明文泄露：\(secret)")
        }

        // 文件头明文：格式版本 / KDF 参数 / salt / nonce
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(header["format"] as? String, ConfigCrypto.format)
        XCTAssertEqual(header["version"] as? Int, 1)
        XCTAssertEqual(header["kdf"] as? String, "pbkdf2-sha256")
        XCTAssertEqual(header["iterations"] as? Int, 600_000)
        XCTAssertEqual((header["salt"] as? String).flatMap { Data(base64Encoded: $0) }?.count, 16)
        XCTAssertEqual((header["nonce"] as? String).flatMap { Data(base64Encoded: $0) }?.count, 12)

        let dst = makeDefaults()
        let dstStore = MemorySecretStore()
        let result = try ConfigImporter.importAll(data, passphrase: pass, defaults: dst, secrets: dstStore)

        XCTAssertEqual(dst.string(forKey: "userName"), "小禾")
        XCTAssertNotNil(dst.data(forKey: "credentials"))
        XCTAssertEqual(dstStore.items, [
            "cred-a": "sk-secret-a",
            "websearch:tavily": "tvly-key",
            "elevenlabs": "el-key",
        ], "OAuth token / CC hub token 不打包")
        XCTAssertEqual(result.restoredKeys, 3)
    }

    func testCryptoRoundTripRawData() throws {
        let plain = Data("hello 记忆花园".utf8)
        let sealed = try ConfigCrypto.seal(plain, passphrase: pass)
        XCTAssertEqual(try ConfigCrypto.open(sealed, passphrase: pass), plain)
        // 每次随机 salt + nonce
        XCTAssertNotEqual(try ConfigCrypto.seal(plain, passphrase: pass), sealed)
    }

    func testEmptyPassphraseRejected() {
        XCTAssertThrowsError(try ConfigCrypto.seal(Data("x".utf8), passphrase: ""))
    }

    // MARK: - 错口令 / 篡改

    func testWrongPassphraseGivesClearErrorAndTouchesNothing() throws {
        let (src, srcStore) = seedSource()
        let data = try ConfigExporter.exportWithKeys(passphrase: pass, defaults: src, secrets: srcStore)

        let dst = makeDefaults()
        dst.set("原名", forKey: "userName")
        let dstStore = MemorySecretStore(["cred-a": "local"])
        XCTAssertThrowsError(try ConfigImporter.importAll(data, passphrase: "wrong pass", defaults: dst, secrets: dstStore)) { error in
            XCTAssertEqual(error as? ConfigCrypto.CryptoError, .wrongPassphrase)
            XCTAssertTrue((error.localizedDescription).contains("口令"))
        }
        XCTAssertEqual(dst.string(forKey: "userName"), "原名")
        XCTAssertEqual(dstStore.items, ["cred-a": "local"])
    }

    func testEncryptedFileWithoutPassphraseAsksForOne() throws {
        let (src, srcStore) = seedSource()
        let data = try ConfigExporter.exportWithKeys(passphrase: pass, defaults: src, secrets: srcStore)
        XCTAssertThrowsError(try ConfigImporter.importAll(data, defaults: makeDefaults(), secrets: MemorySecretStore())) { error in
            guard case ConfigImporter.ImportError.passphraseRequired = error else {
                return XCTFail("应要求口令，实际：\(error)")
            }
        }
    }

    func testTamperedCiphertextDetected() throws {
        let sealed = try ConfigCrypto.seal(Data("payload".utf8), passphrase: pass)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        var ct = try XCTUnwrap(Data(base64Encoded: obj["data"] as! String))
        ct[0] ^= 0x01
        obj["data"] = ct.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try ConfigCrypto.open(tampered, passphrase: pass)) { error in
            XCTAssertEqual(error as? ConfigCrypto.CryptoError, .wrongPassphrase)
        }
    }

    func testTamperedHeaderDetected() throws {
        let sealed = try ConfigCrypto.seal(Data("payload".utf8), passphrase: pass)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: sealed) as? [String: Any])

        // 改 iterations（仍在合法范围内）→ 密钥不同 + 头部被 AAD 覆盖 → 打不开
        var a = obj; a["iterations"] = 600_001
        XCTAssertThrowsError(try ConfigCrypto.open(try JSONSerialization.data(withJSONObject: a), passphrase: pass))

        // 改 format 版本 → 明确拒绝（新版本文件）
        var b = obj; b["version"] = 99
        XCTAssertThrowsError(try ConfigCrypto.open(try JSONSerialization.data(withJSONObject: b), passphrase: pass)) { error in
            XCTAssertEqual(error as? ConfigCrypto.CryptoError, .unsupportedVersion(99))
        }
    }

    // MARK: - 恢复规则

    func testImportReplacesSameIdAndKeepsLocalKeyWhenBackupHasNone() throws {
        let (src, srcStore) = seedSource()   // cred-b 在源机没 key
        let data = try ConfigExporter.exportWithKeys(passphrase: pass, defaults: src, secrets: srcStore)

        let dstStore = MemorySecretStore([
            "cred-a": "old-a",
            "cred-b": "local-b",
            "chatgpt-oauth": "local-oauth",
        ])
        try ConfigImporter.importAll(data, passphrase: pass, defaults: makeDefaults(), secrets: dstStore)
        XCTAssertEqual(dstStore.items["cred-a"], "sk-secret-a", "同 id 替换")
        XCTAssertEqual(dstStore.items["cred-b"], "local-b", "备份没带 key → 保留本机")
        XCTAssertEqual(dstStore.items["chatgpt-oauth"], "local-oauth", "OAuth 不动")
    }

    func testOAuthShapedValueNeverPackedEvenOnApiCard() throws {
        let (src, srcStore) = seedSource()
        srcStore.items["cred-a"] = oauthJSON   // 兜底：值长得像 OAuth token 也不打包
        let data = try ConfigExporter.exportWithKeys(passphrase: pass, defaults: src, secrets: srcStore)
        let plain = try ConfigCrypto.open(data, passphrase: pass)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("refreshToken"))
    }

    // MARK: - 旧格式兼容

    func testPlainExportUnchangedAndImportsWithoutPassphrase() throws {
        let (src, srcStore) = seedSource()
        let data = ConfigExporter.exportAll(defaults: src)
        XCTAssertFalse(ConfigCrypto.isEncrypted(data))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["schema_version"] as? Int, ConfigSchema.currentVersion)
        XCTAssertNil(root["secrets"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sk-secret-a"))
        _ = srcStore

        let dst = makeDefaults()
        let dstStore = MemorySecretStore(["cred-a": "local"])
        let result = try ConfigImporter.importAll(data, defaults: dst, secrets: dstStore)
        XCTAssertEqual(dst.string(forKey: "userName"), "小禾")
        XCTAssertEqual(dstStore.items, ["cred-a": "local"], "明文导入不动 Keychain")
        XCTAssertEqual(result.restoredKeys, 0)
    }

    func testLegacyHandWrittenFileStillImports() throws {
        let legacy = """
        {"schema_version": 1, "app_version": "MemoryPalace 1.0 (1)", "general": {"userName": "旧文件"},
         "_excluded": {"keychain": "API key / OAuth token / CC Hub Token"}}
        """
        let dst = makeDefaults()
        try ConfigImporter.importAll(Data(legacy.utf8), defaults: dst, secrets: MemorySecretStore())
        XCTAssertEqual(dst.string(forKey: "userName"), "旧文件")
    }

    /// 长文折叠已删：旧导出文件里残留的 appearance.expandAllMessages 静默忽略，不报错、不写回
    func testRemovedExpandAllMessagesKeyIgnored() throws {
        let legacy = """
        {"schema_version": 1, "general": {"userName": "旧文件"}, "appearance": {"expandAllMessages": true, "showAvatar": false}}
        """
        let dst = makeDefaults()
        try ConfigImporter.importAll(Data(legacy.utf8), defaults: dst, secrets: MemorySecretStore())
        XCTAssertNil(dst.object(forKey: "expandAllMessages"))
        XCTAssertEqual(dst.object(forKey: "showAvatar") as? Bool, false)
    }

    func testPlaintextFileCarryingSecretsIsIgnored() throws {
        // 手搓一个明文文件夹带 secrets：只有口令加密的文件才可能写 Keychain
        let forged = #"{"schema_version": 1, "secrets": {"api_keys": {"cred-a": "evil"}}}"#
        let store = MemorySecretStore(["cred-a": "local"])
        try ConfigImporter.importAll(Data(forged.utf8), defaults: makeDefaults(), secrets: store)
        XCTAssertEqual(store.items["cred-a"], "local")
    }

    // MARK: - 口令强度提示

    /// 语音服务（plan-voice-providers V3）：服务列表随设置导出；`voice.<id>` key 只进加密包
    func testVoiceServicesAndKeysRoundTrip() throws {
        let (src, srcStore) = seedSource()
        let services = [VoiceService(id: "svc-1", name: "ElevenLabs", kind: .elevenLabs),
                        VoiceService(id: "svc-2", name: "硅基", kind: .openAICompatible, baseURL: "https://api.siliconflow.cn/v1",
                                     openAICompatible: OpenAICompatibleOptions(models: ["tts-x"]))]
        src.set(try JSONEncoder().encode(services), forKey: VoiceServiceStore.listKey)
        srcStore.items["voice.svc-1"] = "el-voice-key"
        srcStore.items["voice.svc-2"] = "sk-voice-key"

        let plain = ConfigExporter.exportAll(defaults: src)
        let plainText = String(decoding: plain, as: UTF8.self)
        XCTAssertTrue(plainText.contains("svc-2"), "明文导出带服务列表")
        XCTAssertFalse(plainText.contains("sk-voice-key"), "明文导出不带 key")

        let data = try ConfigExporter.exportWithKeys(passphrase: pass, defaults: src, secrets: srcStore)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("el-voice-key"))
        let dst = makeDefaults()
        let dstStore = MemorySecretStore()
        try ConfigImporter.importAll(data, passphrase: pass, defaults: dst, secrets: dstStore)

        let back = try JSONDecoder().decode([VoiceService].self, from: XCTUnwrap(dst.data(forKey: VoiceServiceStore.listKey)))
        XCTAssertEqual(back, services)
        XCTAssertEqual(dstStore.items["voice.svc-1"], "el-voice-key")
        XCTAssertEqual(dstStore.items["voice.svc-2"], "sk-voice-key")
    }

    /// 导入不整段覆盖语音服务：本机独有的（楼层可能引用）保留，同 id 用备份的，新的追加（sol P2-8）
    func testImportMergesVoiceServicesById() throws {
        let src = makeDefaults()
        let backup = [VoiceService(id: "shared", name: "备份里的名字", kind: .elevenLabs),
                      VoiceService(id: "only-backup", name: "MiniMax", kind: .miniMax)]
        src.set(try JSONEncoder().encode(backup), forKey: VoiceServiceStore.listKey)
        let data = ConfigExporter.exportAll(defaults: src)

        let dst = makeDefaults()
        let local = [VoiceService(id: "only-local", name: "楼层在用", kind: .openAICompatible),
                     VoiceService(id: "shared", name: "本机旧名字", kind: .elevenLabs)]
        dst.set(try JSONEncoder().encode(local), forKey: VoiceServiceStore.listKey)
        try ConfigImporter.importAll(data, defaults: dst, secrets: MemorySecretStore())

        let merged = try JSONDecoder().decode([VoiceService].self, from: XCTUnwrap(dst.data(forKey: VoiceServiceStore.listKey)))
        XCTAssertEqual(merged.map(\.id), ["only-local", "shared", "only-backup"])
        XCTAssertEqual(merged.first { $0.id == "shared" }?.name, "备份里的名字")
        XCTAssertEqual(merged.first { $0.id == "only-local" }?.kind, .openAICompatible, "本机独有的保留")
    }

    func testPassphraseStrength() {
        XCTAssertEqual(ConfigPassphraseStrength.evaluate(""), .tooShort)
        XCTAssertEqual(ConfigPassphraseStrength.evaluate("abc123"), .tooShort)
        XCTAssertEqual(ConfigPassphraseStrength.evaluate("abcdefgh"), .weak)
        XCTAssertEqual(ConfigPassphraseStrength.evaluate("abcd1234EF"), .fair)
        XCTAssertEqual(ConfigPassphraseStrength.evaluate(pass), .strong)
        XCTAssertFalse(ConfigPassphraseStrength.tooShort.isAcceptable)
        XCTAssertTrue(ConfigPassphraseStrength.weak.isAcceptable)
    }
}
