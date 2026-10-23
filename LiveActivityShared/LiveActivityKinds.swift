/// widget kind 字符串只此一处：`StaticConfiguration(kind:)` 和 `reloadTimelines(ofKind:)` 都引它。
/// 对不上 → app 写完快照 widget 不刷新，而且不会报错。
enum LiveActivityKinds {
    static let usageWidget = "com.susu.MemoryPalace.usage"
}
