import Foundation

struct HTTPRequest: Equatable {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    var body: Data
}

enum HTTPParseError: Error, Equatable, CustomStringConvertible {
    case malformedStartLine
    case badHeader(String)
    case unsupportedVersion(String)
    case unsupportedTransferEncoding
    case badContentLength
    case conflictingHeader(String)
    case headerTooLarge
    case bodyTooLarge

    var description: String {
        switch self {
        case .malformedStartLine: return "请求行写坏了"
        case .badHeader(let name): return "请求头「\(name)」写坏了"
        case .unsupportedVersion(let v): return "不支持的 HTTP 版本：\(v)"
        case .unsupportedTransferEncoding: return "不支持 chunked 请求体"
        case .badContentLength: return "Content-Length 不是数字"
        case .conflictingHeader(let name): return "请求头「\(name)」重复且值不一致"
        case .headerTooLarge: return "请求头太长"
        case .bodyTooLarge: return "请求体太大"
        }
    }
}

/// 最小的 HTTP/1.1 请求解析：起始行 + 头 + 定长体。一次只解一条（响应后关连接）。
struct HTTPRequestParser {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) throws -> HTTPRequest? {
        buffer.append(data)
        guard let split = Self.headerSplit(buffer) else {
            if buffer.count > Self.maxHeaderBytes { throw HTTPParseError.headerTooLarge }
            return nil
        }
        let headBytes = buffer[buffer.startIndex..<split.headEnd]
        guard headBytes.count <= Self.maxHeaderBytes else { throw HTTPParseError.headerTooLarge }
        let head = String(decoding: headBytes, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines = head.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let start = lines.first else { throw HTTPParseError.malformedStartLine }

        let parts = start.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"), parts[2].hasPrefix("HTTP/1.") else {
            throw HTTPParseError.malformedStartLine
        }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { throw HTTPParseError.unsupportedVersion(parts[2]) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.badHeader(line) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw HTTPParseError.badHeader(line) }
            // 重复的头：值相同按一份算，值不同直接拒（Content-Length 冲突会让两侧对边界的理解不一致）
            if let existing = headers[name], existing != value { throw HTTPParseError.conflictingHeader(name) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { throw HTTPParseError.unsupportedTransferEncoding }
        let length: Int
        if let raw = headers["content-length"] {
            // 只收十进制数字（`+22` / `1_0` 这类 `Int(_:)` 会放行、代理不一定认）
            guard !raw.isEmpty, raw.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
                  let n = Int(raw), n >= 0 else { throw HTTPParseError.badContentLength }
            length = n
        } else {
            length = 0
        }
        guard length <= Self.maxBodyBytes else { throw HTTPParseError.bodyTooLarge }

        let bodyStart = buffer.startIndex + split.bodyOffset
        let available = buffer.endIndex - bodyStart
        guard available >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeAll(keepingCapacity: false)
        return HTTPRequest(method: parts[0].uppercased(), target: parts[1], version: parts[2], headers: headers, body: body)
    }

    /// 头结束的位置：第一个空行（`\r\n\r\n` 或 `\n\n`）
    private static func headerSplit(_ data: Data) -> (headEnd: Data.Index, bodyOffset: Int)? {
        let crlf = Data("\r\n\r\n".utf8)
        if let range = data.range(of: crlf) {
            return (range.lowerBound, range.upperBound - data.startIndex)
        }
        let lf = Data("\n\n".utf8)
        if let range = data.range(of: lf) {
            return (range.lowerBound, range.upperBound - data.startIndex)
        }
        return nil
    }
}
