import Foundation

// MARK: - TavernCard (解析后的中间模型)

struct TavernCard {
    var name: String = ""
    var description: String = ""
    var personality: String = ""
    var scenario: String = ""
    var firstMes: String = ""
    var alternateGreetings: [String] = []
    var mesExample: String = ""
    var systemPrompt: String = ""
    var postHistoryInstructions: String = ""
    var creatorNotes: String = ""
    var characterBookName: String?
    var characterBookEntries: [[String: Any]] = []
    var regexScripts: [[String: Any]] = []
    var imageData: Data?
    var rawJSONData: Data?
    var tags: [String] = []
    var creator: String?
    var characterVersion: String?

    /// 是否包含世界书
    var hasWorldBook: Bool {
        !characterBookEntries.isEmpty
    }

    /// 是否包含正则脚本
    var hasRegexScripts: Bool {
        !regexScripts.isEmpty
    }
}

// MARK: - Parse Errors

enum TavernCardError: LocalizedError {
    case invalidJSON
    case invalidPNG
    case noCharaChunk
    case invalidBase64
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "无法解析助手模板 JSON"
        case .invalidPNG: return "无效的 PNG 文件"
        case .noCharaChunk: return "PNG 中未找到助手模板数据（缺少 chara/ccv3 chunk）"
        case .invalidBase64: return "助手模板 base64 数据无效"
        case .unsupportedFormat(let ext): return "不支持的文件格式：\(ext)"
        }
    }
}

// MARK: - Parsing

extension TavernCard {

    /// 从文件 URL 自动选择解析方式
    static func parseFile(url: URL) throws -> TavernCard {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "json":
            return try parseJSON(data: data)
        case "png":
            return try parsePNG(data: data)
        default:
            throw TavernCardError.unsupportedFormat(url.pathExtension)
        }
    }

    /// 解析 JSON 格式角色卡（V2/V3 兼容）
    ///
    /// V2 / V3 都优先读 `data.*`；顶层仅兼容旧卡兜底。
    static func parseJSON(data: Data) throws -> TavernCard {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TavernCardError.invalidJSON
        }

        let inner = json["data"] as? [String: Any] ?? [:]

        // 优先 data.*，fallback 顶层
        func str(_ key: String, innerKey: String? = nil) -> String {
            (inner[innerKey ?? key] as? String)
                ?? (json[key] as? String)
                ?? ""
        }

        var card = TavernCard()
        card.name = str("name")
        card.description = str("description")
        card.personality = str("personality")
        card.scenario = str("scenario")
        card.firstMes = str("first_mes")
        card.mesExample = str("mes_example")

        card.rawJSONData = data
        card.systemPrompt = str("system_prompt")
        card.postHistoryInstructions = str("post_history_instructions")
        card.alternateGreetings = inner["alternate_greetings"] as? [String]
            ?? json["alternate_greetings"] as? [String] ?? []
        card.creatorNotes = inner["creator_notes"] as? String
            ?? json["creator_notes"] as? String ?? json["creatorcomment"] as? String ?? ""
        card.tags = inner["tags"] as? [String] ?? json["tags"] as? [String] ?? []
        card.creator = inner["creator"] as? String ?? json["creator"] as? String
        card.characterVersion = inner["character_version"] as? String ?? json["character_version"] as? String

        if let book = inner["character_book"] as? [String: Any] ?? json["character_book"] as? [String: Any] {
            card.characterBookName = book["name"] as? String
            card.characterBookEntries = book["entries"] as? [[String: Any]] ?? []
        }
        let ext = inner["extensions"] as? [String: Any] ?? [:]
        let legacyExt = json["extensions"] as? [String: Any] ?? [:]
        card.regexScripts = ext["regex_scripts"] as? [[String: Any]]
            ?? legacyExt["regex_scripts"] as? [[String: Any]] ?? []

        return card
    }

    /// 解析 PNG 格式角色卡（从 tEXt chunk 提取 JSON）
    ///
    /// PNG chunk 结构：4B length + 4B type + data + 4B CRC
    /// tEXt chunk data：keyword (null-terminated) + text
    /// 优先找 "ccv3"（V3），fallback "chara"（V2）
    static func parsePNG(data: Data) throws -> TavernCard {
        // 验证 PNG signature
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 8,
              [UInt8](data.prefix(8)) == signature else {
            throw TavernCardError.invalidPNG
        }

        // 遍历 chunks，收集所有 tEXt chunk
        var charaText: String?
        var ccv3Text: String?
        var offset = 8

        while offset + 12 <= data.count {
            // 安全读取 4 bytes big-endian UInt32
            let length = Int(UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3]))
            let typeBytes = data[offset+4..<offset+8]
            let typeStr = String(bytes: typeBytes, encoding: .ascii) ?? ""

            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + length

            guard chunkDataEnd + 4 <= data.count else { break }

            if typeStr == "tEXt" || typeStr == "iTXt" {
                let chunkData = data[chunkDataStart..<chunkDataEnd]
                // keyword 以 null byte 结尾
                if let nullIndex = chunkData.firstIndex(of: 0) {
                    let keyword = String(bytes: chunkData[chunkData.startIndex..<nullIndex], encoding: .ascii) ?? ""
                    // iTXt 有额外 header（compression flag + method + language + translated keyword），跳过
                    var textStart = chunkData.index(after: nullIndex)
                    if typeStr == "iTXt" {
                        // 跳过 compression_flag(1) + compression_method(1) + 两个 null-terminated 字符串
                        var nullCount = 0
                        var idx = textStart
                        // 先跳 2 bytes (compression flag + method)
                        if idx < chunkData.endIndex { idx = chunkData.index(after: idx) }
                        if idx < chunkData.endIndex { idx = chunkData.index(after: idx) }
                        // 跳两个 null-terminated strings
                        while idx < chunkData.endIndex && nullCount < 2 {
                            if chunkData[idx] == 0 { nullCount += 1 }
                            idx = chunkData.index(after: idx)
                        }
                        textStart = idx
                    }
                    let text = String(bytes: chunkData[textStart..<chunkData.endIndex], encoding: .utf8)
                        ?? String(bytes: chunkData[textStart..<chunkData.endIndex], encoding: .ascii)
                        ?? ""

                    // 关键字不分大小写（和酒馆 character-card-parser.js 一致）
                    if keyword.lowercased() == "ccv3" {
                        ccv3Text = text
                    } else if keyword.lowercased() == "chara" {
                        charaText = text
                    }
                }
            }

            // 跳到下一个 chunk: length + type(4) + data(length) + CRC(4)
            offset = chunkDataEnd + 4
        }

        // 优先 ccv3，fallback chara
        guard let base64Text = ccv3Text ?? charaText else {
            throw TavernCardError.noCharaChunk
        }

        guard let jsonData = Data(base64Encoded: base64Text) else {
            throw TavernCardError.invalidBase64
        }

        var card = try parseJSON(data: jsonData)
        card.imageData = data  // 保存原始 PNG 作为封面图
        return card
    }
}
