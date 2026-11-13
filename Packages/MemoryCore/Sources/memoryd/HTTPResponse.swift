import Foundation

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static let jsonType = "application/json; charset=utf-8"

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": jsonType], body: data)
    }

    static func jsonRaw(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": jsonType], body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message, "status": status], status: status)
    }

    func encoded() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for key in all.keys.sorted() { head += "\(key): \(all[key] ?? "")\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
