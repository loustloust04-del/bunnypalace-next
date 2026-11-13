import Foundation
import SwiftData

// MARK: - [Bunny] 药品柜双向同步：上游 Medication / MedicationLog ↔ 网关 /api/meds
//
// 分工沿用大肥兔（HealthSyncService，7f2c6c4df）：本地管服药计划、提醒、依从率；网关管库存，
// 也是 Caelum meds_* 工具的数据源。差别：上游模型没有 gatewayId / remaining 字段，
// 不改上游 schema——「本地药 ↔ 网关药」的对应关系与「已推送的打卡」记在兔兔侧（UserDefaults，按楼层）。
//
// 一轮同步：
//   1. 拉网关药品与今日打卡；
//   2. 认领：按已有对应 → 同名未对应 → 新建本地药（不开提醒、无计划时刻，等她自己设）；
//   3. 本地新建、尚未对应的药推给网关（库存 0，库存由网关 / Caelum 管）；
//   4. 网关今日打卡回灌本地（同药 60 秒内视为同一条；对齐到 ±90 分钟内最近的计划时刻）；
//   5. 本地打卡推给网关（只推启用同步之后的；推之前先和网关今日打卡比对 60 秒，避免重复扣库存）。
// 不同步删除（与大肥兔一致）：本地归档 / 删药不会删网关的药，避免误删库存记录。

enum BunnyMedsSync {   // [Bunny 11-13] 去掉 @MainActor：由后台上下文调用

    /// [Bunny 11-13] 在后台上下文里跑：写库与 WAL 检查点不再落在主线程（黑匣子记录到主线程保存卡 11 秒）
    static func runInBackground(container: ModelContainer, profileId: String) async -> String {
        await Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            return await run(context: ctx, profileId: profileId)
        }.value
    }
    private static func key(_ name: String, _ pid: String) -> String { "bunny.meds.\(name).\(pid)" }

    private static func links(_ pid: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key("links", pid)) as? [String: String] ?? [:]
    }
    private static func setLinks(_ v: [String: String], _ pid: String) { UserDefaults.standard.set(v, forKey: key("links", pid)) }

    private static func pushed(_ pid: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key("pushed", pid)) ?? []
    }
    private static func setPushed(_ v: [String], _ pid: String) {
        UserDefaults.standard.set(Array(v.suffix(800)), forKey: key("pushed", pid))
    }

    private static func pushSince(_ pid: String) -> Date {
        if let d = UserDefaults.standard.object(forKey: key("pushSince", pid)) as? Date { return d }
        let now = Date()
        UserDefaults.standard.set(now, forKey: key("pushSince", pid))
        return now
    }

    static var lastRunAt: Date? { UserDefaults.standard.object(forKey: "bunny.meds.lastRunAt") as? Date }

    static func runIfDue(context: ModelContext, profileId: String, minInterval: TimeInterval = 60) async {
        guard BunnyGateway.isConfigured, !profileId.isEmpty else { return }
        if let last = lastRunAt, Date().timeIntervalSince(last) < minInterval { return }
        _ = await run(context: context, profileId: profileId)
    }

    /// 返回给设置页看的一句话
    @discardableResult
    static func run(context: ModelContext, profileId pid: String) async -> String {
        guard let snap = await MedsClient.fetch() else { return "❌ 拿不到网关药品柜" }
        UserDefaults.standard.set(Date(), forKey: "bunny.meds.lastRunAt")
        let since = pushSince(pid)
        var link = links(pid)                                   // 本地药 UUID → 网关药 id
        var created = 0, pulled = 0, pushedTakes = 0, pushedMeds = 0

        let locals = (try? context.fetch(FetchDescriptor<Medication>(predicate: #Predicate { $0.profileId == pid }))) ?? []
        func localFor(_ gid: String) -> Medication? {
            guard let uuid = link.first(where: { $0.value == gid })?.key else { return nil }
            return locals.first { $0.id.uuidString == uuid }
        }

        // 2. 认领网关的药
        for remote in snap.meds where localFor(remote.id) == nil {
            if let byName = locals.first(where: { $0.name == remote.name && link[$0.id.uuidString] == nil && !$0.isArchived }) {
                link[byName.id.uuidString] = remote.id
            } else {
                let m = Medication(profileId: pid, name: remote.name,
                                   dosage: "\(MedsClient.numText(remote.perDose)) \(remote.unit)",
                                   timesOfDay: [], reminderEnabled: false)
                context.insert(m)
                link[m.id.uuidString] = remote.id
                created += 1
            }
        }

        // 3. 本地新药推给网关
        let allLocals = (try? context.fetch(FetchDescriptor<Medication>(predicate: #Predicate { $0.profileId == pid }))) ?? []
        for med in allLocals where link[med.id.uuidString] == nil && !med.isArchived {
            if let gid = await MedsClient.addReturningId(name: med.name, count: 0, unit: "片", perDose: 1, note: med.dosage) {
                link[med.id.uuidString] = gid
                pushedMeds += 1
            }
        }
        setLinks(link, pid)

        // 4. 网关今日打卡 → 本地
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parse(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
        var logs = (try? context.fetch(FetchDescriptor<MedicationLog>(predicate: #Predicate { $0.profileId == pid }))) ?? []
        var done = Set(pushed(pid))
        for intake in snap.today {
            guard let local = localFor(intake.medId), let ts = parse(intake.ts) else { continue }
            if let same = logs.first(where: { $0.medicationId == local.id && abs($0.takenAt.timeIntervalSince(ts)) < 60 }) {
                done.insert(same.id.uuidString)          // 本地已有（可能正是我们推上去的那条）
                continue
            }
            let log = MedicationLog(profileId: pid, medicationId: local.id,
                                    scheduledAt: nearestSlot(for: local, at: ts), takenAt: ts)
            context.insert(log)
            logs.append(log)
            done.insert(log.id.uuidString)               // 来自网关，不再推回去
            pulled += 1
        }

        // 5. 本地打卡 → 网关
        for log in logs where log.takenAt >= since && !done.contains(log.id.uuidString) {
            guard let gid = link[log.medicationId.uuidString] else { continue }
            let dupRemote = snap.today.contains { $0.medId == gid && (parse($0.ts).map { abs($0.timeIntervalSince(log.takenAt)) < 60 } ?? false) }
            if dupRemote {
                done.insert(log.id.uuidString)
            } else if await MedsClient.take(id: gid) {
                done.insert(log.id.uuidString)
                pushedTakes += 1
            }
        }
        setPushed(Array(done), pid)
        try? context.save()
        return "✅ 网关 \(snap.meds.count) 种药；新建本地 \(created)、推上网关 \(pushedMeds)；打卡拉回 \(pulled)、推上 \(pushedTakes)"
    }

    /// 网关打卡时间对齐到 ±90 分钟内最近的计划时刻，否则记为计划外（与大肥兔一致）
    private static func nearestSlot(for med: Medication, at ts: Date) -> Date? {
        guard !med.timesOfDay.isEmpty else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: ts)
        let minute = cal.component(.hour, from: ts) * 60 + cal.component(.minute, from: ts)
        guard let closest = med.timesOfDay.min(by: { abs($0 - minute) < abs($1 - minute) }),
              abs(closest - minute) <= 90 else { return nil }
        return cal.date(byAdding: .minute, value: closest, to: day)
    }
}
