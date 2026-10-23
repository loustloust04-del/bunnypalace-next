import SwiftUI
import CoreText

/// Manages custom font import, registration, and selection.
enum FontManager {
    #if os(iOS)
    /// lp0929-R3：0 恢复目录扫描；只改变资源定位，仍在首帧前同步注册全部字体。
    static let launchDirectBundledFonts = ProcessInfo.processInfo.environment["MP_LAUNCH_FONT_DIRECT"] != "0"

    private static func directBundledFontURLs(in resourceURL: URL) -> [URL]? {
        // 与 Resources/Fonts 中的字体文件同步维护；兼容 Xcode 平铺和保留 Fonts/ 两种打包。
        let names = ["LXGWWenKai-Regular.ttf", "SourceHanSerifSC-Regular.otf", "Silkscreen-Regular.ttf",
                     "LongCang-Regular.ttf", "ZCOOLKuaiLe-Regular.ttf"]   // 后两个：便利贴手写 / 可爱字体
        let directories = [resourceURL, resourceURL.appendingPathComponent("Fonts", isDirectory: true)]
        var urls: [URL] = []
        var found: Set<String> = []
        for directory in directories {
            for name in names {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    urls.append(url)
                    found.insert(name)
                }
            }
        }
        // 未知/不完整的打包布局回原扫描，不允许因为优化漏掉现有字体。
        return found.count == names.count ? urls : nil
    }
    #endif

    /// Directory for user-imported fonts
    static var fontsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MemoryPalace/Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Built-in font options
    /// 说明：app bundle 内打包了 LXGWWenKai-Regular / SourceHanSerifSC-Regular（OFL 协议）
    #if os(iOS)
    static let presetFonts: [(name: String, displayName: String)] = [
        ("", "系统默认"),
        ("PingFangSC-Light", "苹方 Light"),
        ("PingFangSC-Regular", "苹方 Regular"),
        ("PingFangSC-Medium", "苹方 Medium"),
        ("PingFangSC-Semibold", "苹方 Semibold"),
        ("LXGWWenKai-Regular", "霞鹜文楷"),
        ("SourceHanSerifSC-Regular", "思源宋体"),
    ]
    #else
    static let presetFonts: [(name: String, displayName: String)] = [
        ("", "系统默认"),
        ("PingFangSC-Regular", "苹方"),
        ("STSongti-SC-Regular", "宋体"),
        ("STKaitiSC-Regular", "楷体"),
        ("STFangsong", "仿宋"),
        ("LXGWWenKai-Regular", "霞鹜文楷"),
        ("SourceHanSerifSC-Regular", "思源宋体"),
    ]
    #endif

    /// Register fonts bundled with the app (Resources/Fonts/*.ttf|*.otf)
    static func registerBundledFonts() {
        #if os(macOS)
        defer { MacMarkdownFontResolver.shared.invalidate() }
        #else
        defer { IOSMarkdownFontCache.invalidate() }
        #endif
        guard let resourceURL = Bundle.main.resourceURL else { return }

        #if os(iOS)
        if launchDirectBundledFonts, let urls = directBundledFontURLs(in: resourceURL) {
            for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            return
        }
        #endif

        var candidates: [URL] = []
        // bundle 顶层（资源被扁平化时会在这里）
        if let files = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: files)
        }
        // Fonts/ 子目录（保留目录结构时）
        let fontsDir = resourceURL.appendingPathComponent("Fonts", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDir,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: files)
        }

        for url in candidates where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Register all user-imported fonts at app launch
    static func registerImportedFonts() {
        #if os(macOS)
        defer { MacMarkdownFontResolver.shared.invalidate() }
        #else
        defer { IOSMarkdownFontCache.invalidate() }
        #endif
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// Import a font file, copy to app fonts directory, register it
    @discardableResult
    static func importFont(from sourceURL: URL) -> String? {
        #if os(macOS)
        defer { MacMarkdownFontResolver.shared.invalidate() }
        #else
        defer { IOSMarkdownFontCache.invalidate() }
        #endif
        let dest = fontsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        if !FileManager.default.fileExists(atPath: dest.path) {
            do {
                try FileManager.default.copyItem(at: sourceURL, to: dest)
            } catch {
                return nil
            }
        }

        CTFontManagerRegisterFontsForURL(dest as CFURL, .process, nil)

        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(dest as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else {
            return nil
        }

        return name
    }

    /// List user-imported fonts
    static func importedFonts() -> [(fileName: String, fontName: String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var result: [(String, String)] = []
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
               let first = descriptors.first,
               let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
                let displayName = CTFontDescriptorCopyAttribute(first, kCTFontDisplayNameAttribute) as? String ?? name
                result.append((displayName, name))
            }
        }
        return result
    }

    /// Delete an imported font file by PostScript name
    static func deleteFont(named fontName: String) {
        #if os(macOS)
        defer { MacMarkdownFontResolver.shared.invalidate() }
        #else
        defer { IOSMarkdownFontCache.invalidate() }
        #endif
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor],
               let first = descriptors.first,
               let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String,
               name == fontName {
                CTFontManagerUnregisterFontsForURL(file as CFURL, .process, nil)
                try? FileManager.default.removeItem(at: file)
                return
            }
        }
    }

    /// Get a Font for the given settings
    /// B34：fallback 必须跟 `@AppStorage("fontScale")` 声明默认（1.2）对齐。
    /// 否则用户没动过设置时：assistant 走 @AppStorage 拿 1.2 → 13.5×1.2，user 文本走这里拿 1.0 → 13.5×1.0，
    /// 两边字号差 2.7pt，user 气泡看着比 AI 小一圈。
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName = UserDefaults.standard.string(forKey: "selectedFont") ?? ""
        let scale = UserDefaults.standard.double(forKey: "fontScale")
        let effectiveScale = scale > 0 ? scale : 1.2
        let scaledSize = size * effectiveScale

        if fontName.isEmpty {
            return .system(size: scaledSize, weight: weight)
        } else {
            return .custom(fontName, size: scaledSize)
        }
    }

    #if canImport(UIKit)
    /// UIKit 侧同源构造（输入框 UIKit 化，plan T1）：与 font(size:) 同一套 selectedFont/fontScale 规则，
    /// 两边必须同步改——显示与测量共用这一个入口。
    static func uiFont(size: CGFloat) -> UIFont {
        let fontName = UserDefaults.standard.string(forKey: "selectedFont") ?? ""
        let scale = UserDefaults.standard.double(forKey: "fontScale")
        let scaledSize = size * (scale > 0 ? scale : 1.2)
        if fontName.isEmpty { return .systemFont(ofSize: scaledSize) }
        return UIFont(name: fontName, size: scaledSize) ?? .systemFont(ofSize: scaledSize)
    }
    #endif
}
