import Foundation

/// 顶层 JSON 数组按元素切片，不解码（#050 E2）。
///
/// 导出的 conversations.json 动辄几百 MB（粟粟的 ChatGPT 包 671 MB），整份交给 JSONDecoder 会先在内存里
/// 建一整棵树，手机撑不住；一条坏了整份失败。这里只扫字节、记每个元素的范围，调用方逐条解码：
/// 内存只跟最大的一条走，坏一条只丢那一条。
///
/// 也认 `{"conversations": [ … ]}` 这种包一层的（`wrapperKeys`）。
enum JSONArraySlicer {
    struct Result {
        /// 每个元素在 data 里的范围（data 自己的下标，可直接 `data[range]`）
        var elements: [Range<Int>] = []
        /// 不是数组 / 文件被截断：说明文字。elements 是出错前已切好的
        var error: String?
    }

    static func slice(_ data: Data, wrapperKeys: [String] = ["conversations"]) -> Result {
        data.withUnsafeBytes { raw -> Result in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return Result(error: "文件是空的")
            }
            var scanner = Scanner(p: base, n: raw.count)
            var result = Result()
            var wrapped = false
            scanner.skipSpace()
            guard scanner.i < scanner.n else { return Result(error: "文件是空的") }
            if scanner.byte == UInt8(ascii: "{") {
                wrapped = true
                guard scanner.enterWrapper(keys: wrapperKeys.map { Array($0.utf8) }) else {
                    return Result(error: "不是对话列表")
                }
            } else if scanner.byte != UInt8(ascii: "[") {
                return Result(error: "不是对话列表")
            }
            scanner.i += 1  // 跳过 [
            let offset = data.startIndex
            while true {
                scanner.skipSpace()
                guard scanner.i < scanner.n else {
                    result.error = "文件在第 \(result.elements.count + 1) 段处断了（可能没下载完整）"
                    return result
                }
                if scanner.byte == UInt8(ascii: "]") { return closing(&scanner, result, wrapped) }
                let start = scanner.i
                guard scanner.skipValue() else {
                    result.error = "文件在第 \(result.elements.count + 1) 段处断了（可能没下载完整）"
                    return result
                }
                result.elements.append((offset + start)..<(offset + scanner.i))
                scanner.skipSpace()
                guard scanner.i < scanner.n else {
                    result.error = "文件结尾不完整（可能没下载完整）"
                    return result
                }
                if scanner.byte == UInt8(ascii: ",") { scanner.i += 1; continue }
                if scanner.byte == UInt8(ascii: "]") { return closing(&scanner, result, wrapped) }
                result.error = "第 \(result.elements.count) 段后面格式不对"
                return result
            }
        }
    }

    /// i 停在数组的 `]`：包了一层的还要看外面的对象有没有收尾（sol #13）
    private static func closing(_ scanner: inout Scanner, _ result: Result, _ wrapped: Bool) -> Result {
        guard wrapped else { return result }
        var out = result
        scanner.i += 1
        if !scanner.finishObject() { out.error = "文件结尾不完整（可能没下载完整）" }
        return out
    }

    private struct Scanner {
        let p: UnsafePointer<UInt8>
        let n: Int
        var i = 0

        var byte: UInt8 { p[i] }

        mutating func skipSpace() {
            while i < n, p[i] == 0x20 || p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x09 { i += 1 }
        }

        /// i 停在开头的 `"`；成功时 i 停在结尾 `"` 之后
        mutating func skipString() -> Bool {
            i += 1
            while i < n {
                switch p[i] {
                case UInt8(ascii: "\\"): i += 2
                case UInt8(ascii: "\""): i += 1; return true
                default: i += 1
                }
            }
            return false
        }

        /// 跳过一个完整的值；i 停在值之后
        mutating func skipValue() -> Bool {
            guard i < n else { return false }
            switch p[i] {
            case UInt8(ascii: "\""):
                return skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while i < n {
                    switch p[i] {
                    case UInt8(ascii: "\""):
                        guard skipString() else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default:
                        break
                    }
                    i += 1
                }
                return false
            default:
                // 数字 / true / false / null：到分隔符为止
                let start = i
                while i < n {
                    let b = p[i]
                    if b == UInt8(ascii: ",") || b == UInt8(ascii: "]") || b == UInt8(ascii: "}")
                        || b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { break }
                    i += 1
                }
                return i > start
            }
        }

        /// 在对象里、某个值刚结束：跳过剩下的键值，直到这个对象的 `}`
        mutating func finishObject() -> Bool {
            while true {
                skipSpace()
                guard i < n else { return false }
                if p[i] == UInt8(ascii: "}") { i += 1; return true }
                guard p[i] == UInt8(ascii: ",") else { return false }
                i += 1
                skipSpace()
                guard i < n, p[i] == UInt8(ascii: "\""), skipString() else { return false }
                skipSpace()
                guard i < n, p[i] == UInt8(ascii: ":") else { return false }
                i += 1
                skipSpace()
                guard skipValue() else { return false }
            }
        }

        /// i 停在顶层 `{`：找第一层里名字在 keys 里、值是数组的键；成功时 i 停在那个 `[`
        mutating func enterWrapper(keys: [[UInt8]]) -> Bool {
            i += 1
            while true {
                skipSpace()
                guard i < n, p[i] == UInt8(ascii: "\"") else { return false }
                let keyStart = i + 1
                guard skipString() else { return false }
                let key = Array(UnsafeBufferPointer(start: p + keyStart, count: i - 1 - keyStart))
                skipSpace()
                guard i < n, p[i] == UInt8(ascii: ":") else { return false }
                i += 1
                skipSpace()
                guard i < n else { return false }
                if keys.contains(key), p[i] == UInt8(ascii: "[") { return true }
                guard skipValue() else { return false }
                skipSpace()
                guard i < n, p[i] == UInt8(ascii: ",") else { return false }
                i += 1
            }
        }
    }
}

/// 一份按元素切好的 JSON 数组文件：内存映射，逐条解码
struct JSONArrayFile {
    let data: Data
    let elements: [Range<Int>]
    /// 不是数组 / 被截断的说明（elements 仍是能切出来的那部分）
    let error: String?

    var count: Int { elements.count }

    init(url: URL) throws {
        data = try ExportJSON.data(at: url)
        let sliced = JSONArraySlicer.slice(data)
        elements = sliced.elements
        error = sliced.error
    }

    func decode<T: Decodable>(_ type: T.Type, at index: Int, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: data[elements[index]])
    }
}
