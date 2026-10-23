import CryptoKit
import Foundation
import Security

/// #068 中继自签证书 pin：叶子证书 SubjectPublicKeyInfo 的 sha256（base64），
/// 和 cc-bridge `relay.json` 的 pinSpkiSha256 / 配对码 p3 同一个定义。
enum CCRelayPin {
    /// 从证书 DER 里原样截出 SPKI 再算 sha256。解析不了返回 nil（当不匹配处理）
    static func spkiSHA256(certDER: Data) -> String? {
        guard let spki = subjectPublicKeyInfo([UInt8](certDER)) else { return nil }
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// 服务器证书挑战：是中继那台主机且配了 pin → 只认 pin（自签也接受，对不上就拒、不回退）；
    /// 其余地址（LAN / Tailscale / 正规证书的中继）照常走系统校验
    static func evaluate(_ challenge: URLAuthenticationChallenge, defaults: UserDefaults = .standard) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let pin = CCBridgeEndpoints.relayPin(host: space.host, port: space.port, defaults: defaults)
        let leaf = pin == nil ? nil : (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first.map { SecCertificateCopyData($0) as Data }
        switch decide(pin: pin, leafDER: leaf) {
        case .useCredential: return (.useCredential, URLCredential(trust: trust))
        case .performDefaultHandling: return (.performDefaultHandling, nil)
        default: return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// 没 pin → 系统校验；有 pin → 叶子 SPKI 对上才放行（自签也行），对不上 / 拿不到证书一律拒，不回退
    static func decide(pin: String?, leafDER: Data?) -> URLSession.AuthChallengeDisposition {
        guard let pin else { return .performDefaultHandling }
        guard let leafDER, spkiSHA256(certDER: leafDER) == pin else { return .cancelAuthenticationChallenge }
        return .useCredential
    }

    /// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version 可选, serialNumber, signature,
    /// issuer, validity, subject, subjectPublicKeyInfo, … }, … }
    private static func subjectPublicKeyInfo(_ b: [UInt8]) -> [UInt8]? {
        guard b.first == 0x30, let cert = tlv(b, at: 0),
              cert.contentStart < b.count, b[cert.contentStart] == 0x30, let tbs = tlv(b, at: cert.contentStart) else { return nil }
        var i = tbs.contentStart
        if i < b.count, b[i] == 0xA0 { guard let v = tlv(b, at: i) else { return nil }; i = v.end }
        for _ in 0..<5 { guard let e = tlv(b, at: i) else { return nil }; i = e.end }
        guard i < b.count, b[i] == 0x30, let spki = tlv(b, at: i), spki.end <= tbs.end else { return nil }
        return Array(b[i..<spki.end])
    }

    /// 一个 DER 元素：内容起点和整体终点（只支持单字节 tag，证书里够用）
    private static func tlv(_ b: [UInt8], at i: Int) -> (contentStart: Int, end: Int)? {
        guard i + 1 < b.count else { return nil }
        var len = Int(b[i + 1])
        var start = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n > 0, n <= 4, start + n <= b.count else { return nil }
            len = b[start..<start + n].reduce(0) { $0 << 8 | Int($1) }
            start += n
        }
        guard start + len <= b.count else { return nil }
        return (start, start + len)
    }
}

/// 竞速探测 session 的代理：不跟重定向（中继候选不许被带去别处），中继配了 pin 时校验证书
final class CCBridgeProbeDelegate: NSObject, URLSessionTaskDelegate {
    /// 秒连尺子：每个探测请求的 URLSessionTaskMetrics（session 委托队列上回调）
    private let onMetrics: ((Int, URLSessionTaskMetrics) -> Void)?

    init(onMetrics: ((Int, URLSessionTaskMetrics) -> Void)? = nil) {
        self.onMetrics = onMetrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        onMetrics?(task.taskIdentifier, metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = CCRelayPin.evaluate(challenge)
        completionHandler(disposition, credential)
    }
}
