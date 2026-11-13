import XCTest
@testable import 记忆花园

/// 11-07 探针（铲屎二期刀 4 真跑时 😷 上非流式长调用 ~33s 报 -1005）：同一台机、同一个端点，
/// 裸 URLSession 发三种请求，分清是「非流式长时间无字节被掐」还是 app 代码问题：
///   ① 非流式 max_tokens 1500（预计 < 30s）② 非流式 max_tokens 4000（预计 > 30s）③ 流式 max_tokens 8192（一直有字节）
/// 每条打耗时、结局（完成 / 错误码）、输出 token。默认跳过：车头用 TEST_RUNNER_MP_CUTPROBE_API_KEY 注入 key（只进内存）。
@MainActor
final class NonStreamCutProbeTests: XCTestCase {
    private static let baseURL = "https://api.anthropic.com/v1"
    private static let model = "claude-haiku-5-5"

    override func setUp() async throws {
        guard let value = getenv("MP_CUTPROBE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_CUTPROBE_API_KEY，不访问真实端点")
        }
        executionTimeAllowance = 900
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = URL(string: Self.baseURL)?.host
        try CatalogLiveAuthProtocol.install()
    }

    override func tearDown() async throws {
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    private func request(maxTokens: Int, stream: Bool) throws -> URLRequest {
        var r = URLRequest(url: URL(string: "\(Self.baseURL)/messages")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue(CatalogLiveAuthProtocol.placeholder, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model, "max_tokens": maxTokens, "stream": stream,
            "system": "你是小说作者。只输出正文。",
            "messages": [["role": "user", "content": "写一部虚构的长篇游记，主角叫星砚，至少三万字，按章节一直写下去，中途不要总结、不要停。"]],
        ])
        return r
    }

    private func probeNonStream(_ maxTokens: Int) async {
        let t0 = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: request(maxTokens: maxTokens, stream: false))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let out = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { $0["usage"] as? [String: Any] }?["output_tokens"] ?? "?"
            print(String(format: "[CUTPROBE] nonstream max=%d: ok status=%d out=%@ t=%.1fs", maxTokens, status, "\(out)", Date().timeIntervalSince(t0)))
        } catch {
            print(String(format: "[CUTPROBE] nonstream max=%d: ERR %@ code=%d t=%.1fs", maxTokens, (error as NSError).domain, (error as NSError).code, Date().timeIntervalSince(t0)))
        }
    }

    private func probeStream(_ maxTokens: Int) async {
        let t0 = Date()
        var bytes = 0
        var sawStop = false
        do {
            let (stream, resp) = try await URLSession.shared.bytes(for: request(maxTokens: maxTokens, stream: true))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            for try await line in stream.lines {
                bytes += line.utf8.count
                if line.contains("\"max_tokens\"") || line.contains("message_stop") { sawStop = true }
            }
            print(String(format: "[CUTPROBE] stream max=%d: ok status=%d bytes=%d stop=%@ t=%.1fs", maxTokens, status, bytes, sawStop ? "y" : "n", Date().timeIntervalSince(t0)))
        } catch {
            print(String(format: "[CUTPROBE] stream max=%d: ERR %@ code=%d bytes=%d t=%.1fs", maxTokens, (error as NSError).domain, (error as NSError).code, bytes, Date().timeIntervalSince(t0)))
        }
    }

    /// 不经 CatalogLiveAuthProtocol 转发，自己的 session 直连，抓 task metrics：协议（h2 / h3）、是否走代理、对端地址族
    private final class Metrics: NSObject, URLSessionTaskDelegate {
        var line = "no-metrics"
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            line = metrics.transactionMetrics.map { m in
                "proto=\(m.networkProtocolName ?? "?") proxy=\(m.isProxyConnection) reused=\(m.isReusedConnection) remoteV6=\((m.remoteAddress ?? "").contains(":")) port=\(m.remotePort ?? -1)"
            }.joined(separator: " | ")
        }
    }

    private func probeNonStreamDirect(_ maxTokens: Int) async {
        guard let key = getenv("MP_CUTPROBE_API_KEY").map({ String(cString: $0) }) else { return }
        var r = try! request(maxTokens: maxTokens, stream: false)
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        let m = Metrics()
        let session = URLSession(configuration: .ephemeral, delegate: m, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let t0 = Date()
        do {
            let (_, resp) = try await session.data(for: r)
            print(String(format: "[CUTPROBE] direct max=%d: ok status=%d t=%.1fs %@", maxTokens, (resp as? HTTPURLResponse)?.statusCode ?? 0,
                         Date().timeIntervalSince(t0), m.line))
        } catch {
            try? await Task.sleep(nanoseconds: 300_000_000)
            print(String(format: "[CUTPROBE] direct max=%d: ERR code=%d t=%.1fs %@", maxTokens, (error as NSError).code,
                         Date().timeIntervalSince(t0), m.line))
        }
    }

    func testProbeNonStreamCut() async {
        if let direct = ProcessInfo.processInfo.environment["MP_CUTPROBE_DIRECT"], !direct.isEmpty {
            for n in direct.split(separator: ",").compactMap({ Int($0) }) { await probeNonStreamDirect(n) }
            return
        }
        let only = ProcessInfo.processInfo.environment["MP_CUTPROBE_ONLY"] ?? ""
        if !only.isEmpty {
            for n in only.split(separator: ",").compactMap({ Int($0) }) { await probeNonStream(n) }
            return
        }
        await probeNonStream(1500)
        await probeNonStream(4000)
        await probeStream(8192)
    }
}
