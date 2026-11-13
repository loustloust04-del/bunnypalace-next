import Foundation

public enum CatalogJSON {}

extension CatalogJSON {
    public struct Failure: Error {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// 只用于 schema 声明的数组 / 对象，不把正文字符串当 JSON。
    public struct Container<Value: Decodable>: Decodable {
        public let value: Value

        public init(from decoder: Decoder) throws {
            do {
                value = try Value(from: decoder)
            } catch {
                guard let text = try? decoder.singleValueContainer().decode(String.self) else { throw error }
                do {
                    value = try decodeValue(Value.self, text)
                } catch let failure as Failure {
                    let path = decoder.codingPath.map(\.stringValue).joined(separator: ".")
                    let hint = path == "items" ? "items 必须直接是数组，不要把数组写成字符串。" : "\(path) 必须直接是数组或对象，不要把 JSON 写成字符串。"
                    throw Failure(message: hint + "内层 " + failure.message)
                }
            }
        }
    }

    public static func decodeValue<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        let data = Data(text.utf8)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            if let failure = error as? Failure { throw failure }
            if case DecodingError.dataCorrupted = error {
                let repaired = repairQuotes(text)
                if repaired != text, let value = try? JSONDecoder().decode(type, from: Data(repaired.utf8)) {
                    return value
                }
            }
            throw failure(error, text: text)
        }
    }

    private static func failure(_ error: Error, text: String) -> Failure {
        let context: DecodingError.Context
        let detail: String
        switch error {
        case DecodingError.dataCorrupted(let c):
            context = c
            detail = "JSON 坏了：正文里的引号请用「」，不要用半角双引号；检查逗号和闭括号。"
        case DecodingError.keyNotFound(let key, let c):
            return Failure(message: "缺少字段 \((c.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))")
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return Failure(message: "字段 \(c.codingPath.map(\.stringValue).joined(separator: ".")) 类型不对：\(c.debugDescription)")
        default:
            return Failure(message: error.localizedDescription)
        }
        let parser = (context.underlyingError ?? error) as NSError
        let debug = parser.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription
        if let index = parser.userInfo["NSJSONSerializationErrorIndex"] as? Int {
            let prefix = text.utf8.prefix(max(0, index))
            let line = prefix.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
            let column = prefix.count - (prefix.lastIndex(of: 10).map { prefix.distance(from: prefix.startIndex, to: $0) + 1 } ?? 0) + 1
            return Failure(message: "第 \(line) 行、第 \(column) 列附近 \(detail)（解析器：\(debug)）")
        }
        return Failure(message: detail + "（解析器：\(debug)）")
    }

    /// 沿用 pi-utils JsonLexer 的引号后视规则；只修值，不补结构、不接受 partial。
    public static func repairQuotes(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var stack: [UInt8] = []
        var inString = false
        var valueString = false
        var escaped = false
        var previous: UInt8 = 0
        func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
        for i in bytes.indices {
            let byte = bytes[i]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    var next = i + 1
                    while next < bytes.count, whitespace(bytes[next]) { next += 1 }
                    // 引号 / 容器开头可能是漏了分隔符，不能吞成正文。
                    if valueString, next < bytes.count, ![34, 44, 58, 91, 93, 123, 125].contains(bytes[next]) {
                        out.append(92)
                    } else {
                        inString = false
                        previous = byte
                    }
                }
            } else if byte == 34 {
                inString = true
                valueString = previous == 58 || stack.last == 91
            } else if !whitespace(byte) {
                if byte == 123 || byte == 91 { stack.append(byte) }
                if byte == 125 || byte == 93 { _ = stack.popLast() }
                previous = byte
            }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
