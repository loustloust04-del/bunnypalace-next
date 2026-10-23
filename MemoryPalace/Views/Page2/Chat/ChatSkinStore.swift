#if os(iOS)
import UIKit

/// 聊天皮肤的落地与加载。
///
/// **为什么要把 web 资源从 bundle 拷出来**：xcodegen 把 `Resources/Web/` 的文件**平铺**进
/// bundle 根（实测 `skins/terminal.css` → 根目录 `terminal.css`），皮肤自带的 `Images/`
/// 没法在 bundle 里保持目录结构；而 `loadFileURL(_:allowingReadAccessTo:)` 只能授权一棵树，
/// 文档在 bundle、皮肤在 Application Support 的话 web 读不到皮肤图片。
/// 所以两边都放进 Application Support 的同一棵树，授权根目录。
///
/// ```
/// Application Support/
///   ChatWeb/     chat.html / chat-base.css / chat-runtime.js   ← 每次启动与 bundle 同步
///   ChatSkins/
///     active/    style.css + Images/…                          ← 当前皮肤
/// ```
/// P3 换成 `mp-asset://` 后这套目录仍然是皮肤的落地位置，只是不再需要 ChatWeb 这一份拷贝。
enum ChatSkinStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var webDir: URL { root.appendingPathComponent("ChatWeb", isDirectory: true) }
    static var skinsDir: URL { root.appendingPathComponent("ChatSkins", isDirectory: true) }
    static var activeSkinDir: URL { skinsDir.appendingPathComponent("active", isDirectory: true) }

    /// bundle → Application Support 同步 web 资源。按修改时间比对，没变就不拷。
    static func syncWebAssets() {
        let fm = FileManager.default
        try? fm.createDirectory(at: webDir, withIntermediateDirectories: true)
        for name in ["chat.html", "chat-base.css", "chat-runtime.js"] {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            guard let src = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "Web")
                ?? Bundle.main.url(forResource: stem, withExtension: ext) else {
                KBProbe.log("[CSSCHAT] bundle 缺 \(name)")
                continue
            }
            let dst = webDir.appendingPathComponent(name)
            let srcDate = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            let dstDate = (try? dst.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard srcDate > dstDate else { continue }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// 文档 URL（同步之后的那一份）
    static var documentURL: URL { webDir.appendingPathComponent("chat.html") }

    /// 当前皮肤的 CSS。没装皮肤返回 nil（走默认 chat-base.css）。
    /// CSS 里的图片路径是相对文档的 `../ChatSkins/active/Images/…`，
    /// 所以两边必须在同一棵授权树下。
    static func activeSkinCSS() -> String? {
        let f = activeSkinDir.appendingPathComponent("style.css")
        guard let s = try? String(contentsOf: f, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }


    // MARK: - 基础项（设置页的快捷旋钮，和主聊天的外观各存各的）

    static let fontScaleKey = "cssChat.fontScale"
    static let bgOpacityKey = "cssChat.bgOpacity"
    static let fontScaleDefault = 1.2
    /// 不放 active/ 里：换皮肤 / 恢复默认皮肤不该把背景图一起删了
    static var userBackgroundURL: URL { skinsDir.appendingPathComponent("user-bg.jpg") }

    static var hasUserBackground: Bool { FileManager.default.fileExists(atPath: userBackgroundURL.path) }

    static func saveUserBackground(_ image: UIImage) throws {
        let maxSide: CGFloat = 2400
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)
        try data.write(to: userBackgroundURL, options: .atomic)
        notifyChanged()
    }

    static func removeUserBackground() {
        try? FileManager.default.removeItem(at: userBackgroundURL)
        notifyChanged()
    }

    /// 注在皮肤**之前**（`#mp-base`）：皮肤 / 手写 CSS 写了同名变量就以 CSS 为准。
    static func baseCSS() -> String {
        let d = UserDefaults.standard
        let scale = d.object(forKey: fontScaleKey) as? Double ?? fontScaleDefault
        var css = ":root { --mp-font-scale: \(scale); }\n"
        if let mtime = (try? userBackgroundURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 {
            let opacity = d.object(forKey: bgOpacityKey) as? Double ?? 1
            // 版本号进 URL：scheme handler 按 URL 缓存，换了图不换 URL 会一直喂旧图
            css += """
            body::before { content: ""; position: fixed; inset: 0; pointer-events: none;
              background: url("mp-asset://bg/user?v=\(Int(mtime))") center / cover no-repeat;
              opacity: \(opacity); }

            """
        }
        return css
    }

    /// 皮肤 CSS / 基础项变了。开着的聊天页收到就重注，不用退出重进。
    static let didChange = Notification.Name("ChatSkinStore.didChange")
    static func notifyChanged() { NotificationCenter.default.post(name: didChange, object: nil) }

    /// 设置页 CSS 编辑器保存。没装皮肤就新建一份叫「自定义」的；写空 = 只清样式，皮肤自带的图留着。
    static func saveUserCSS(_ css: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: activeSkinDir, withIntermediateDirectories: true)
        try css.write(to: activeSkinDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        let manifest = activeSkinDir.appendingPathComponent("manifest.json")
        if !fm.fileExists(atPath: manifest.path),
           let d = try? JSONSerialization.data(withJSONObject: ["name": "自定义", "author": "", "source": "user"]) {
            try? d.write(to: manifest)
        }
        notifyChanged()
    }

    /// 逃生：清掉当前皮肤，之后重进页面就是默认皮肤（chat-base.css）。
    /// 皮肤一律由用户从设置页导入，app 不内置任何主题包。
    static func clearActiveSkin() {
        try? FileManager.default.removeItem(at: activeSkinDir)
        KBProbe.log("[CSSCHAT] 皮肤已重置为默认")
        notifyChanged()
    }

    static func activeSkinName() -> String? {
        let f = activeSkinDir.appendingPathComponent("manifest.json")
        guard let d = try? Data(contentsOf: f),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["name"] as? String
    }
}
#endif
