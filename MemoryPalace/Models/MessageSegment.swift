import Foundation

/// Claude 导入 v2 写入的结构化分段。按 `content[]` 原顺序保存。
/// 渲染时（MessageSegmentsView）按顺序 map 成独立 View，每段独立折叠。
///
/// Codable 用自定义 key "kind" 做 tag，保持向后兼容（新增 case 时老解码跳过即可）。
enum MessageSegment: Codable, Hashable {
    case text(String)
    case thinking(text: String, signature: String?)
    case toolUse(
        id: String,
        name: String,
        inputJSON: String,
        integrationName: String?,
        iconName: String?
    )
    case toolResult(
        toolUseId: String,
        text: String,
        isError: Bool,
        integrationName: String?
    )
    case flag(
        kind: String,
        helplineName: String?,
        helplinePhone: String?,
        helplineUrl: String?
    )
    case attachment(
        name: String,
        type: String?,
        extractedContent: String?
    )
    case image(name: String, type: String?, data: Data)
    case file(name: String, uuid: String)
    /// 原始字节内联存储的任意文件（CC↔susu 互发；区别于 .file 的 uuid 引用、.attachment 的纯文本）
    case fileData(name: String, mime: String, data: Data)
    /// 附件一份存储：字节在文件库（path = filesystem 相对路径），SwiftData 只存引用。
    /// 老数据仍是内联 .image/.fileData，永久兼容读。
    case imageRef(name: String, type: String?, path: String)
    case fileDataRef(name: String, mime: String, path: String)
    /// 语音条：AI 表演脚本经 TTS 生成的音频。字节在文件库（同 fileDataRef 的一份存储），
    /// script 存表演脚本原文——「换一版」靠它重跑，失败降级时也保住文字。
    case audioRef(name: String, mime: String, path: String, duration: Double?, script: String?)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case signature
        case id
        case name
        case inputJSON
        case integrationName
        case iconName
        case toolUseId
        case isError
        case helplineName
        case helplinePhone
        case helplineUrl
        case type
        case extractedContent
        case data
        case uuid
        case path
        case duration
        case script
    }

    private enum Kind: String, Codable {
        case text
        case thinking
        case toolUse
        case toolResult
        case flag
        case attachment
        case image
        case file
        case fileData
        case imageRef
        case fileDataRef
        case audioRef
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .thinking(let text, let sig):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(sig, forKey: .signature)
        case .toolUse(let id, let name, let inputJSON, let integration, let icon):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(inputJSON, forKey: .inputJSON)
            try c.encodeIfPresent(integration, forKey: .integrationName)
            try c.encodeIfPresent(icon, forKey: .iconName)
        case .toolResult(let useId, let text, let isErr, let integration):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(useId, forKey: .toolUseId)
            try c.encode(text, forKey: .text)
            try c.encode(isErr, forKey: .isError)
            try c.encodeIfPresent(integration, forKey: .integrationName)
        case .flag(let kind, let hName, let hPhone, let hUrl):
            try c.encode(Kind.flag, forKey: .kind)
            try c.encode(kind, forKey: .name)
            try c.encodeIfPresent(hName, forKey: .helplineName)
            try c.encodeIfPresent(hPhone, forKey: .helplinePhone)
            try c.encodeIfPresent(hUrl, forKey: .helplineUrl)
        case .attachment(let name, let type, let extracted):
            try c.encode(Kind.attachment, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encodeIfPresent(extracted, forKey: .extractedContent)
        case .image(let name, let type, let data):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encode(data, forKey: .data)
        case .file(let name, let uuid):
            try c.encode(Kind.file, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(uuid, forKey: .uuid)
        case .fileData(let name, let mime, let data):
            try c.encode(Kind.fileData, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(mime, forKey: .type)
            try c.encode(data, forKey: .data)
        case .imageRef(let name, let type, let path):
            try c.encode(Kind.imageRef, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(type, forKey: .type)
            try c.encode(path, forKey: .path)
        case .fileDataRef(let name, let mime, let path):
            try c.encode(Kind.fileDataRef, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(mime, forKey: .type)
            try c.encode(path, forKey: .path)
        case .audioRef(let name, let mime, let path, let duration, let script):
            try c.encode(Kind.audioRef, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(mime, forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(duration, forKey: .duration)
            try c.encodeIfPresent(script, forKey: .script)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            let s = try c.decode(String.self, forKey: .text)
            self = .text(s)
        case .thinking:
            let s = try c.decode(String.self, forKey: .text)
            let sig = try c.decodeIfPresent(String.self, forKey: .signature)
            self = .thinking(text: s, signature: sig)
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .inputJSON),
                integrationName: try c.decodeIfPresent(String.self, forKey: .integrationName),
                iconName: try c.decodeIfPresent(String.self, forKey: .iconName)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                text: try c.decode(String.self, forKey: .text),
                isError: try c.decode(Bool.self, forKey: .isError),
                integrationName: try c.decodeIfPresent(String.self, forKey: .integrationName)
            )
        case .flag:
            self = .flag(
                kind: try c.decode(String.self, forKey: .name),
                helplineName: try c.decodeIfPresent(String.self, forKey: .helplineName),
                helplinePhone: try c.decodeIfPresent(String.self, forKey: .helplinePhone),
                helplineUrl: try c.decodeIfPresent(String.self, forKey: .helplineUrl)
            )
        case .attachment:
            self = .attachment(
                name: try c.decode(String.self, forKey: .name),
                type: try c.decodeIfPresent(String.self, forKey: .type),
                extractedContent: try c.decodeIfPresent(String.self, forKey: .extractedContent)
            )
        case .image:
            self = .image(
                name: try c.decode(String.self, forKey: .name),
                type: try c.decodeIfPresent(String.self, forKey: .type),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .file:
            self = .file(
                name: try c.decode(String.self, forKey: .name),
                uuid: try c.decode(String.self, forKey: .uuid)
            )
        case .fileData:
            self = .fileData(
                name: try c.decode(String.self, forKey: .name),
                mime: try c.decode(String.self, forKey: .type),
                data: try c.decode(Data.self, forKey: .data)
            )
        case .imageRef:
            self = .imageRef(
                name: try c.decode(String.self, forKey: .name),
                type: try c.decodeIfPresent(String.self, forKey: .type),
                path: try c.decode(String.self, forKey: .path)
            )
        case .fileDataRef:
            self = .fileDataRef(
                name: try c.decode(String.self, forKey: .name),
                mime: try c.decode(String.self, forKey: .type),
                path: try c.decode(String.self, forKey: .path)
            )
        case .audioRef:
            self = .audioRef(
                name: try c.decode(String.self, forKey: .name),
                mime: try c.decode(String.self, forKey: .type),
                path: try c.decode(String.self, forKey: .path),
                duration: try c.decodeIfPresent(Double.self, forKey: .duration),
                script: try c.decodeIfPresent(String.self, forKey: .script)
            )
        }
    }
}

// MARK: - 附件一份存储 · hydrate

extension MessageSegment {
    /// ref 段 → 等价内联段（按需读盘）。非 ref 原样返回；文件丢失返回 nil（调用方给占位）。
    func hydrated(profileId: String) -> MessageSegment? {
        switch self {
        case .imageRef(let name, let type, let path):
            guard let data = AttachmentStore.read(path, profileId: profileId) else { return nil }
            return .image(name: name, type: type, data: data)
        case .fileDataRef(let name, let mime, let path):
            guard let data = AttachmentStore.read(path, profileId: profileId) else { return nil }
            return .fileData(name: name, mime: mime, data: data)
        default:
            return self
        }
    }

    var refDisplayName: String? {
        switch self {
        case .imageRef(let name, _, _), .fileDataRef(let name, _, _): return name
        default: return nil
        }
    }
}

extension Array where Element == MessageSegment {
    /// 气泡是否该走 segmented 渲染：audioRef 不算数——语音条在气泡外侧胶囊渲染，
    /// 只挂了语音条的消息正文仍走纯文本分支（否则挂 segment 瞬间正文蒸发）。
    var hasRenderableSegments: Bool {
        contains { seg in
            if case .audioRef = seg { return false }
            return true
        }
    }

    /// 她发的纯语音条（plan-voice-note M1）：有 audioRef、没有任何别的段。气泡不画文字（content 只是给 AI 看的那行），
    /// 只画胶囊 + 转文字；长按菜单藏编辑。AI 的语音条同样可能只有一个 audioRef 段（正文在 content），所以只对 user 节点用
    var userVoiceNote: Bool {
        !isEmpty && allSatisfy { if case .audioRef = $0 { return true } else { return false } }
    }

    /// 语音条段（路径 / 时长 / 转写或表演脚本），按出现顺序
    var audioRefs: [(path: String, duration: Double?, script: String?)] {
        compactMap { seg in
            if case .audioRef(_, _, let p, let d, let s) = seg { return (p, d, s) }
            return nil
        }
    }

    /// 带语音段（她的语音条 / 文字 + 语音）。显示、复制都读段，不从 content 形状猜（sol P2-4）：
    /// content 里 `[语音 m:ss] 转写` 那行只给 AI 看，手打的同形状行不能被误删
    var hasAudioRef: Bool {
        contains { if case .audioRef = $0 { return true } else { return false } }
    }

    /// 她带语音的消息里打的字（.text 段原文，段间空一行）；没语音段 = nil（调用方照用 content，原样）
    var userTypedTextIfVoice: String? {
        guard hasAudioRef else { return nil }
        return compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined(separator: "\n\n")
    }

    /// 复制 / 引用 / 多选出口：按段顺序，打的字 + 每条语音的转写（没转出文字的跳过）；没语音段 = nil
    var userVoiceCopyText: String? {
        guard hasAudioRef else { return nil }
        return compactMap { seg -> String? in
            switch seg {
            case .text(let s): return s
            case .audioRef(_, _, _, _, let script): return (script ?? "").isEmpty ? nil : script
            default: return nil
            }
        }.joined(separator: "\n\n")
    }

    /// 渲染/出口前统一解 ref：内联段原样过，ref 读盘，丢失文件降级成 .attachment 占位卡（复用现有渲染，零新 UI）。
    func hydratedForDisplay(profileId: String) -> [MessageSegment] {
        map { seg in
            seg.hydrated(profileId: profileId)
                ?? .attachment(name: seg.refDisplayName ?? "附件", type: nil, extractedContent: "附件文件已被移动或删除")
        }
    }
}
