import Foundation
import SwiftData

/// ChatGPT 导出（conversations.json，mapping 树）→ 导入 payload。
/// 写库走 `PayloadImportEngine`（#043 D10）；读文件按对话切片逐条解码（#050 E2），转 payload 见 `ChatGPTPayloadBuilder`。
enum ConversationImporter {

    /// 读一个 conversations.json（只映射 + 切片，不整份解码）
    static func load(file url: URL) throws -> JSONArrayFile {
        try JSONArrayFile(url: url)
    }

    static func makePayload(from raw: RawConversation) -> ImportedConversationPayload? {
        ChatGPTPayloadBuilder().payload(from: raw)
    }
}

// MARK: - Raw JSON Types

struct RawConversation: Decodable {
    let id: String?
    let conversation_id: String?
    let title: String?
    let create_time: Double?
    let update_time: Double?
    let current_node: String?
    let mapping: [String: RawNode]?
}

struct RawNode: Decodable {
    let id: String?
    let message: RawMessage?
    let parent: String?
    let children: [String]?
}

struct RawMessage: Decodable {
    let id: String?
    let author: RawAuthor?
    let create_time: Double?
    let update_time: Double?
    let content: RawContent?
    let status: String?
    let end_turn: Bool?
    let weight: Double?
    let metadata: AnyCodable?
    let recipient: String?
    let channel: String?
}

struct RawAuthor: Decodable {
    let role: String?
    let name: String?
}

/// 各 content_type 的字段不一样（text / code / thoughts / tether_quote…），逐个宽松解：一个字段类型不对不连累整条
struct RawContent: Decodable {
    let content_type: String?
    let parts: [RawPart]?
    let text: String?
    let language: String?
    let result: String?
    let summary: String?
    let title: String?
    let url: String?
    let thoughts: [RawThought]?
    let user_profile: String?
    let user_instructions: String?
    /// content_type 直接是 image_asset_pointer 时的指针
    let asset_pointer: String?

    enum CodingKeys: String, CodingKey {
        case content_type, parts, text, language, result, summary, title, url, thoughts, user_profile, user_instructions
        case asset_pointer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content_type = try? c.decodeIfPresent(String.self, forKey: .content_type)
        parts = try? c.decodeIfPresent([RawPart].self, forKey: .parts)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        thoughts = try? c.decodeIfPresent([RawThought].self, forKey: .thoughts)
        user_profile = try? c.decodeIfPresent(String.self, forKey: .user_profile)
        user_instructions = try? c.decodeIfPresent(String.self, forKey: .user_instructions)
        asset_pointer = try? c.decodeIfPresent(String.self, forKey: .asset_pointer)
    }

    /// parts 里的字符串用 \n 连（旧代码的正文就是这么来的）
    var joinedParts: String {
        (parts ?? []).compactMap { if case .string(let s) = $0 { return s } else { return nil } }.joined(separator: "\n")
    }
}

struct RawThought: Decodable {
    let summary: String?
    let content: String?
}

/// `message.metadata` 里导入用得上的几项
struct RawMetadata {
    struct Attachment {
        let id: String
        let name: String?
        let size: UInt64?
    }

    var attachments: [Attachment] = []
    var isHidden = false

    init(_ any: AnyCodable?) {
        guard let dict = any?.value as? [String: AnyCodable] else { return }
        isHidden = dict["is_visually_hidden_from_conversation"]?.value as? Bool ?? false
        for item in dict["attachments"]?.value as? [AnyCodable] ?? [] {
            guard let a = item.value as? [String: AnyCodable], let id = a["id"]?.value as? String else { continue }
            let size = (a["size"]?.value as? Int).map { UInt64(max(0, $0)) }
            attachments.append(Attachment(id: id, name: a["name"]?.value as? String, size: size))
        }
    }
}

extension RawMessage {
    var metadataObject: RawMetadata { RawMetadata(metadata) }
}

enum RawPart: Decodable {
    case string(String)
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let obj = try? container.decode([String: AnyCodable].self) {
            self = .object(obj)
        } else {
            self = .string("")
        }
    }
}

/// Generic type to handle arbitrary JSON values
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if container.decodeNil() { value = NSNull() }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else { value = NSNull() }
    }
}
