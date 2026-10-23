#if os(macOS)
import Foundation

/// 会话正文里自带的一张图（原始编码字节，不是像素）。只在详情解析路径解码，索引路径仍是 `[image]` 占位
/// （plan-wake-native-n1 §2.5，Wake `ImageAttachment`）
struct CodingImage: Sendable, Equatable {
    var mediaType: String
    var data: Data

    /// 胶囊 / 提示里的格式名：image/png → PNG，image/svg+xml → SVG
    var formatLabel: String {
        let subtype = mediaType.split(separator: "/").last.map(String.init) ?? mediaType
        return (subtype.split(separator: "+").first.map(String.init) ?? subtype).uppercased()
    }

    var fileExtension: String {
        switch mediaType {
        case "image/jpeg": return "jpg"
        case "image/svg+xml": return "svg"
        default: return mediaType.split(separator: "/").last.map(String.init) ?? "img"
        }
    }
}

/// 一次转录解析的解码总预算（Wake `transcript_image_decode_budget`）：TaskLocal 圈定范围，嵌套沿用外层；
/// 范围外（索引路径）一律不解码
final class CodingImageBudget: @unchecked Sendable {
    static let transcriptLimit = 64 * 1024 * 1024
    @TaskLocal static var current: CodingImageBudget?

    private var remaining: Int

    init(limit: Int = CodingImageBudget.transcriptLimit) {
        remaining = limit
    }

    func consume(_ bytes: Int) -> Bool {
        guard bytes <= remaining else { return false }
        remaining -= bytes
        return true
    }

    static func decoding<R>(limit: Int = transcriptLimit, _ body: () throws -> R) rethrows -> R {
        if current != nil { return try body() }
        return try $current.withValue(CodingImageBudget(limit: limit), operation: body)
    }
}

/// 图片块解码（Wake `parse_utils.rs` `decode_image_part` 一族）。会话文件是不可信输入：
/// 只认会话自带的 data URI / base64 / 字节数组，绝不读 path / file:// 指向的本地文件，也不下载 http(s)
enum CodingImageDecoder {
    /// 单张 base64 文本上限（约 12 MiB 原图）
    static let maxBase64 = 16 * 1024 * 1024
    static let maxBytes = 12 * 1024 * 1024

    static func decode(_ object: CodingParse.JSON, depth: Int, budget: CodingImageBudget) -> CodingImage? {
        guard depth <= 5 else { return nil }
        for key in ["source", "inlineData", "inline_data"] {
            if let inner = object[key] as? CodingParse.JSON, let image = decode(inner, depth: depth + 1, budget: budget) {
                return image
            }
        }
        let mediaType = CodingParse.imageMediaType(object)
        for key in ["image_url", "imageUrl", "url", "uri", "fileUri", "file_uri", "path"] {
            guard let source = object[key] else { continue }
            if let value = source as? String {
                if value.hasPrefix("data:"), let image = dataURI(value, budget: budget) { return image }
            } else if let inner = source as? CodingParse.JSON, let image = decode(inner, depth: depth + 1, budget: budget) {
                return image
            }
        }
        guard let data = object["data"] else { return nil }
        if let value = data as? String {
            if value.hasPrefix("data:") { return dataURI(value, budget: budget) }
            if mediaType == "image/svg+xml", value.contains("<svg") {
                return attachment(Data(value.utf8), mediaType: mediaType, budget: budget)
            }
            return base64(value, mediaType: mediaType, budget: budget)
        }
        if let values = data as? [Any], values.count <= maxBytes {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(values.count)
            for value in values {
                guard let number = value as? Int, (0...255).contains(number) else { return nil }
                bytes.append(UInt8(number))
            }
            return attachment(Data(bytes), mediaType: mediaType, budget: budget)
        }
        if let inner = data as? CodingParse.JSON { return decode(inner, depth: depth + 1, budget: budget) }
        return nil
    }

    /// `data:image/png;base64,...`：只收 image MIME + base64
    static func dataURI(_ uri: String, budget: CodingImageBudget) -> CodingImage? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let fields = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma].split(separator: ";", omittingEmptySubsequences: false)
        guard let mediaType = fields.first, mediaType.hasPrefix("image/"), fields.dropFirst().contains("base64") else { return nil }
        return base64(String(uri[uri.index(after: comma)...]), mediaType: String(mediaType), budget: budget)
    }

    /// 标准 base64（容忍空白），不行再试 URL-safe 字母表
    static func base64(_ text: String, mediaType: String?, budget: CodingImageBudget) -> CodingImage? {
        guard text.utf8.count <= maxBase64 else { return nil }
        let bytes = text.utf8.filter { $0 != 0x20 && !(0x09...0x0D).contains($0) }
        let urlSafe = bytes.map { $0 == UInt8(ascii: "-") ? UInt8(ascii: "+") : ($0 == UInt8(ascii: "_") ? UInt8(ascii: "/") : $0) }
        guard let decoded = Data(base64Encoded: Data(bytes)) ?? Data(base64Encoded: Data(urlSafe)) else { return nil }
        return attachment(decoded, mediaType: mediaType, budget: budget)
    }

    /// 单张 ≤ 12 MB；没有可信 MIME 就按魔数认，认不出不收；最后扣转录总预算
    static func attachment(_ data: Data, mediaType: String?, budget: CodingImageBudget) -> CodingImage? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        guard let type = mediaType.flatMap({ $0.hasPrefix("image/") ? $0 : nil }) ?? sniff(data) else { return nil }
        guard budget.consume(data.count) else { return nil }
        return CodingImage(mediaType: type, data: data)
    }

    static func sniff(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(512))
        func starts(_ prefix: [UInt8]) -> Bool { head.count >= prefix.count && Array(head[0..<prefix.count]) == prefix }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
        if head.count >= 12, starts(Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if starts(Array("BM".utf8)) { return "image/bmp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if let text = String(bytes: head, encoding: .utf8), text.contains("<svg") { return "image/svg+xml" }
        return nil
    }
}
#endif
