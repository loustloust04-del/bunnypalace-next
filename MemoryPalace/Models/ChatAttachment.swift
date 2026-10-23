import Foundation

enum ChatAttachmentKind: String, Hashable, Codable {
    case text
    case image
    case card   // 聊天卡片待发版本（research-chat-cards §4.4）：extractedText = 完整卡片块
    case voice  // 她发的语音条（plan-voice-note M1）：音频已在文件库（storedRef），extractedText = 转写
}

enum ChatAttachmentError: LocalizedError {
    case imageTooLarge(String, Int)
    case invalidImage(String)

    var errorDescription: String? {
        switch self {
        case .imageTooLarge(let name, let limitMB):
            return "\(name) 太大了，当前图片上限 \(limitMB) MB"
        case .invalidImage(let name):
            return "无法读取图片：\(name)"
        }
    }
}

struct PendingChatAttachment: Identifiable, Hashable, Codable {
    static let maxImageBytes = 8 * 1024 * 1024

    var id = UUID()
    let name: String
    let kind: ChatAttachmentKind
    let typeDescription: String
    let extractedText: String
    let byteCount: Int
    let mimeType: String?
    let imageData: Data?
    let fileData: Data?   // C2 任意文件：非图的原始字节（发给 CC 处理）
    /// 编辑旧消息带回的原附件：文件库里已有的 ref 路径。写回时直接出 ref 段，不再落盘 / 压缩（plan-edit-attachments R2）
    var storedRef: String? = nil
    /// 语音条时长（秒）。可选字段：老草稿 / 老排队 JSON 没这个键照样解（plan-voice-note M1）
    var audioDuration: Double? = nil
    /// 本条语音的声学线索，与转写分开；旧草稿缺这个键仍能读。
    var voiceProsody: VoiceProsodyContext? = nil
    var speakerCue: String? = nil

    var previewText: String {
        if extractedText.count > 4000 {
            return String(extractedText.prefix(4000)) + "\n...（已截断）"
        }
        return extractedText
    }

    var isImage: Bool {
        kind == .image && imageData != nil
    }

    /// C2：非图但带原始字节 = 可作为"真文件"发给 CC
    var isFile: Bool {
        !isImage && fileData != nil
    }

    static func text(name: String, typeDescription: String, extractedText: String, byteCount: Int,
                     fileData: Data? = nil, fileMime: String? = nil) -> PendingChatAttachment {
        PendingChatAttachment(
            name: name,
            kind: .text,
            typeDescription: typeDescription,
            extractedText: extractedText,
            byteCount: byteCount,
            mimeType: fileMime,
            imageData: nil,
            fileData: fileData
        )
    }

    static func card(_ card: ChatCard) -> PendingChatAttachment {
        let block = card.blockText
        return PendingChatAttachment(
            name: card.title, kind: .card, typeDescription: card.kindLabel,
            extractedText: block, byteCount: block.utf8.count,
            mimeType: nil, imageData: nil, fileData: nil)
    }

    /// kind == .card 时解析出卡片
    var chatCard: ChatCard? {
        guard kind == .card else { return nil }
        return ChatCardExtractor.cards(in: extractedText).first
    }

    /// 语音条：音频发送前已自己存进文件库（externalize 只会转 .fileDataRef，会丢时长和转写——plan-voice-note 第二节 1）
    static func voice(path: String, duration: Double, transcript: String?) -> PendingChatAttachment {
        var att = PendingChatAttachment(
            name: (path as NSString).lastPathComponent, kind: .voice, typeDescription: "语音",
            extractedText: transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            byteCount: 0, mimeType: "audio/mp4", imageData: nil, fileData: nil)
        att.storedRef = path
        att.audioDuration = duration
        return att
    }

    static func image(name: String, typeDescription: String, mimeType: String, data: Data) throws -> PendingChatAttachment {
        guard data.count <= maxImageBytes else {
            throw ChatAttachmentError.imageTooLarge(name, maxImageBytes / 1024 / 1024)
        }
        return PendingChatAttachment(
            name: name,
            kind: .image,
            typeDescription: typeDescription,
            extractedText: "",
            byteCount: data.count,
            mimeType: mimeType,
            imageData: data,
            fileData: nil
        )
    }
}

enum ChatAttachmentPromptBuilder {
    /// 卡片就是消息正文：宏展开之后再拼上（卡片 JSON 不参与宏替换，research-chat-cards §6）
    static func appendingCards(to text: String, from attachments: [PendingChatAttachment]) -> String {
        let blocks = attachments.filter { $0.kind == .card }.map(\.extractedText)
        guard !blocks.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ((trimmed.isEmpty ? [] : [trimmed]) + blocks).joined(separator: "\n\n")
    }

    static func modelInput(text: String, attachments: [PendingChatAttachment]) -> String {
        var parts: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }

