import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private enum Keys {
        static let themeMode = "themeMode"
        static let selectedThemeId = "selectedThemeId"
        static let usePureBackground = "usePureBackground"
        static let themeDefinitions = "themeDefinitions"
    }

    var themeMode: AppThemeMode {
        didSet {
            guard themeMode != oldValue else { return }
            defaults.set(themeMode.rawValue, forKey: Keys.themeMode)
            touch()
        }
    }

    var selectedThemeId: String {
        didSet {
            let normalized = Self.normalizedThemeId(selectedThemeId, within: themeDefinitions)
            if normalized != selectedThemeId {
                selectedThemeId = normalized
                return
            }

            guard selectedThemeId != oldValue else { return }
            defaults.set(selectedThemeId, forKey: Keys.selectedThemeId)
            touch()
        }
    }

    var usePureBackground: Bool {
        didSet {
            guard usePureBackground != oldValue else { return }
            defaults.set(usePureBackground, forKey: Keys.usePureBackground)
            touch()
        }
    }

    var themeDefinitions: [AppThemeDefinition] {
        didSet {
            let normalized = Self.normalizedDefinitions(themeDefinitions)
            if normalized != themeDefinitions {
                themeDefinitions = normalized
                return
            }

            let normalizedThemeId = Self.normalizedThemeId(selectedThemeId, within: themeDefinitions)
            if normalizedThemeId != selectedThemeId {
                selectedThemeId = normalizedThemeId
            }

            guard themeDefinitions != oldValue else { return }
            persistDefinitions()
            touch()
        }
    }

    private(set) var systemColorScheme: ColorScheme
    private(set) var themeChangeID = UUID()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let storedDefinitions = Self.loadThemeDefinitions(from: defaults)
        self.defaults = defaults
        self.themeMode = AppThemeMode(rawValue: defaults.string(forKey: Keys.themeMode) ?? "") ?? .system
        self.usePureBackground = defaults.bool(forKey: Keys.usePureBackground)
        self.themeDefinitions = storedDefinitions
        self.selectedThemeId = Self.normalizedThemeId(
            defaults.string(forKey: Keys.selectedThemeId) ?? AppThemeDefinition.defaultTheme.id,
            within: storedDefinitions
        )
        self.systemColorScheme = Self.detectSystemColorScheme()
    }

    var preferredColorScheme: ColorScheme? {
        themeMode.preferredColorScheme
    }

    var activeScheme: ColorScheme {
        themeMode.preferredColorScheme ?? systemColorScheme
    }

    var selectedTheme: AppThemeDefinition {
        themeDefinition(id: selectedThemeId) ?? .defaultTheme
    }

    var customTheme: AppThemeDefinition {
        themeDefinition(id: AppThemeDefinition.customTheme.id) ?? .customTheme
    }

    var currentTokenSet: ThemeTokenSet {
        resolvedTokenSet(for: selectedTheme, scheme: activeScheme)
    }

    var currentBackgroundImageURL: URL? {
        backgroundImageURL(for: selectedTheme.id)
    }

    var currentBackgroundStyle: ThemeBackgroundStyle {
        backgroundStyle(for: selectedTheme.id)
    }

    func resolvedTokenSet(for scheme: ColorScheme) -> ThemeTokenSet {
        resolvedTokenSet(for: selectedTheme, scheme: scheme)
    }

    func previewTokenSet(for themeId: String, scheme: ColorScheme) -> ThemeTokenSet {
        guard let theme = themeDefinition(id: themeId) else {
            return resolvedTokenSet(for: scheme)
        }
        return resolvedTokenSet(for: theme, scheme: scheme)
    }

    func backgroundImageURL(for themeId: String) -> URL? {
        guard let fileName = themeDefinition(id: themeId)?.backgroundImageFileName else { return nil }
        return ThemeAssetStore.url(for: fileName)
    }

    func backgroundStyle(for themeId: String) -> ThemeBackgroundStyle {
        themeDefinition(id: themeId)?.resolvedBackgroundStyle ?? ThemeBackgroundStyle()
    }

    func themeDefinition(id: String) -> AppThemeDefinition? {
        themeDefinitions.first(where: { $0.id == id })
    }

    func syncSystemColorScheme(_ scheme: ColorScheme) {
        guard systemColorScheme != scheme else { return }
        systemColorScheme = scheme
        if themeMode == .system {
            touch()
        }
    }

    func selectTheme(id: String) {
        selectedThemeId = id
    }

    func updateThemeName(_ name: String, for id: String) {
        updateThemeDefinition(id: id) { theme in
            guard theme.isEditable else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            theme.name = trimmed.isEmpty ? fallbackName(for: id) : trimmed
            theme.isBuiltIn = false
        }
    }

    func replaceTokenSet(_ tokens: ThemeTokenSet, for scheme: ColorScheme, themeId: String) {
        updateThemeDefinition(id: themeId) { theme in
            guard theme.isEditable else { return }
            if scheme == .dark {
                theme.dark = tokens
            } else {
                theme.light = tokens
            }
            theme.isBuiltIn = false
        }
    }

    func restoreDefaultTokenSet(for scheme: ColorScheme, themeId: String) {
        replaceTokenSet(
            scheme == .dark ? .palaceDarkDefault : .palaceLightDefault,
            for: scheme,
            themeId: themeId
        )
    }

    func resetCustomTheme() {
        replaceThemeDefinition(.customTheme)
    }

    func copyLightIntoDarkDraft(themeId: String) {
        updateThemeDefinition(id: themeId) { theme in
            guard theme.isEditable else { return }
            theme.dark = theme.light.generatingDarkDraftFromLight()
            theme.isBuiltIn = false
        }
    }

    /// `select`：复制完要不要切成当前主题。外观页「+」/ 内置主题从当前入口复制 → 切；主题列表长按编辑内置主题 → 不切（改主题 ≠ 应用主题）。
    @discardableResult
    func saveThemeCopy(from sourceThemeId: String, name: String, select: Bool = true) -> String? {
        guard let sourceTheme = themeDefinition(id: sourceThemeId) else { return nil }

        let newThemeId = "theme-\(UUID().uuidString.lowercased())"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var backgroundImageFileName: String?

        if let sourceImage = sourceTheme.backgroundImageFileName {
            backgroundImageFileName = try? ThemeAssetStore.copyBackgroundImage(named: sourceImage, for: newThemeId)
        }

        let savedTheme = AppThemeDefinition(
            id: newThemeId,
            name: trimmedName.isEmpty ? suggestedCopyName(for: sourceTheme) : trimmedName,
            isBuiltIn: false,
            light: sourceTheme.light,
            dark: sourceTheme.dark,
            backgroundImageFileName: backgroundImageFileName,
            backgroundStyle: sourceTheme.backgroundStyle?.normalized
        )

        themeDefinitions.append(savedTheme)
        if select {
            selectedThemeId = savedTheme.id
        }
        return savedTheme.id
    }

    func deleteTheme(id: String) {
        guard let theme = themeDefinition(id: id), theme.isDeletable else { return }

        if let fileName = theme.backgroundImageFileName {
            ThemeAssetStore.removeBackgroundImage(named: fileName)
        }

        themeDefinitions.removeAll(where: { $0.id == id })
        if selectedThemeId == id {
            selectedThemeId = AppThemeDefinition.customTheme.id
        }
    }

    func setBackgroundImage(from url: URL, for themeId: String) throws {
        guard let theme = themeDefinition(id: themeId), theme.isEditable else { return }

        let previousFileName = theme.backgroundImageFileName
        let newFileName = try ThemeAssetStore.saveBackgroundImage(from: url, for: themeId)

        updateThemeDefinition(id: themeId) { mutableTheme in
            mutableTheme.backgroundImageFileName = newFileName
            mutableTheme.isBuiltIn = false
        }

        if let previousFileName, previousFileName != newFileName {
            ThemeAssetStore.removeBackgroundImage(named: previousFileName)
        }
    }

    func setBackgroundImage(data: Data, preferredExtension: String?, for themeId: String) throws {
        guard let theme = themeDefinition(id: themeId), theme.isEditable else { return }

        let previousFileName = theme.backgroundImageFileName
        let newFileName = try ThemeAssetStore.saveBackgroundImage(
            data: data,
            for: themeId,
            preferredExtension: preferredExtension
        )

        updateThemeDefinition(id: themeId) { mutableTheme in
            mutableTheme.backgroundImageFileName = newFileName
            mutableTheme.isBuiltIn = false
        }

        if let previousFileName, previousFileName != newFileName {
            ThemeAssetStore.removeBackgroundImage(named: previousFileName)
        }
    }

    func clearBackgroundImage(for themeId: String) {
        guard let theme = themeDefinition(id: themeId), theme.isEditable else { return }

        let previousFileName = theme.backgroundImageFileName
        updateThemeDefinition(id: themeId) { mutableTheme in
            mutableTheme.backgroundImageFileName = nil
            mutableTheme.isBuiltIn = false
        }

        if let previousFileName {
            ThemeAssetStore.removeBackgroundImage(named: previousFileName)
        }
    }

    func updateBackgroundOpacity(_ opacity: Double, for themeId: String) {
        updateThemeDefinition(id: themeId) { theme in
            guard theme.isEditable else { return }
            var style = theme.backgroundStyle?.normalized ?? ThemeBackgroundStyle()
            style.opacity = opacity
            theme.backgroundStyle = style.normalized
            theme.isBuiltIn = false
        }
    }

    func updateBackgroundVeil(_ veil: Double, for themeId: String) {
        updateThemeDefinition(id: themeId) { theme in
            guard theme.isEditable else { return }
            var style = theme.backgroundStyle?.normalized ?? ThemeBackgroundStyle()
            style.veil = veil
            theme.backgroundStyle = style.normalized
            theme.isBuiltIn = false
        }
    }

    func updateBackgroundOffset(x: Double? = nil, y: Double? = nil, for themeId: String) {
        updateThemeDefinition(id: themeId) { theme in
            guard theme.isEditable else { return }
            var style = theme.backgroundStyle?.normalized ?? ThemeBackgroundStyle()

            if let x {
                style.offsetX = x
            }
            if let y {
                style.offsetY = y
            }

            theme.backgroundStyle = style.normalized
            theme.isBuiltIn = false
        }
    }

    func resetBackgroundAdjustments(for themeId: String) {
        updateThemeDefinition(id: themeId) { theme in
            guard theme.isEditable else { return }
            theme.backgroundStyle = nil
            theme.isBuiltIn = false
        }
    }

    /// 整份替换背景参数（聊天背景页「撤销」回到进页快照用；nil = 默认）。
    func replaceBackgroundStyle(_ style: ThemeBackgroundStyle?, for themeId: String) {
        updateThemeDefinition(id: themeId) { theme in
            guard theme.isEditable else { return }
            theme.backgroundStyle = style?.normalized
            theme.isBuiltIn = false
        }
    }

    private func resolvedTokenSet(for theme: AppThemeDefinition, scheme: ColorScheme) -> ThemeTokenSet {
        var base = theme.tokens(for: scheme)
        if usePureBackground {
            base = base.applyingPureBackground(for: scheme)
        }
        // 壁纸下自动半透明（让气泡融进壁纸）。UserDefaults 的 AppStorage 兜底逻辑：
        // key 不存在时 UserDefaults.bool 返回 false，所以取反表示"默认开"；
        // 用户显式关掉时 key == true，这里就跳过强制透明，完全听选色。
        let autoTransparentOff = UserDefaults.standard.bool(forKey: "disableAutoTransparentBubblesOnWallpaper")
        if theme.hasBackgroundImage && !autoTransparentOff {
            base = base.applyingBackgroundImageSurfaceStyle(for: scheme)
        }
        return base
    }

    private func replaceThemeDefinition(_ theme: AppThemeDefinition) {
        guard let index = themeDefinitions.firstIndex(where: { $0.id == theme.id }) else { return }
        if let existingFileName = themeDefinitions[index].backgroundImageFileName,
           existingFileName != theme.backgroundImageFileName {
            ThemeAssetStore.removeBackgroundImage(named: existingFileName)
        }
        themeDefinitions[index] = theme
    }

    private func updateThemeDefinition(id: String, transform: (inout AppThemeDefinition) -> Void) {
        guard let index = themeDefinitions.firstIndex(where: { $0.id == id }) else { return }
        var updated = themeDefinitions[index]
        transform(&updated)
        themeDefinitions[index] = updated
    }

    private func persistDefinitions() {
        do {
            let data = try JSONEncoder().encode(themeDefinitions)
            defaults.set(data, forKey: Keys.themeDefinitions)
        } catch {
            // 落盘失败不静默吞（B22 案后保留的防线，面包屑给开发者调试用）
            BreadcrumbLog.shared.add("🎨⚠️", "主题保存失败: \(error.localizedDescription)")
        }
    }

    private func touch() {
        themeChangeID = UUID()
    }

    /// 外部修改影响 resolvedTokenSet 的标志（如 UserDefaults 开关）后主动触发 SwiftUI 重算。
    func notifyThemeChange() {
        touch()
    }

    private func fallbackName(for id: String) -> String {
        id == AppThemeDefinition.customTheme.id ? "自定义主题" : "新主题"
    }

    private func suggestedCopyName(for theme: AppThemeDefinition) -> String {
        if theme.isCustomDraft {
            return "我的主题"
        }
        return "\(theme.name) 副本"
    }

    private static func loadThemeDefinitions(from defaults: UserDefaults) -> [AppThemeDefinition] {
        guard let data = defaults.data(forKey: Keys.themeDefinitions) else {
            return normalizedDefinitions(AppThemeDefinition.seedThemes)
        }

        do {
            return normalizedDefinitions(try JSONDecoder().decode([AppThemeDefinition].self, from: data))
        } catch {
            // 有数据但解不开 = 数据损坏，落痕后才回种子（B22 案后保留的防线）
            BreadcrumbLog.shared.add("🎨⚠️", "主题数据解码失败(\(data.count)B): \(error.localizedDescription) → 回退默认主题")
            return normalizedDefinitions(AppThemeDefinition.seedThemes)
        }
    }

    private static func normalizedThemeId(_ id: String, within definitions: [AppThemeDefinition]) -> String {
        definitions.contains(where: { $0.id == id }) ? id : AppThemeDefinition.defaultTheme.id
    }

    private static func normalizedDefinitions(_ definitions: [AppThemeDefinition]) -> [AppThemeDefinition] {
        var lookup: [String: AppThemeDefinition] = [:]
        for definition in definitions {
            lookup[definition.id] = definition
        }

        lookup[AppThemeDefinition.defaultTheme.id] = .defaultTheme

        if let customTheme = lookup[AppThemeDefinition.customTheme.id] {
            lookup[AppThemeDefinition.customTheme.id] = AppThemeDefinition(
                id: customTheme.id,
                name: customTheme.name.isEmpty ? "自定义主题" : customTheme.name,
                isBuiltIn: false,
                light: customTheme.light,
                dark: customTheme.dark,
                backgroundImageFileName: customTheme.backgroundImageFileName,
                backgroundStyle: customTheme.backgroundStyle?.normalized
            )
        } else {
            lookup[AppThemeDefinition.customTheme.id] = .customTheme
        }

        var ordered: [AppThemeDefinition] = []
        if let defaultTheme = lookup.removeValue(forKey: AppThemeDefinition.defaultTheme.id) {
            ordered.append(defaultTheme)
        }
        if let customTheme = lookup.removeValue(forKey: AppThemeDefinition.customTheme.id) {
            ordered.append(customTheme)
        }
        ordered.append(contentsOf: lookup.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending })
        return ordered
    }

    private static func detectSystemColorScheme() -> ColorScheme {
        #if os(macOS)
        let appearance = NSApp?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
        #else
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #endif
    }
}
