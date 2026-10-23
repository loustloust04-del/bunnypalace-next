import XCTest
import AppKit
@testable import 记忆花园

/// icon 体系（plan-icons §二）：presetId → 品牌资产纯派生映射 / monogram 兜底 / 资产真的在 catalog 里。
final class AppIconTests: XCTestCase {

    /// C 级替换用到的通用资产（`SettingsSearch` / `RightPanelPlugin` / 设置根列表消费）
    private let genericAssets = [
        "ri-robot-2", "ri-emoji-sticker", "ri-sword", "ri-stack", "ri-compass-3",
    ]

    // MARK: 前缀分流

    func testIsAssetNameMatchesRiAndXiaoyaPrefix() {
        XCTAssertTrue(AppIconView.isAssetName("ri-openai"))
        XCTAssertTrue(AppIconView.isAssetName("ri-compass-3"))
        XCTAssertTrue(AppIconView.isAssetName("xiaoya-cameo"))
        // SF Symbol 名一个都不能被误判成资产，否则渲染点会去 catalog 找不存在的图
        XCTAssertFalse(AppIconView.isAssetName("gearshape"))
        XCTAssertFalse(AppIconView.isAssetName("chevron.right"))
        XCTAssertFalse(AppIconView.isAssetName("rectangle.grid.2x2"))
        XCTAssertFalse(AppIconView.isAssetName(""))
    }

    // MARK: 映射全覆盖

    /// 17 家预设一个不漏：要么有品牌图，要么有非空 monogram。
    func testEveryPresetResolvesToIconOrMonogram() {
        XCTAssertEqual(APIProvider.presets.count, 18, "预设数量变了，映射表要跟着核一遍（mac 上含本机模型）")
        for preset in APIProvider.presets {
            if let asset = ProviderIcon.assetName(presetId: preset.id) {
                XCTAssertTrue(asset.hasPrefix("ri-"), "\(preset.id) 映射到了非资产名 \(asset)")
            } else {
                let mono = ProviderIcon.monogram(presetId: preset.id, fallbackName: preset.name)
                XCTAssertFalse(mono.isEmpty, "\(preset.id) 既没 logo 也没 monogram")
                XCTAssertNotEqual(mono, "?", "\(preset.id) 的 monogram 落到了未知兜底")
            }
        }
    }

