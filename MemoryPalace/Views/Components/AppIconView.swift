import SwiftUI

// MARK: - 尺寸档
//
// scout §4.2 盘出六档语境（7-10 / 11-13 / 14-16 / 18-20 / 22-26 / 28-34pt）；
// 自定义 asset 不像 SF Symbol 能靠 .font(size:) 自适应，必须显式 frame，
// 否则 16 家 logo 会因 viewBox 留白差异忽大忽小。这里取中给三档，
// 现存渲染点要贴原密度时直接传 CGFloat（如 macOS 设置 tab 16pt）。

enum AppIconSize {
    /// 组头尾标、chip 内小标（对应 scout 11-13 档）
    static let mini: CGFloat = 12
    /// 设置根列表、选提供商菜单行、搜索结果行（对应 14-16 / 18-20 档之间）
    static let list: CGFloat = 17
    /// 主身份位、空态（对应 22-26 档）
    static let identity: CGFloat = 23
}

// MARK: - 统一图标入口

/// 图标统一入口：名字带 `ri-` 前缀走 Assets.xcassets 的 Remix / simple-icons template 资产，
/// 否则按 SF Symbol 名渲染。
///
/// 前缀分流是为了不动数据结构：三个字符串图标真相源（设置根列表 `settingsButton(icon:)`、
/// 设置搜索 `SettingsSearchEntry.systemImage`、右栏 `RightPanelTool.icon`）现在都存 SF name 字符串，
/// 换 icon 只需把字符串换成 `ri-*`，不用给它们加类型。
///
/// 资产全部是单色 template（`scripts/gen-icon-assets.sh` 写的 catalog 属性），
/// tint 跟 Theme token 走，不引品牌原色。
struct AppIconView: View {
    let name: String
    var size: CGFloat = AppIconSize.list
    /// nil = 继承外部 foregroundColor（渲染点已有自己的 tint 语法时传 nil）
    var tint: Color? = Theme.textSecondary
    /// 只对 SF Symbol 分支生效（资产是固定笔画）。留着是为了让现存渲染点原样保形。
    var weight: Font.Weight = .regular
    /// 传了才挂 VoiceOver 标签（provider logo 报品牌名）；纯装饰位留 nil 保持原行为
    var label: String? = nil
    /// 右栏工具图标位传 `tool.id`：Debug 包里该工具有本地默认图（`LocalDefaultIcon`）时优先画它
    var toolID: String? = nil

    /// 字符串图标真相源的分流判据
    static func isAssetName(_ name: String) -> Bool { name.hasPrefix("ri-") || name.hasPrefix("xiaoya-") }

    /// 光学补偿（粟粟 09-01：「新图标更小」）：SF Symbol 的 `.font(size:)` 是字体尺寸，
    /// 字形经常撑出这个数；asset 却被 frame 硬框住，且 Remix 24×24 viewBox 里图形自带边距。
    /// 同数值下 asset 视觉明显偏小 → asset 分支的 frame 统一放大此系数（真机/模拟器同屏比对校准值）。
    static let assetOpticalScale: CGFloat = 1.25

    /// 墨量补偿（粟粟 09-02：「新图标描边稍粗一丢丢」）：Remix 线条在 24 网格里比
    /// SF regular 笔画粗约两成，路径是烘焙好的填充改不了线宽——用透明度做光学减重
    /// （细线深色 ≈ 粗线浅色的等重原理），只作用于 asset 分支，不动大小。
    static let assetInkCompensation: Double = 0.86

    var body: some View {
        icon
            .modifier(AccessibilityLabelIfPresent(label: label))
    }

    @ViewBuilder
    private var icon: some View {
        #if DEBUG
        if let local = LocalDefaultIcon.image(for: toolID) {
            let side = size * Self.assetOpticalScale
            local.resizable().scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.23, style: .continuous))
                .frame(width: size, height: size)
        } else {
            glyph
        }
        #else
        glyph
        #endif
    }

    @ViewBuilder
    private var glyph: some View {
        if AppIconView.isAssetName(name) {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * Self.assetOpticalScale, height: size * Self.assetOpticalScale)
                // 占位仍按名义 size 参与布局，放大的部分向四周溢出——
                // 不这样做的话行高/列宽会跟着涨，跟旧 SF 行对不齐
                .frame(width: size, height: size)
                .foregroundColor(tint)
                .opacity(Self.assetInkCompensation)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .foregroundColor(tint)
        }
    }
}

