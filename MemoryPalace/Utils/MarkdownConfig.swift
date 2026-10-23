// 流式重写 Phase 1：本文件的取值来自当年 `MarkdownTheme.memoryPalace`（MarkdownUI v2.4.1）的一次映射。
// ms0911 起双平台（mac 聊天正文同走 fork）；**2026-09-16 MarkdownUI 已完全退役**（第二刀收掉最后 7 个 sheet，
// 主题文件与 SPM 包一并删除）——下面提到 MarkdownUI 的地方都是历史来源说明，仓里已经没有那个库了。
//
// 决策（见 docs/plan-streaming-rewrite-phase1-config.md + review-streaming-rewrite-phase1-codex.md）：
// - heading 用 bold/semibold PlatformFont 作为 normal（库 Heading+.swift 用 .normal，不读 .bold）
// - citationConfig 必须 isEnabled=false（默认 .default 会误吃 MP 现有 [xxx](url) 渲成 pill）
// - 只用 raw init，不用 withXxx builders（builder reset citationConfig 是 bug）
// - 自定义字体变体用 CTFontDescriptor symbolic traits family matching（不是 "-Bold" 后缀）
// - preferredLineHeight: nil（库 ParagraphUIView 根本不读这字段）
//
// 接受的视觉降级（D8 + codex 补充）：blockquote chrome / unordered bullet 色 /
// inline code dotted underline 阴影 / table 交替行 / thematicBreak 样式 /
// code block 圆角 20pt + bundled HighlightSwift CSS / HTMLArtifactCard 降级——以上两端同。
// 块距/行距分端：iOS 吃库默认 block spacing 30 / paragraph lineSpacing 5（不可控）；
// mac 由 memoryPalace 的 lineSpacingScale/paragraphSpacingScale 参数换算覆盖（ms0911 R8 B3）。
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import SwiftStreamingMarkdown

extension MarkdownRenderConfig {

    /// MP 暖奶白 + 浅灰薄荷主题映射。
    /// - parameter fontName: PostScript 字体名（FontManager.selectedFont）。空 → 系统字体。
    /// - parameter scale: 字号 scale（FontManager.fontScale，默认 1.2）。
    /// - parameter animated: 逐词淡入（ParagraphUIView.animatedByWord）。只有流式路径传 true——
    ///   静态渲染开它会让历史消息滚动重建时整段 alpha 淡入闪变（ParagraphView.makeUIView）。
    /// - parameter lineSpacingScale / paragraphSpacingScale: ms0911 R8 B3 排版滑杆换算（mac 传，iOS 永 nil 吃库默认）。
    ///   R9b 走查 4 起口径：默认滑杆值 = iOS 数值，滑杆按比例缩放——
    ///   行距 = 5 × s/1.45、块距 = 30 × s/1.65（5/30 是 fork BlockView iOS 分支写死值，1.45/1.65 是滑杆默认）。
    /// - parameter contextMenu: 选段浮条自定义项（R2-4b 正文划词收生词；nil = 只有系统项）
    /// - parameter textHighlights: 持久化划线层（fork patch 7，聊天批注）
    /// - parameter mergesTextRuns: 连续段落 / 标题并进一个文字视图（跨段选择，plan-cross-paragraph-selection）。
    ///   只有长按浮层预览里的定稿正文传 true（ChatMarkdownView 读 `\.chatMergesTextRuns` 且 `!animated`）；
    ///   列表 / 流式路径不传，保持一块一个视图（粟粟 10-03：Air 列表合并就卡）。
    static func memoryPalace(fontName: String = "", scale: CGFloat = 1.2, animated: Bool = false,
                             contextMenu: TextContextMenu? = nil,
                             textHighlights: [TextHighlight] = [],
                             lineSpacingScale: Double? = nil,
                             paragraphSpacingScale: Double? = nil,
                             textColor: Color = Theme.textPrimary,
                             mergesTextRuns: Bool = false) -> MarkdownRenderConfig {
        let bodySize: CGFloat = 13.5 * scale
        let codeSize: CGFloat = bodySize * 0.88
        let blockQuoteSize: CGFloat = 13 * scale
        let h1Size: CGFloat = 20 * scale
        let h2Size: CGFloat = 17 * scale
        let h3Size: CGFloat = 15 * scale

        // 正文色：调用方按角色传（`ChatTextRole`），非聊天调用方不传 = 主文字。
        // 引用块 / 链接 / 行内码底色不跟它走，仍各自取 token。
        let bodyTextUI = PlatformColor(textColor)
        let textSecondaryUI = PlatformColor(Theme.textSecondary)
        let accentUI = PlatformColor(Theme.accent)
        let branchUI = PlatformColor(Theme.branchIndicator)
        let mainBgUI = PlatformColor(Theme.mainBg)

        // body paragraph：regular weight，bold/italic 变体由 mkTextFonts 找 family
        let paragraphFonts = mkTextFonts(size: bodySize, fontName: fontName, baseWeight: .regular)

        // [codex#6] heading 必须把 bold/semibold PlatformFont 作为 normal 传——库 Heading+.swift 用 .normal 不读 .bold
        let h1Fonts = mkTextFonts(size: h1Size, fontName: fontName, baseWeight: .bold)
        let h2Fonts = mkTextFonts(size: h2Size, fontName: fontName, baseWeight: .semibold)
        let h3Fonts = mkTextFonts(size: h3Size, fontName: fontName, baseWeight: .semibold)

        // blockquote text — secondary 色
        let blockQuoteFonts = mkTextFonts(size: blockQuoteSize, fontName: fontName, baseWeight: .regular)

        // inline code — monospaced
        let codeFont = PlatformFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)