    func testBrandMappingIsExact() {
        var expected: [String: String] = [
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
        XCTAssertEqual(ProviderIcon.assetByPresetId, expected)
        // 映射表里的 id 必须都是真预设，不能是手抖拼错的字符串
        let presetIds = Set(APIProvider.presets.map(\.id))
        for id in ProviderIcon.assetByPresetId.keys {
            XCTAssertTrue(presetIds.contains(id), "映射表里的 \(id) 不是任何预设的 id")
        }
    }

    /// 三家无开源图标的走 monogram，不许偷偷映射到弱关联的通用图
    func testGapProvidersFallBackToMonogram() {
        for id in ["groq", "siliconflow", "doubao"] {
            XCTAssertNil(ProviderIcon.assetName(presetId: id), "\(id) 不该有品牌资产")
        }
        XCTAssertEqual(ProviderIcon.monogram(presetId: "groq", fallbackName: ""), "G")
        XCTAssertEqual(ProviderIcon.monogram(presetId: "siliconflow", fallbackName: ""), "S")
        XCTAssertEqual(ProviderIcon.monogram(presetId: "doubao", fallbackName: ""), "豆")
    }

    /// 预设的 monogram 认预设名，不认卡昵称——同一家不同昵称的卡不能出现不同字母
    func testPresetMonogramIgnoresNickname() {
        XCTAssertEqual(ProviderIcon.monogram(presetId: "groq", fallbackName: "我的备用卡"), "G")
    }

    // MARK: 兜底

    func testCustomCredentialUsesNicknameInitial() {
        XCTAssertNil(ProviderIcon.assetName(presetId: nil))
        XCTAssertEqual(ProviderIcon.monogram(presetId: nil, fallbackName: "midjourney"), "M")
        XCTAssertEqual(ProviderIcon.monogram(presetId: nil, fallbackName: "  中转站"), "中")
        XCTAssertEqual(ProviderIcon.monogram(presetId: nil, fallbackName: ""), "?")
        XCTAssertEqual(ProviderIcon.monogram(presetId: nil, fallbackName: "   "), "?")
    }

    /// 未知 presetId（旧存档带着已下架的预设 id）不能崩，落昵称首字
    func testUnknownPresetIdFallsBackToNickname() {
        XCTAssertNil(ProviderIcon.assetName(presetId: "some-removed-preset"))
        XCTAssertEqual(ProviderIcon.monogram(presetId: "some-removed-preset", fallbackName: "旧卡"), "旧")
    }

    // MARK: 资产真的在 catalog 里

    /// 映射表和 C 级清单里的每个 `ri-*` 都必须能从 asset catalog 加载出来。
    /// 拼错名字 / 漏跑 `scripts/gen-icon-assets.sh` 时，UI 上只是空白，靠这条测出来。
    func testAllReferencedAssetsExistInCatalog() {
        let names = Set(ProviderIcon.assetByPresetId.values).union(genericAssets)
        XCTAssertEqual(names.count, 16, "资产总数与 plan §一 的 16 个对不上")
        for name in names.sorted() {
            XCTAssertNotNil(NSImage(named: name), "asset catalog 里没有 \(name)")
        }
    }

    /// 两个字符串图标真相源里写的 `ri-*` 必须都能加载：
    /// 设置搜索 registry 和右栏 catalog 都是手写字符串，拼错了 UI 上只是空白。
    func testStringRegistriesReferenceExistingAssets() {
        var checked = 0
        for entry in SettingsSearchEntry.all where AppIconView.isAssetName(entry.systemImage) {
            XCTAssertNotNil(NSImage(named: entry.systemImage),
                            "设置搜索 \(entry.id) 引用了不存在的资产 \(entry.systemImage)")
            checked += 1
        }
        for tool in RightPanelToolManager.builtInTools where AppIconView.isAssetName(tool.icon) {
            XCTAssertNotNil(NSImage(named: tool.icon),
                            "右栏工具 \(tool.id) 引用了不存在的资产 \(tool.icon)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "两个 registry 一个 ri- 都没有，C 级替换没落地？")
    }

    /// macOS 设置 tab bar 的 icon 直接查这张表，缺一条那个 tab 就秃一个（旁边都有图）
    func testEverySettingsTabHasIcon() {
        for tab in SettingsView.SettingsTab.allCases {
            XCTAssertNotNil(SettingsSearchEntry.iconByTab[tab], "\(tab.rawValue) 没有 icon")
        }
    }

    /// 小芽 v2：椭圆肖像（dock / 设置 / Page2 图标）template 随主题染色；
    /// 九张剪纸表情是原色（自带奶白纸垫，亮暗主题都能看，plan §3.6）
    func testXiaoyaAssetsExistWithRightRendering() {
        guard let cameo = NSImage(named: "xiaoya-cameo") else { return XCTFail("没有 xiaoya-cameo") }
        XCTAssertTrue(cameo.isTemplate)
        XCTAssertEqual(XiaoyaMood.allCases.count, 9)
        for mood in XiaoyaMood.allCases {
            guard let image = NSImage(named: mood.assetName) else {
                XCTFail("asset catalog 里没有 \(mood.assetName)")
                continue
            }
            XCTAssertFalse(image.isTemplate, "\(mood.assetName) 应该原色渲染")
        }
        XCTAssertEqual(RightPanelToolManager.builtInTools.first { $0.id == "xiaoya" }?.icon, "xiaoya-cameo")
        XCTAssertEqual(SettingsSearchEntry.iconByTab[.xiaoya], "xiaoya-cameo")
    }

    /// template 渲染意图丢了的话，品牌图会以原色出现，跟 Theme 配色打架
    func testAssetsAreTemplateRendered() {
        for name in Set(ProviderIcon.assetByPresetId.values).union(genericAssets).sorted() {
            guard let image = NSImage(named: name) else {
                XCTFail("asset catalog 里没有 \(name)")
                continue
            }
            XCTAssertTrue(image.isTemplate, "\(name) 不是 template，会带原色渲染")
        }
    }
}
