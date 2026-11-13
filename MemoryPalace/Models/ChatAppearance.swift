import Foundation

/// 「聊天时的样子」按楼层（atrium P3④）。字段全可选：合成 Codable 对非可选字段缺键会让整份楼层列表解不开，
/// 默认值放读侧（同 `Profile.storedVoice*`）。④a 聊天主题；④b 字体字号 / 气泡几何 / 行距段距。
struct ChatAppearance: Codable, Hashable {
    /// 聊天主题。nil = 跟随界面主题（宫殿默认）；指向已删 / 不存在的主题时读侧回落界面主题
    var themeId: String?

    // ④b：nil = 读侧默认值（各处 `@AppStorage` 的默认值）
    var fontName: String?
    var fontScale: Double?
    var bubbleModeCornerRadius: Double?
    var bubbleCornerRadius: Double?
    var bubblePaddingH: Double?
    var bubblePaddingV: Double?
    var bubbleSpacing: Double?
    var lineSpacingScale: Double?
    var paragraphSpacingScale: Double?

    /// 老全局键已抄进各层（④b 迁移）。没落之前镜像不碰下面 9 个键，老键原样继续用
    static let migratedKey = "chatAppearance.perFloorMigrated"
    static let fontKey = "selectedFont"

    /// 数值项 ↔ 老全局键（~40 处读者都是 `@AppStorage` 这些键，不改）+ 读侧默认值
    struct Metric {
        let key: String
        let path: WritableKeyPath<ChatAppearance, Double?>
        let defaultValue: Double
    }

    static let fontScaleMetric = Metric(key: "fontScale", path: \.fontScale, defaultValue: 1.2)
    static let bubbleModeCornerMetric = Metric(key: "bubbleModeCornerRadius", path: \.bubbleModeCornerRadius, defaultValue: 20)
    static let bubbleCornerMetric = Metric(key: "bubbleCornerRadius", path: \.bubbleCornerRadius, defaultValue: 16)
    static let bubblePaddingHMetric = Metric(key: "bubblePaddingH", path: \.bubblePaddingH, defaultValue: 18)
    static let bubblePaddingVMetric = Metric(key: "bubblePaddingV", path: \.bubblePaddingV, defaultValue: 15)
    static let bubbleSpacingMetric = Metric(key: "bubbleSpacing", path: \.bubbleSpacing, defaultValue: 31)
    static let lineSpacingMetric = Metric(key: "lineSpacingScale", path: \.lineSpacingScale, defaultValue: 1.45)
    static let paragraphSpacingMetric = Metric(key: "paragraphSpacingScale", path: \.paragraphSpacingScale, defaultValue: 1.65)

    static let metrics: [Metric] = [
        fontScaleMetric, bubbleModeCornerMetric, bubbleCornerMetric, bubblePaddingHMetric,
        bubblePaddingVMetric, bubbleSpacingMetric, lineSpacingMetric, paragraphSpacingMetric,
    ]

    /// 镜像 / 迁移管的全部老键（字体 + 8 个数值）
    static var legacyKeys: [String] { [fontKey] + metrics.map(\.key) }

    func value(_ metric: Metric) -> Double { self[keyPath: metric.path] ?? metric.defaultValue }
    var effectiveFontName: String { fontName ?? "" }

    /// 去掉 themeId 以外的按层值（「恢复默认」）
    mutating func resetLayout() {
        fontName = nil
        for metric in Self.metrics { self[keyPath: metric.path] = nil }
    }

    /// 当前层的值镜像进运行时（`ProfileManager.mirrorCurrent` 调，只给当前层）。
    /// 字体字号 / 气泡几何只在迁移标记落了之后才写（`ProfileManager.init` 的镜像早于迁移，那时各层全 nil，直接写会把老全局值删掉）
    static func mirror(_ appearance: ChatAppearance?, into defaults: UserDefaults, theme: ThemeManager) {
        theme.applyChatTheme(appearance?.themeId)
        guard defaults.bool(forKey: migratedKey) else { return }
        writeKeys(appearance ?? ChatAppearance(), into: defaults)
    }

    /// 9 个老键写成这一层的值：nil 删键（让读侧默认值生效），值没变不写（`@AppStorage` 读者不白收通知）
    static func writeKeys(_ appearance: ChatAppearance, into defaults: UserDefaults) {
        sync(appearance.fontName, key: fontKey, into: defaults)
        for metric in metrics { sync(appearance[keyPath: metric.path], key: metric.key, into: defaults) }
    }

    static func sync(_ value: String?, key: String, into defaults: UserDefaults) {
        if let value {
            if defaults.object(forKey: key) as? String != value { defaults.set(value, forKey: key) }
        } else if defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    static func sync(_ value: Double?, key: String, into defaults: UserDefaults) {
        if let value {
            if (defaults.object(forKey: key) as? NSNumber)?.doubleValue != value { defaults.set(value, forKey: key) }
        } else if defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    /// 老的全局 9 键里设过的 → 抄进所有已有楼层（没设过的留 nil；某层已有值的不覆盖）。
    /// 改过的楼层全部落盘成功才落标记，失败下次启动重试；返回是否落了标记（落了调用方补一次 `mirrorCurrent`）
    @discardableResult
    static func migrateGlobalToFloors(profiles: [Profile], defaults store: UserDefaults, persist: ([Profile]) -> Bool) -> Bool {
        guard !store.bool(forKey: migratedKey) else { return false }
        var global = ChatAppearance()
        global.fontName = store.object(forKey: fontKey) as? String
        for metric in metrics { global[keyPath: metric.path] = (store.object(forKey: metric.key) as? NSNumber)?.doubleValue }
        if global != ChatAppearance() {
            let changed = profiles.map { p -> Profile in
                var p = p
                var a = p.chatAppearance ?? ChatAppearance()
                a.fontName = a.fontName ?? global.fontName
                for metric in metrics { a[keyPath: metric.path] = a[keyPath: metric.path] ?? global[keyPath: metric.path] }
                p.chatAppearance = a
                return p
            }
            if !changed.isEmpty, !persist(changed) { return false }
        }
        store.set(true, forKey: migratedKey)
        return true
    }
}
