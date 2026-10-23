import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// clipboard_read：读系统剪贴板。域 = clipboard（三档）。
/// iOS 程序化读取跨 app 内容会触发系统「允许粘贴」提示——那就是天然的二次权限 UI，不绕。
/// 文本/URL 直接回；图片落成附件（AttachmentStore）返回相对路径供 ocr_image / 发送用。
enum ClipboardTool {
    static let toolName = "clipboard_read"
    static let maxChars = 20_000

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "读取用户设备剪贴板当前内容。文本/链接直接返回（超 20000 字截断）；图片会存为附件并返回 path（可交给 ocr_image）。只在用户明确要你看剪贴板时调用。",
            properties: [:],
            required: []
        )
    }

    @MainActor
    static func execute(profileId: String, conversationId: String?) -> DeviceToolExec {
        #if canImport(UIKit)
        let pb = UIPasteboard.general
        if let s = pb.string, !s.isEmpty {
            return textResult(s, kind: pb.hasURLs ? "url" : "text")
        }
        if let img = pb.image, let data = img.pngData() {
            return imageResult(data, width: Int(img.size.width * img.scale), height: Int(img.size.height * img.scale), profileId: profileId, conversationId: conversationId)
        }
        return DeviceToolIO.ok(["kind": "empty", "text": ""])
        #else
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty {
            return textResult(s, kind: (pb.string(forType: .URL) != nil || URL(string: s)?.scheme != nil) ? "url" : "text")
        }
        if let img = pb.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
            return imageResult(data, width: rep.pixelsWide, height: rep.pixelsHigh, profileId: profileId, conversationId: conversationId)
        }
        return DeviceToolIO.ok(["kind": "empty", "text": ""])
        #endif
    }

    private static func textResult(_ s: String, kind: String) -> DeviceToolExec {
        var data: [String: Any] = ["kind": kind, "text": String(s.prefix(maxChars)), "length": s.count]
        if s.count > maxChars { data["_warning"] = "已截断到 \(maxChars) 字" }
        return DeviceToolIO.ok(data)
    }

    private static func imageResult(_ data: Data, width: Int, height: Int, profileId: String, conversationId: String?) -> DeviceToolExec {
        guard let convId = conversationId else {
            return DeviceToolIO.ok(["kind": "image", "width": width, "height": height, "_warning": "无对话上下文，图片未保存"])
        }
        do {
            let ref = try AttachmentStore.save(fileName: "clipboard-\(Int(Date().timeIntervalSince1970)).png", data: data,
                                               conversationId: convId, conversationTitle: nil, profileId: profileId)
            return DeviceToolIO.ok(
                ["kind": "image", "path": ref, "width": width, "height": height],
                card: DeviceToolIO.card(type: "image", title: "剪贴板图片",
                                        subtitle: "\(width)×\(height)", icon: "doc.on.clipboard", imagePath: ref)
            )
        } catch {
            return DeviceToolIO.fail("failed", "图片保存失败：\(error.localizedDescription)")
        }
    }
}
