import Foundation

/// 按字节缓冲，只在完整行上做 UTF-8 解码；行尾认 \n、\r\n、单独 \r（\r 在分片末尾时等下一片再判）
struct SSELineDecoder {
    enum Field: Equatable { case event(String), data(String), comment, other }

    struct LineTooLong: Error {}

    static let maxLineBytes = 32 * 1024 * 1024

    private var pending = Data()
    /// pending 里已扫过、确定没有行尾的字节数（长行分很多片来时不重复扫）
    private var scanned = 0
    private let maxLineBytes: Int

    init(maxLineBytes: Int = SSELineDecoder.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func feed(_ data: Data) throws -> [Field] {
        pending.append(data)
        var fields: [Field] = []
        var start = pending.startIndex
        var i = start + scanned
        while i < pending.endIndex {
            let byte = pending[i]
            if byte == 0x0A {
                try checkLength(i - start)
                fields.append(Self.parse(line: Self.decode(pending[start..<i])))
                i += 1
                start = i
            } else if byte == 0x0D {
                let next = i + 1
                // \r 落在末尾：可能是 \r\n 的前半，等下一片
                if next == pending.endIndex { break }
                try checkLength(i - start)
                fields.append(Self.parse(line: Self.decode(pending[start..<i])))
                i = pending[next] == 0x0A ? next + 1 : next
                start = i
            } else {
                i += 1
            }
        }
        // 没收完的行：i 停在末尾待判的 \r 上时它不算行内容
        try checkLength(i - start)
        if start > pending.startIndex { pending = Data(pending[start...]) }
        scanned = i - start
        return fields
    }

    /// 行长只算内容字节、不算行尾；完整行和没收完的行同一把尺，怎么切片结果都一样
    private mutating func checkLength(_ count: Int) throws {
        guard count > maxLineBytes else { return }
        reset()
        throw LineTooLong()
    }

    /// 流结束：把没换行的最后一行也吐出来
    mutating func finish() -> [Field] {
        defer { reset() }
        guard !pending.isEmpty else { return [] }
        var rest = pending[...]
        if rest.last == 0x0D { rest = rest.dropLast() }
        return [Self.parse(line: Self.decode(rest))]
    }

    mutating func reset() {
        pending = Data()
        scanned = 0
    }

    /// 规范：`field:value`，冒号后**最多去一个**空格；以 `:` 开头 = 注释；没冒号 = 整行是字段名、值为空
    static func parse(line: String) -> Field {
        if line.hasPrefix(":") { return .comment }
        let name: Substring
        var value: Substring = ""
        if let colon = line.firstIndex(of: ":") {
            name = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            name = line[...]
        }
        switch name {
        case "event": return .event(String(value))
        case "data": return .data(String(value))
        default: return .other
        }
    }

    private static func decode(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