#if DEBUG
/// 仓库外的本地默认图标（版权图，绝不进 git）：project.yml 的 Debug-only 构建脚本
/// `scripts/copy-local-debug-icon.sh` 在本机有 `~/.mp-local-assets/` 源图时拷进包，没有就不拷 → 这里 nil，各渲染点回落 SF。
/// 优先级：Page2「更换图标」自定义 > 本地默认图 > `RightPanelTool.icon`。
enum LocalDefaultIcon {
    private static let images: [String: Image] = {
        var map: [String: Image] = [:]
        let resources: [String: String] = [:]
        for (toolID, resource) in resources {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "png") else { continue }
            #if os(macOS)
            if let image = NSImage(contentsOf: url) { map[toolID] = Image(nsImage: image) }
            #else
            if let image = UIImage(contentsOfFile: url.path) { map[toolID] = Image(uiImage: image) }
            #endif
        }
        return map
    }()

    static func image(for toolID: String?) -> Image? {
        toolID.flatMap { images[$0] }
    }
}
#endif

private struct AccessibilityLabelIfPresent: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(Text(label))
        } else {
            content
        }
    }
}

// MARK: - Provider 品牌图标

/// presetId → 品牌资产的**纯派生**映射。
///
/// 硬红线：不碰 API 卡片逻辑——`APIProvider` / `APICredential` 不加字段，
/// `CredentialEmoji` 池和迁移代码零改动。emoji 仍是「这张 key 卡」的身份（可编辑、全局唯一），
/// logo 只是「这张卡连的是哪家」的品牌派生显示，两者并存。
enum ProviderIcon {
    /// 14 家有开源品牌图的预设。groq / siliconflow / doubao 全网开源库都没有，走 monogram 兜底。
    static let assetByPresetId: [String: String] = {
        var map: [String: String] = [
            "chatgpt-oauth": "ri-openai",
            "openai": "ri-openai",
            "codex-bridge": "ri-openai",
            "anthropic": "ri-anthropic",
            "claude-p": "ri-claude",
            "cc-bridge": "ri-claude",
            "gemini": "ri-gemini",
            "deepseek": "ri-deepseek",
            "xai": "ri-grok-ai",
            "dashscope": "ri-qwen-ai",
            "zhipu": "ri-zhipu-ai",
            "openrouter": "ri-openrouter",
            "moonshot": "ri-moonshotai",
            "ollama": "ri-ollama",
        ]
        return map
    }()

    /// 有品牌图返回 asset 名；没有（含自定义卡 presetId == nil）返回 nil，由 monogram 接手。
    static func assetName(presetId: String?) -> String? {
        guard let presetId else { return nil }
        return assetByPresetId[presetId]
    }

    /// 兜底首字：预设走预设名（Groq→G / SiliconFlow→S / 豆包→豆），
    /// 自定义卡走传进来的昵称首字——不然同一家不同昵称的卡会得到不同字母。
    static func monogram(presetId: String?, fallbackName: String) -> String {
        if let presetId, let preset = APIProvider.presets.first(where: { $0.id == presetId }) {
            return firstGlyph(preset.name)
        }
        return firstGlyph(fallbackName)
    }

    private static func firstGlyph(_ raw: String) -> String {
        guard let c = raw.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "?" }
        return c.isASCII ? String(c).uppercased() : String(c)
    }
}

/// 无品牌图时的首字母圆片（不抠官网 SVG，不用弱关联的通用图标）。
struct ProviderMonogram: View {
    let letter: String
    var size: CGFloat = AppIconSize.list
    var tint: Color = Theme.textSecondary

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.56, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.branchIndicator.opacity(0.18)))
    }
}

/// Provider 品牌位统一视图：有 logo 用 logo，没有落 monogram 圆片。
struct ProviderIconView: View {
    /// 卡选的内置预设 id；自定义卡是 nil
    let presetId: String?
    /// monogram 兜底取首字 + VoiceOver 报名（传卡昵称或预设名）
    let displayName: String
    var size: CGFloat = AppIconSize.list
    var tint: Color = Theme.textSecondary

    var body: some View {
        if let asset = ProviderIcon.assetName(presetId: presetId) {
            AppIconView(name: asset, size: size, tint: tint, label: displayName)
        } else {
            ProviderMonogram(
                letter: ProviderIcon.monogram(presetId: presetId, fallbackName: displayName),
                size: size,
                tint: tint
            )
            .accessibilityLabel(Text(displayName))
        }
    }
}
