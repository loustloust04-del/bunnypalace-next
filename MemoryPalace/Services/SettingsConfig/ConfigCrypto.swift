import Foundation
import CryptoKit
import CommonCrypto

// MARK: - 设置导出口令加密（research-magpie 2.8）
//
// 「包含 API key」的设置导出整份用口令封起来。文件仍是 JSON，但只有一个明文信封：
//   { format, version, kdf, iterations, salt, nonce, data }
// 头部明文写全参数，将来升 KDF / 迭代数只要认新 version，不用猜。
// data = AES-256-GCM(ciphertext ‖ tag)，密钥 = PBKDF2-SHA256(口令, salt, iterations)。
// 头部字段整体进 AAD —— 改 iterations/salt/nonce 任一个都解不开（照 magpie backup.go header()）。

enum ConfigCrypto {

    static let format = "memorypalace-settings-encrypted"
    static let version = 1
    static let kdf = "pbkdf2-sha256"
    static let defaultIterations = 600_000

    enum CryptoError: LocalizedError, Equatable {
        case emptyPassphrase
        case notEncrypted
        case unsupportedVersion(Int)
        case malformed
        case wrongPassphrase
        case keyDerivationFailed

        var errorDescription: String? {
            switch self {
            case .emptyPassphrase: return "口令不能为空"
            case .notEncrypted: return "不是加密的设置文件"
            case .unsupportedVersion(let v): return "加密格式 version=\(v) 比当前 app 新，请升级 app 后再导入"
            case .malformed: return "加密文件头损坏，无法识别"
            case .wrongPassphrase: return "口令不对，或文件被改动过"
            case .keyDerivationFailed: return "口令派生密钥失败"
            }
        }
    }

    /// 明文信封。Data 字段经 JSONEncoder 自动 base64。
    private struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var iterations: Int
        var salt: Data
        var nonce: Data
        var data: Data
    }

    /// 只看信封 format 字段，不解密。旧明文导出（schema_version 根）返回 false。
    static func isEncrypted(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["format"] as? String == format
    }

    static func seal(_ plain: Data, passphrase: String, iterations: Int = defaultIterations) throws -> Data {
        guard !passphrase.isEmpty else { throw CryptoError.emptyPassphrase }
        var env = Envelope(format: format, version: version, kdf: kdf, iterations: iterations,
                           salt: randomBytes(16), nonce: randomBytes(12), data: Data())
        let key = try deriveKey(passphrase, salt: env.salt, iterations: env.iterations)
        let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: env.nonce),
                                   authenticating: aad(env))
        env.data = box.ciphertext + box.tag
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(env)
    }

    static func open(_ sealed: Data, passphrase: String) throws -> Data {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: sealed), env.format == format else {
            throw isEncrypted(sealed) ? CryptoError.malformed : CryptoError.notEncrypted
        }
        guard env.version == version, env.kdf == kdf else {
            throw CryptoError.unsupportedVersion(env.version)
        }
        guard (100_000...10_000_000).contains(env.iterations),
              env.salt.count >= 16, env.nonce.count == 12, env.data.count >= 16 else {
            throw CryptoError.malformed
        }
        guard !passphrase.isEmpty else { throw CryptoError.wrongPassphrase }
        let key = try deriveKey(passphrase, salt: env.salt, iterations: env.iterations)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: env.nonce),
                                            ciphertext: env.data.dropLast(16),
                                            tag: env.data.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: aad(env))
        } catch {
            throw CryptoError.wrongPassphrase
        }
    }

    // MARK: - private

    /// 头部参数拼成 AAD：format/version/kdf/iterations/salt(hex)/nonce(hex)
    private static func aad(_ e: Envelope) -> Data {
        Data("\(e.format)/\(e.version)/\(e.kdf)/\(e.iterations)/\(hex(e.salt))/\(hex(e.nonce))".utf8)
    }

    private static func deriveKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let pass = Array(passphrase.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuf in
            pass.withUnsafeBufferPointer { passBuf in
                passBuf.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pass.count) { passPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr, pass.count,
                        saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        &out, out.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed }
        return SymmetricKey(data: out)
    }

    private static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    private static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 口令强度（只做提示，<8 位不让导出）

enum ConfigPassphraseStrength: Equatable {
    case tooShort, weak, fair, strong

    static let minimumLength = 8

    static func evaluate(_ s: String) -> ConfigPassphraseStrength {
        guard s.count >= minimumLength else { return .tooShort }
        var classes = 0
        if s.contains(where: { $0.isLowercase }) { classes += 1 }
        if s.contains(where: { $0.isUppercase }) { classes += 1 }
        if s.contains(where: { $0.isNumber }) { classes += 1 }
        if s.contains(where: { !$0.isLowercase && !$0.isUppercase && !$0.isNumber }) { classes += 1 }
        var score = 0
        if s.count >= 12 { score += 1 }
        if s.count >= 16 { score += 1 }
        if classes >= 2 { score += 1 }
        if classes >= 3 { score += 1 }
        switch score {
        case 0...1: return .weak
        case 2: return .fair
        default: return .strong
        }
    }

    var isAcceptable: Bool { self != .tooShort }

    var label: String {
        switch self {
        case .tooShort: return "太短（至少 \(Self.minimumLength) 位）"
        case .weak: return "弱 · 建议更长，或混用大小写 / 数字 / 符号"
        case .fair: return "中"
        case .strong: return "强"
        }
    }
}
