import Foundation
import PDFKit
import UniformTypeIdentifiers

enum AttachmentTextExtractorError: LocalizedError {
    case unsupported(String)
    case oversized(String, Int)
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "暂不支持读取这个文件：\(name)"
        case .oversized(let name, let limitMB):
            return "\(name) 太大了，当前上限 \(limitMB) MB"
        case .unreadable(let name):
            return "无法读取文件内容：\(name)"
        case .empty(let name):
            return "没有从文件里读到可发送的文字：\(name)"
        }
    }
}

enum AttachmentTextExtractor {
    static let maxFileBytes = 25 * 1024 * 1024   // C2：任意文件上限 25MB（原 8MB 太小，zip/pdf 不够）
    static let maxExtractedCharacters = 60_000

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "csv", "tsv", "log",
        "swift", "py", "js", "jsx", "ts", "tsx", "html", "htm", "css",
        "xml", "yaml", "yml", "toml", "ini", "sh", "zsh", "bash",
        "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go",
        "rb", "php", "sql", "plist"
    ]

    static func extract(from url: URL) throws -> PendingChatAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let name = url.lastPathComponent.isEmpty ? "附件" : url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .localizedTypeDescriptionKey])
        let size = values?.fileSize ?? ((try? Data(contentsOf: url).count) ?? 0)
        guard size <= maxFileBytes else {
            throw AttachmentTextExtractorError.oversized(name, maxFileBytes / 1024 / 1024)
        }

        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let typeDescription = values?.localizedTypeDescription ?? type?.localizedDescription ?? url.pathExtension.uppercased()

        if type?.conforms(to: .image) == true {
            guard let data = try? Data(contentsOf: url) else {
                throw AttachmentTextExtractorError.unreadable(name)
            }
            let mime = type?.preferredMIMEType ?? imageMimeType(for: url.pathExtension)
            return try PendingChatAttachment.image(name: name, typeDescription: typeDescription, mimeType: mime, data: data)
        }

        // C2：所有非图文件都读原始字节（给 CC 当真文件发）
        let rawData = try? Data(contentsOf: url)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"

        // 能提取文本的（pdf/代码/文本）仍提取，给非-CC provider 用；不能的（zip/xlsx 等）空文本但带原始文件
        var extracted = ""
        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            extracted = (try? extractPDF(url: url, name: name)) ?? ""
        } else if isTextFile(type: type, extension: url.pathExtension) {
            extracted = (try? extractText(url: url, name: name)) ?? ""
        }

        // 既提不出文本、又没读到原始字节 → 真没法用，才报错
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || rawData != nil else {
            throw AttachmentTextExtractorError.unreadable(name)
        }

        return PendingChatAttachment.text(
            name: name,
            typeDescription: typeDescription,
            extractedText: String(trimmed.prefix(maxExtractedCharacters)),
            byteCount: size,
            fileData: rawData,
            fileMime: mime
        )
    }

    private static func isTextFile(type: UTType?, extension ext: String) -> Bool {
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true || type?.conforms(to: .json) == true {
            return true
        }
        return textExtensions.contains(ext.lowercased())
    }

    private static func extractText(url: URL, name: String) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw AttachmentTextExtractorError.unreadable(name)
        }
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = String(data: data, encoding: .utf16) {
            return string
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractPDF(url: URL, name: String) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw AttachmentTextExtractorError.unreadable(name)
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                pages.append(text)
            }
            if pages.joined(separator: "\n\n").count >= maxExtractedCharacters {
                break
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func imageMimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        default:
            return "image/jpeg"
        }
    }
}