        for attachment in attachments {
            if attachment.kind == .card {
                parts.append(attachment.extractedText)   // 卡片是正文，不包 [附件] 壳
                continue
            }
            if attachment.kind == .voice {
                parts.append(voiceLine(attachment))      // 语音条：一行给 AI 看，不包 [附件] 壳
                continue
            }
            if attachment.isImage {
                parts.append("[图片附件：\(attachment.name) · \(attachment.typeDescription)]")
            } else {
                parts.append("""
                [附件：\(attachment.name) · \(attachment.typeDescription)]
                \(attachment.extractedText)
                [/附件]
                """)
            }
        }

        return parts.joined(separator: "\n\n")
    }

    /// `[语音 0:07] 转写`；没转出文字 → `[语音 0:07]（没转出文字）`。转写压成一行（只给 AI 看；显示 / 复制读 segments，不剥这行）
    static func voiceLine(_ attachment: PendingChatAttachment) -> String {
        let head = "[语音 \(VoiceWave.clock(attachment.audioDuration ?? 0))]"
        let transcript = attachment.extractedText
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let line = transcript.isEmpty ? head + "（没转出文字）" : head + " " + transcript
        return [line, attachment.voiceProsody?.hint, attachment.speakerCue].compactMap { $0 }.joined(separator: "\n")
    }

    struct UserMessageParts {
        let displayText: String
        let modelText: String
        let contentType: String
        /// nil = 没有非卡片附件，节点不写 segments
        let segments: [MessageSegment]?
    }

    /// 用户消息写进节点的那几样（sendMessage / editAndResend 共用）。`displayBase` = 调用方已宏展开 + trim 的文字；
    /// 卡片拼进正文、不算附件，contentType / segments 只看非卡片附件（research-chat-cards §6）
    static func userMessage(displayBase: String, attachments: [PendingChatAttachment]) -> UserMessageParts {
        let displayText = appendingCards(to: displayBase, from: attachments)
        let nonCards = attachments.filter { $0.kind != .card }
        return UserMessageParts(
            displayText: displayText,
            modelText: modelInput(text: displayText, attachments: nonCards),
            contentType: nonCards.isEmpty ? "text" : "segmented",
            segments: nonCards.isEmpty ? nil : segments(text: displayText, attachments: nonCards))
    }

    static func segments(text: String, attachments: [PendingChatAttachment]) -> [MessageSegment] {
        var result: [MessageSegment] = []
        // 图片在前（气泡上方显示小方块）
        for att in attachments where att.isImage {
            if let ref = att.storedRef {
                result.append(.imageRef(name: att.name, type: att.typeDescription, path: ref))
            } else if let data = att.imageData {
                result.append(.image(name: att.name, type: att.typeDescription, data: data))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(.text(trimmed))
        }
        // 语音条紧跟文字：音频已在文件库，直接出 ref（script = 转写，空转写存 nil）
        for att in attachments where att.kind == .voice {
            guard let ref = att.storedRef else { continue }
            result.append(.audioRef(name: att.name, mime: att.mimeType ?? "audio/mp4", path: ref,
                                    duration: att.audioDuration,
                                    script: att.extractedText.isEmpty ? nil : att.extractedText))
        }
        // 文件附件在后：有原始字节 → .fileData（卡片+可发 CC 真文件）；否则退化 .attachment（纯文本）
        for att in attachments where !att.isImage && att.kind != .voice {
            if let ref = att.storedRef, att.fileData != nil {
                result.append(.fileDataRef(name: att.name, mime: att.mimeType ?? "application/octet-stream", path: ref))
            } else if let fd = att.fileData {
                result.append(.fileData(name: att.name, mime: att.mimeType ?? "application/octet-stream", data: fd))
            } else {
                result.append(.attachment(name: att.name, type: att.typeDescription, extractedContent: att.previewText))
            }
        }
        return result
    }

    // MARK: - 编辑旧消息：节点 → 输入条内容（plan-edit-attachments §1）

    struct RestoredComposer {
        var text: String
        var attachments: [PendingChatAttachment]
        var quotePreview: String?
        var quoteReplyTo: String?
        /// 拿不回来的附件数（文件被移走 / 导入旧对话只有名字）
        var missingCount: Int
    }

    /// 不是无损逆运算，是「规范化编辑」：文字是宏已展开的显示文本，附件图在前、文件在后（发送时 segments 的顺序）。
    /// `read`：ref → 字节；`extract`：ref → 从磁盘原文件重新抽文字（壳对不上时兜底）
    static func restore(
        content: String,
        segments: [MessageSegment]?,
        replyToId: String?,
        replyQuote: String?,
        read: (String) -> Data?,
        extract: (String) -> PendingChatAttachment?
    ) -> RestoredComposer {
        var text = segments.map { segs in
            segs.compactMap { seg -> String? in
                if case .text(let t) = seg { return t }
                return nil
            }.joined(separator: "\n\n")
        } ?? content

        // 卡片：原样找得到才拆成 chip；找不到（手打 / 非规范 JSON）留在文字里，绝不两边都有
        var cards: [PendingChatAttachment] = []
        for card in ChatCardExtractor.cards(in: text) {
            guard let range = text.range(of: card.blockText) else { continue }
            text.removeSubrange(range)
            cards.append(.card(card))
        }
        text = text.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var images: [PendingChatAttachment] = []
        var files: [PendingChatAttachment] = []
        var missing = 0
        var shells = fileShells(in: content, after: segments == nil ? nil : text)
        func takeShell(named name: String) -> (type: String, text: String)? {
            guard let idx = shells.firstIndex(where: { $0.name == name }) else { return nil }
            let shell = shells[idx]
            shells.removeSubrange(...idx)   // 按顺序消费，不回头复用
            return (shell.type, shell.text)
        }

        for seg in segments ?? [] {
            switch seg {
            case .image(let name, let type, let data):
                if let att = try? PendingChatAttachment.image(name: name, typeDescription: type ?? "图片", mimeType: "image/jpeg", data: data) {
                    images.append(att)
                } else { missing += 1 }
            case .imageRef(let name, let type, let path):
                if let data = read(path),
                   var att = try? PendingChatAttachment.image(name: name, typeDescription: type ?? "图片", mimeType: "image/jpeg", data: data) {
                    att.storedRef = path
                    images.append(att)
                } else { missing += 1 }
            case .fileData(let name, let mime, let data):
                if let shell = takeShell(named: name) {
                    files.append(.text(name: name, typeDescription: shell.type, extractedText: shell.text,
                                       byteCount: data.count, fileData: data, fileMime: mime))
                } else { missing += 1 }
            case .fileDataRef(let name, let mime, let path):
                guard let data = read(path) else { missing += 1; continue }
                let recovered = takeShell(named: name) ?? extract(path).map { ($0.typeDescription, $0.extractedText) }
                guard let recovered else { missing += 1; continue }
                var att = PendingChatAttachment.text(name: name, typeDescription: recovered.0, extractedText: recovered.1,
                                                     byteCount: data.count, fileData: data, fileMime: mime)
                att.storedRef = path
                files.append(att)
            case .attachment(let name, let type, let extracted):
                let recovered = takeShell(named: name) ?? (type ?? "文件", extracted ?? "")
                files.append(.text(name: name, typeDescription: recovered.0, extractedText: recovered.1,
                                   byteCount: recovered.1.utf8.count))
            case .file:
                missing += 1
            case .audioRef:
                continue   // 语音条不恢复：恢复回输入框只会变成一行 [语音…] 文字（菜单里本来就没编辑，plan-voice-note 第二节 7）
            default:
                continue
            }
        }

        let hasQuote = !(replyToId ?? "").isEmpty && !(replyQuote ?? "").isEmpty
        return RestoredComposer(
            text: text,
            attachments: images + cards + files,
            quotePreview: hasQuote ? replyQuote : nil,
            quoteReplyTo: hasQuote ? replyToId : nil,
            missingCount: missing)
    }

    /// content 里按出现顺序的文件壳 `[附件：名 · 类型]\n全文\n[/附件]`（modelInput 的格式）。
    /// 结束标记要求其后是串尾或下一个壳，全文里自带 `[/附件]` 不会截断。`after`：正文，从它后面开始找，躲开她自己打的字
    static func fileShells(in content: String, after body: String?) -> [(name: String, type: String, text: String)] {
        var result: [(name: String, type: String, text: String)] = []
        var from = content.startIndex
        if let body, !body.isEmpty, let r = content.range(of: body) { from = r.upperBound }
        while let open = content.range(of: "[附件：", range: from..<content.endIndex),
              let headerEnd = content.range(of: "]\n", range: open.upperBound..<content.endIndex) {
            let header = content[open.upperBound..<headerEnd.lowerBound]
            var closeFrom = headerEnd.lowerBound
            var close: Range<String.Index>?
            while let c = content.range(of: "\n[/附件]", range: closeFrom..<content.endIndex) {
                let rest = content[c.upperBound...]
                if rest.isEmpty || rest.hasPrefix("\n\n[附件：") || rest.hasPrefix("\n\n[图片附件：") { close = c; break }
                closeFrom = c.upperBound
            }
            guard let close, let sep = header.range(of: " · ", options: .backwards) else { break }
            let bodyStart = min(headerEnd.upperBound, close.lowerBound)
            result.append((String(header[..<sep.lowerBound]), String(header[sep.upperBound...]),
                           String(content[bodyStart..<close.lowerBound])))
            from = close.upperBound
        }
        return result
    }
}
