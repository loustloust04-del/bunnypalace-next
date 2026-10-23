import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 摇一摇反馈：自动截图 + 操作轨迹 + 用户手写笔记 + 可选相册补图。
/// 隐私边界：不发对话标题/楼层名/消息内容（breadcrumb 已剥离消息前缀），
/// 截图和操作 metadata 算诊断必备。
enum FeedbackStore {

    struct Context {
        /// 当前页面描述（如 "iOS page 1（聊天）"）。
        var pageDescription: String = ""
    }

    static var feedbackDirectory: URL {
        #if os(iOS)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("feedback", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("feedback", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - 版本信息

    static var appVersionLine: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (\(b)) · 构建于 \(buildDateString)"
    }

    static var buildDateString: String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return "未知" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static var platformLine: String {
        #if os(iOS)
        return "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)"
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        return "macOS \(v)"
        #endif
    }

    // MARK: - 截图（无新权限）

    /// 触发瞬间调用（弹面板之前），返回 jpeg data。
    static func captureScreenshot() -> Data? {
        #if os(iOS)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.jpegData(compressionQuality: 0.8)
        #else
        guard let view = NSApp.keyWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #endif
    }

    // MARK: - 落盘

    /// 返回写入的 md 文件 URL。
    /// screenshot：摇一摇瞬间截屏；extraImages：粟粟主动从相册选的补图。
    static func save(note: String, screenshot: Data?, extraImages: [Data] = [], context: Context) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = f.string(from: Date())
        let mdURL = feedbackDirectory.appendingPathComponent("\(stem).md")

        var imageLines: [String] = []
        if let screenshot {
            let imgURL = feedbackDirectory.appendingPathComponent("\(stem).jpg")
            try screenshot.write(to: imgURL)
            imageLines.append("![截图](\(stem).jpg)")
        }
        for (i, img) in extraImages.enumerated() {
            let name = "\(stem)-\(i + 2).jpg"
            try img.write(to: feedbackDirectory.appendingPathComponent(name))
            imageLines.append("![附图\(i + 2)](\(name))")
        }
        let imagesLine = imageLines.isEmpty ? "（无）" : imageLines.joined(separator: "\n")

        let timeF = DateFormatter()
        timeF.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let md = """
        ---
        time: \(timeF.string(from: Date()))
        app: \(appVersionLine)
        platform: \(platformLine)
        页面: \(context.pageDescription)
        ---

        ## 反馈内容

        \(note.isEmpty ? "（无文字）" : note)

        ## 最近操作轨迹

        ```
        \(BreadcrumbLog.shared.formattedDump())
        ```

        ## 截图

        \(imagesLine)
        """

        try md.write(to: mdURL, atomically: true, encoding: .utf8)

        #if os(iOS)
        if CCBridgeWebSocketClient.shared.isConnected {
            var payload: [String: Any] = ["type": "feedback", "stem": stem, "md": md]
            if let screenshot {
                payload["image_b64"] = screenshot.base64EncodedString()
            }
            if !extraImages.isEmpty {
                payload["extra_images_b64"] = extraImages.map { $0.base64EncodedString() }
            }
            CCBridgeWebSocketClient.shared.send(payload) { err in
                #if DEBUG
                if let err { print("[feedback] hub 回传失败（本地已留底）: \(err.localizedDescription)") }
                #endif
            }
        }
        #endif

        return mdURL
    }
}

extension Notification.Name {
    /// 摇一摇（iOS）/ ⌘⇧D（macOS）触发反馈面板。ContentView 订阅。
    static let feedbackGestureTriggered = Notification.Name("MemoryPalaceFeedbackGestureTriggered")
}
