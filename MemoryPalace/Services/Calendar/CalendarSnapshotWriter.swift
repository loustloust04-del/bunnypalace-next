import Foundation
#if os(iOS)
import WidgetKit
#endif

// MARK: - 纪念日快照 → App Group（plan-calendar §九 P6，只有 iOS 有系统小组件）
// 跟随当前楼层：打开日历 / 改纪念日 / 聊天里记了日子时重写整份。
// 带照片（plan-calendar-photos-todos 裁定 #2）：串行队列里 先备好缩略图 → 原子写 latest.json → 成功才刷新小组件 → 清旧缩略图。

enum CalendarSnapshotWriter {
    #if os(iOS)
    private static let queue = DispatchQueue(label: "com.susu.MemoryPalace.calendar-snapshot", qos: .utility)
    #endif

    static func refresh(profileId: String) {
        #if os(iOS)
        let store = AnniversaryStore.forProfile(profileId)
        let anniversaries = store.loadAll()
        let today = Date()
        let cal = Calendar.current
        var sources: [(item: Int, from: URL, name: String)] = []
        var items: [CalendarSnapshot.Item] = []
        for a in AnniversaryOrdering.upcoming(anniversaries, today: today).prefix(6) {
            var targets: [String] = []
            if a.kind != .since {
                var from = today
                for _ in 0..<(a.kind == .yearly ? 3 : 1) {
                    guard let c = AnniversaryMath.countdown(for: a, today: from, gregorian: cal), !c.isPast else { break }
                    targets.append(DailyActivity.dayKey(c.target, calendar: cal))
                    guard let next = cal.date(byAdding: .day, value: 1, to: c.target) else { break }
                    from = next
                }
            }
            var item = CalendarSnapshot.Item(title: a.title, kind: a.kind.rawValue, isBirthday: a.isBirthday,
                                             style: a.style.rawValue, baseDate: a.date, targets: targets)
            if a.style.acceptsPhoto, let file = a.photo, let url = store.photoURL(a) {
                let name = CalendarSnapshot.thumbnailName(profileId: profileId, photoFile: file)
                item.photo = "\(CalendarSnapshot.photosDir)/\(name)"
                sources.append((items.count, url, name))
            }
            items.append(item)
        }
        let built = items, photoSources = sources
        queue.async {
            var items = built
            guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: UsageSnapshotWriter.appGroupId) else { return }
            let fm = FileManager.default
            let dir = base.appendingPathComponent(CalendarSnapshot.photosDir, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // 1. 缩略图（不可变文件名，已有就不重做）；做不出来（原图还没下来 / 坏了）就当这条没照片
            for s in photoSources {
                let dest = dir.appendingPathComponent(s.name)
                if fm.fileExists(atPath: dest.path) { continue }
                guard let data = try? Data(contentsOf: s.from),
                      let jpeg = AnniversaryPhoto.jpeg(from: data, maxPixel: AnniversaryPhoto.widgetMaxPixel),
                      (try? jpeg.write(to: dest, options: .atomic)) != nil else {
                    items[s.item].photo = nil
                    continue
                }
            }
            // 2. 原子写快照，成功才刷新
            let snapshot = CalendarSnapshot(profileId: profileId, items: items, writtenAt: today)
            let url = base.appendingPathComponent(CalendarSnapshot.relativePath)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot), (try? data.write(to: url, options: .atomic)) != nil else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: CalendarSnapshot.widgetKind)
            // 3. 清旧缩略图（不在这份快照里、放了超过一天）
            let keep = Set(items.compactMap { $0.photo.map { ($0 as NSString).lastPathComponent } })
            let existing: [(name: String, modified: Date)] = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for name in CalendarSnapshot.staleThumbnails(existing: existing, keep: keep, now: Date()) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        #endif
    }
}
