import Foundation
import EventKit

/// EventKit 共享层（plan-设备工具 §1）：单例 EKEventStore + 授权（走 SystemAuthQueue）+ 事件/提醒的查建删。
/// 重复事件语义（Minis 档案）：`eventIdentifier` 是系列 ID，单次实例靠 `occurrenceDate` 区分；删除带 span。
/// fetch 提醒是回调 API，包成 async 并加 10s 超时——超时必须报 timeout 不能当空列表。
final class EventKitService {
    static let shared = EventKitService()
    let store = EKEventStore()
    private init() {}

    enum AccessResult { case granted, denied, timeout }

    // MARK: 授权

    func ensureEventsAccess() async -> AccessResult {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return .granted }
        let store = self.store
        let r = await SystemAuthQueue.shared.run { () -> Bool in
            (try? await store.requestFullAccessToEvents()) ?? false
        }
        guard let ok = r else { return .timeout }
        return ok ? .granted : .denied
    }

    func ensureRemindersAccess() async -> AccessResult {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return .granted }
        let store = self.store
        let r = await SystemAuthQueue.shared.run { () -> Bool in
            (try? await store.requestFullAccessToReminders()) ?? false
        }
        guard let ok = r else { return .timeout }
        return ok ? .granted : .denied
    }

    // MARK: 事件

    func queryEvents(from: Date, to: Date, limit: Int, calendarTitle: String?) -> (events: [EKEvent], total: Int) {
        let cals = calendarTitle.flatMap { t in
            let m = store.calendars(for: .event).filter { $0.title.localizedCaseInsensitiveCompare(t) == .orderedSame }
            return m.isEmpty ? nil : m
        }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        let all = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        return (Array(all.prefix(limit)), all.count)
    }

    func createEvent(title: String, start: Date, end: Date, allDay: Bool, location: String?, notes: String?, calendarTitle: String?) throws -> EKEvent {
        let ev = EKEvent(eventStore: store)
        ev.title = title
        ev.startDate = start
        ev.endDate = end
        ev.isAllDay = allDay
        ev.location = location
        ev.notes = notes
        if let t = calendarTitle,
           let c = store.calendars(for: .event).first(where: { $0.title.localizedCaseInsensitiveCompare(t) == .orderedSame && $0.allowsContentModifications }) {
            ev.calendar = c
        } else {
            ev.calendar = store.defaultCalendarForNewEvents
        }
        try store.save(ev, span: .thisEvent, commit: true)
        return ev
    }

    enum DeleteSpan: String { case this, future }

    /// occurrenceDate 给了就在 ±1 天窗口内找最接近的实例（Minis 同款），不给就取系列的第一条。
    func deleteEvent(id: String, occurrenceDate: Date?, span: DeleteSpan) throws -> Bool {
        var target: EKEvent?
        if let occ = occurrenceDate {
            let pred = store.predicateForEvents(withStart: occ.addingTimeInterval(-86400), end: occ.addingTimeInterval(86400), calendars: nil)
            target = store.events(matching: pred)
                .filter { $0.eventIdentifier == id }
                .min { abs($0.startDate.timeIntervalSince(occ)) < abs($1.startDate.timeIntervalSince(occ)) }
        } else {
            target = store.event(withIdentifier: id)
        }
        guard let ev = target else { return false }
        try store.remove(ev, span: span == .future ? .futureEvents : .thisEvent, commit: true)
        return true
    }

    // MARK: 提醒

    func queryReminders(listTitle: String?, includeCompleted: Bool, dueBefore: Date?, limit: Int) async -> (reminders: [EKReminder], total: Int)? {
        let store = self.store
        let cals = listTitle.flatMap { t in
            let m = store.calendars(for: .reminder).filter { $0.title.localizedCaseInsensitiveCompare(t) == .orderedSame }
            return m.isEmpty ? nil : m
        }
        let pred = includeCompleted
            ? store.predicateForReminders(in: cals)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: cals)
        let fetched: [EKReminder]? = await DeviceToolIO.withTimeout(seconds: 10) {
            await withCheckedContinuation { (c: CheckedContinuation<[EKReminder], Never>) in
                store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) }
            }
        }
        guard var all = fetched else { return nil }
        if includeCompleted, let due = dueBefore {
            all = all.filter { ($0.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture) <= due }
        }
        all.sort { ($0.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture) < ($1.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture) }
        return (Array(all.prefix(limit)), all.count)
    }

    func createReminder(title: String, due: Date?, listTitle: String?, notes: String?, priority: Int?) throws -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = notes
        if let p = priority { r.priority = max(0, min(9, p)) }
        if let d = due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            r.addAlarm(EKAlarm(absoluteDate: d))
        }
        if let t = listTitle,
           let c = store.calendars(for: .reminder).first(where: { $0.title.localizedCaseInsensitiveCompare(t) == .orderedSame && $0.allowsContentModifications }) {
            r.calendar = c
        } else {
            r.calendar = store.defaultCalendarForNewReminders()
        }
        try store.save(r, commit: true)
        return r
    }

    func completeReminder(id: String) throws -> Bool {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        r.isCompleted = true
        try store.save(r, commit: true)
        return true
    }

    // MARK: 序列化

    static func describe(_ ev: EKEvent) -> [String: Any] {
        var d: [String: Any] = [
            "id": ev.eventIdentifier ?? "",
            "title": ev.title ?? "",
            "start": DeviceToolIO.iso(ev.startDate),
            "end": DeviceToolIO.iso(ev.endDate),
            "all_day": ev.isAllDay,
            "calendar": ev.calendar?.title ?? "",
        ]
        if let l = ev.location, !l.isEmpty { d["location"] = l }
        if ev.hasRecurrenceRules { d["recurring"] = true; d["occurrence_date"] = DeviceToolIO.iso(ev.occurrenceDate) }
        return d
    }

    static func describe(_ r: EKReminder) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.calendarItemIdentifier,
            "title": r.title ?? "",
            "completed": r.isCompleted,
            "list": r.calendar?.title ?? "",
        ]
        if let due = r.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) { d["due"] = DeviceToolIO.iso(due) }
        if r.priority != 0 { d["priority"] = r.priority }
        if let n = r.notes, !n.isEmpty { d["notes"] = n }
        return d
    }
}
