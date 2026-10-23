import Foundation
import CryptoKit

// MARK: - OAuth 2.0 PKCE
//
// Proof Key for Code Exchange：防中间人截 code 后冒认换 token。
// verifier 是随机串（48 字节 b64url），challenge = sha256(verifier) b64url。
// 浏览器跳 auth 时发 challenge，回调拿到 code 后用 verifier 换 token。

enum ChatGPTOAuthPKCE {
    /// 生成 48 字节随机 PKCE verifier（b64url 编码后约 64 字符）
    static func newCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 兜底：用 UUID 拼接（不应该走到这条，SecRandomCopyBytes 几乎不失败）
            let s = UUID().uuidString + UUID().uuidString + UUID().uuidString
            return b64url(Data(s.utf8))
        }
        return b64url(Data(bytes))
    }

    /// challenge = base64url(sha256(verifier))
    static func codeChallenge(verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return b64url(Data(hash))
    }

    /// 生成 OAuth state（防 CSRF）
    static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return b64url(Data(bytes))
    }

    /// base64url（标准 b64 去 padding 替换 +/ 为 -_）
    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
