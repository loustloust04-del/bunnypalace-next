import SwiftUI
import PhotosUI

/// 相册选图 → JPEG 0.82 附件（面 4.1a）：两端同一份。逐张收集失败让调用方一次弹「附件读取失败」（原 mac 底排的做法），不静默丢图。
enum PhotoAttachmentImporter {
    static func attachments(from items: [PhotosPickerItem]) async -> (imported: [PendingChatAttachment], failures: [String]) {
        var imported: [PendingChatAttachment] = []
        var failures: [String] = []
        for (offset, item) in items.enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ChatAttachmentError.invalidImage("照片 \(offset + 1)")
                }
                imported.append(try attachment(from: data, index: offset + 1))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return (imported, failures)
    }

    static func attachment(from data: Data, index: Int) throws -> PendingChatAttachment {
        guard let jpegData = jpeg(from: data) else {
            throw ChatAttachmentError.invalidImage("照片 \(index)")
        }
        return try PendingChatAttachment.image(
            name: "照片 \(index).jpg",
            typeDescription: "图片",
            mimeType: "image/jpeg",
            data: jpegData
        )
    }

    private static func jpeg(from data: Data) -> Data? {
        #if os(macOS)
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
        #else
        return UIImage(data: data)?.jpegData(compressionQuality: 0.82)
        #endif
    }
}
