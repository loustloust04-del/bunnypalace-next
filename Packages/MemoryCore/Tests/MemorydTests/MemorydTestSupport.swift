import Foundation
@testable import memoryd

/// 测试里直接用 `respond` 时绑的端口（真实 HTTP 走 `server.start()` 注入实际端口）
enum MemorydTestPort {
    static let value: UInt16 = 8765
    static var host: String { "127.0.0.1:\(value)" }
}

enum MemorydFixture {
    /// `Tests/MemoryCoreTests/Fixtures/memoryd-floor`（全虚构：岚舟 / 星砚 / 云桥城 / 琥珀风铃 / 雾岛）
    static var floor: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MemoryCoreTests/Fixtures/memoryd-floor", isDirectory: true)
    }

    /// 每个测试拷一份到临时目录：跑批会写 `bench-runs/`、建 `.recall-index.sqlite`
    static func copiedFloor() throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("memoryd-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: floor, to: dest)
        return dest
    }

    /// 夹具不是 `memoryd-mount.sh` 拷出来的：统一走 `--allow-unmounted` 那条路
    static func service(_ floor: URL, profileId: String = "memoryd-test") throws -> MemorydService {
        let service = try MemorydService(
            config: .init(floor: floor, profileId: profileId, allowUnmounted: true),
            webRoot: MemorydResources.webRoot
        )
        service.bind(port: MemorydTestPort.value)
        return service
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension HTTPResponse {
    var jsonObject: Any? {
        try? JSONSerialization.jsonObject(with: body)
    }

    var jsonDictionary: [String: Any]? {
        jsonObject as? [String: Any]
    }
}

extension MemorydService {
    func get(_ target: String) async -> HTTPResponse {
        await raw("GET", target)
    }

    func post(_ target: String, json: String, contentType: String = "application/json") async -> HTTPResponse {
        await raw("POST", target, headers: ["content-type": contentType], body: json)
    }

    /// 自定义头：Host / Origin / Content-Type 校验的测试用
    func raw(_ method: String, _ target: String, headers: [String: String] = [:],
             body: String = "", host: String? = MemorydTestPort.host) async -> HTTPResponse {
        var all = headers
        if let host { all["host"] = host }
        all["content-length"] = String(body.utf8.count)
        return await respond(HTTPRequest(method: method, target: target, version: "HTTP/1.1",
                                         headers: all, body: Data(body.utf8)))
    }
}