        // link — 跟 body 同字体
        let linkFont = paragraphFonts.normal

        return MarkdownRenderConfig(
            // B6 刀1：流式路径（StreamingTextView / SimpleStreamingBody）传 animated: true 吃逐词淡入，
            // 静态渲染保持 false（原 [codex#9] 留给 Phase 4 的账，2026-07-08 结清）
            shouldAnimateText: animated,

            blockQuoteStyle: MarkdownTextStyle(
                textFonts: blockQuoteFonts,
                textColor: textSecondaryUI
            ),

            headingStyle: MarkdownHeadingTextStyle(
                h1Font: h1Fonts,
                h2Font: h2Fonts,
                h3Font: h3Fonts,
                h4Font: h3Fonts,    // h4-h6 复用 h3 semibold
                h5Font: h3Fonts,
                h6Font: h3Fonts,
                textColor: bodyTextUI
            ),

            orderedListStyle: MarkdownTextStyle(
                textFonts: paragraphFonts,
                textColor: bodyTextUI
            ),

            paragraphStyle: MarkdownTextStyle(
                textFonts: paragraphFonts,
                textColor: bodyTextUI
            ),

            tableStyle: MarkdownTableTextStyle(
                textFonts: mkTextFonts(size: blockQuoteSize, fontName: fontName, baseWeight: .regular),
                headerTextColor: bodyTextUI,
                regularTextColor: bodyTextUI,
                headerBackgroundColor: accentUI.withAlphaComponent(0.38),
                borderColor: accentUI.withAlphaComponent(0.9),
                actionButtonColor: branchUI
            ),

            inlineStyle: MarkdownInlineTextStyle(
                boldTextColor: bodyTextUI,
                linkTextFont: linkFont,
                linkTextColor: branchUI,
                codeTextFont: codeFont,
                codeTextColor: bodyTextUI,
                codeBackgroundColor: accentUI.withAlphaComponent(0.72),
                // [codex#26] 库强制 dotted underline；.clear 让它透明，attributed string 仍有 underline（接受）
                codeUnderlineColor: .clear
            ),

            // [codex#3] Phase 8 接长按 menu，现在 nil 用系统 selection menu
            textContextMenu: contextMenu,
            textHighlights: textHighlights,

            // [codex#17] 必须 isEnabled=false 关掉，否则默认 .default 会误吃 MP 现有 [xxx](url) 渲成 pill
            // mainBg = 暖奶白让 chip 在暖背景下不刺眼（即使 isEnabled=false 仍需要传 font/colors，库 init 要求）
            citationConfig: CitationConfig(
                isEnabled: false,
                coder: .default,
                font: PlatformFont.systemFont(ofSize: codeSize, weight: .regular),
                textColor: bodyTextUI,
                backgroundColor: mainBgUI
            ),

            // R9b 走查 4：换算对齐 iOS——默认滑杆 = iOS 数值，滑杆按比例缩放（5/30 = fork BlockView
            // iOS 分支写死值；1.45/1.65 = 滑杆默认）。旧公式对齐的是 MarkdownUI（默认 9.87pt/19.8pt，
            // mac 行更松段更挤正好反了）。闭包体 iOS 永不执行（iOS 传 nil）——iOS 行为零变化。
            blockSpacing: paragraphSpacingScale.map { s in
                let iOSBlockSpacing = 30.0      // fork BlockView iOS 分支写死的块距
                let sliderDefault = 1.65        // 「外观 › 排版」段落间距滑杆默认（AppStorage 同名键）
                return CGFloat(iOSBlockSpacing * s / sliderDefault)
            },
            paragraphLineSpacing: lineSpacingScale.map { s in
                let iOSParagraphLineSpacing = 5.0   // fork BlockView iOS 分支写死的行距
                let sliderDefault = 1.45            // 行间距滑杆默认
                return CGFloat(iOSParagraphLineSpacing * s / sliderDefault)
            },
            mergesTextRuns: mergesTextRuns
        )
    }

    /// MP 主题构造 TextFonts。weight-aware（heading bold 作为 normal 传给库）。
    ///
    /// - parameter size: 字号
    /// - parameter fontName: PostScript 字体名；空 → 系统字体
    /// - parameter baseWeight: normal 字段的 weight（heading 用 .bold/.semibold）
    @inline(__always)
    private static func mkTextFonts(
        size: CGFloat,
        fontName: String,
        baseWeight: PlatformFont.Weight
    ) -> TextFonts {
        #if os(macOS)
        return MacMarkdownFontResolver.shared.fonts(name: fontName, size: size, weight: baseWeight)
        #else
        return IOSMarkdownFontCache.fonts(name: fontName, size: size, weight: baseWeight) {
            makeTextFonts(size: size, fontName: fontName, baseWeight: baseWeight)
        }
        #endif
    }

    #if os(iOS)
    private static func makeTextFonts(size: CGFloat, fontName: String, baseWeight: PlatformFont.Weight) -> TextFonts {
        let normal: PlatformFont
        let bold: PlatformFont?
        let italic: PlatformFont?
        let boldItalic: PlatformFont?

        if fontName.isEmpty {
            // 系统字体：weight 用 .systemFont(ofSize:weight:) 控制
            normal = .systemFont(ofSize: size, weight: baseWeight)
            // base 已经 bold/semibold 时，bold 字段提供更重的 weight（.bold）
            let boldWeight: PlatformFont.Weight = (baseWeight == .regular) ? .semibold : .bold
            bold = .systemFont(ofSize: size, weight: boldWeight)
            italic = italicVariant(of: normal, size: size)
            boldItalic = bold.flatMap { italicVariant(of: $0, size: size) }
        } else {
            // 自定义字体：用 CTFontDescriptor symbolic traits family matching 找变体
            // [codex#24] 不能用 "\(fontName)-Bold" 后缀——PostScript 名是 LXGWWenKai-Regular，
            // 加 -Bold 变成 LXGWWenKai-Regular-Bold 不存在
            let baseDescriptor = UIFontDescriptor(name: fontName, size: size)
            normal = PlatformFont(descriptor: baseDescriptor, size: size)
            bold = findVariant(of: baseDescriptor, size: size, addTraits: .traitBold)
            italic = findVariant(of: baseDescriptor, size: size, addTraits: .traitItalic)
            boldItalic = findVariant(
                of: baseDescriptor,
                size: size,
                addTraits: [.traitBold, .traitItalic]
            )
        }

        return TextFonts(
            normal: normal,
            italic: italic,
            bold: bold,
            boldItalic: boldItalic,
            preferredLetterSpacing: nil,
            // [codex#22] ParagraphUIView 根本不读 preferredLineHeight；写也没用
            preferredLineHeight: nil
        )
    }
    #endif

    #if os(iOS)
    /// 给系统字体加 italic trait（自定义字体走 findVariant）。
    private static func italicVariant(of font: PlatformFont, size: CGFloat) -> PlatformFont? {
        guard let desc = font.fontDescriptor.withSymbolicTraits(.traitItalic) else { return nil }
        return PlatformFont(descriptor: desc, size: size)
    }

    /// 自定义字体 family matching：找 base + 指定 traits 的变体。
    /// 找不到（return nil）让库 fall back normal——视觉看不到 bold/italic 区别。
    private static func findVariant(
        of base: UIFontDescriptor,
        size: CGFloat,
        addTraits: UIFontDescriptor.SymbolicTraits
    ) -> PlatformFont? {
        guard let desc = base.withSymbolicTraits(addTraits) else { return nil }
        let font = PlatformFont(descriptor: desc, size: size)
        // 验证：返回的 PostScript 名跟 base 不同 = 真的找到了 variant；
        // 否则系统找不到给 fall back 同 base，返 nil 让库自己 fall back
        return font.fontName != PlatformFont(descriptor: base, size: size).fontName ? font : nil
    }
    #endif
}

#if os(iOS)
/// perf-flash：字体变体匹配是资源操作，不是每条消息每次 body 的渲染工作（同 mac `MacMarkdownFontResolver`）。
/// 按 名字 × 字号 × 字重 缓存不可变字体组；颜色 / 划线 / 菜单仍逐次构造。字体注册 / 导入 / 删除时清空。
enum IOSMarkdownFontCache {
    private final class Entry {
        let fonts: TextFonts
        init(_ fonts: TextFonts) { self.fonts = fonts }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 128
        return c
    }()

    static func fonts(name: String, size: CGFloat, weight: UIFont.Weight, make: () -> TextFonts) -> TextFonts {
        let key = "\(name)|\(size)|\(weight.rawValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit.fonts }
        let fonts = make()
        cache.setObject(Entry(fonts), forKey: key)
        return fonts
    }

    static func invalidate() { cache.removeAllObjects() }
}
#endif
