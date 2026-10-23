import Foundation
import SwiftData

// MARK: - 健康模块 P0 数据层（体重 + 吃药）
// 两域独立不共基类（标量时序 vs 计划+打卡，见 docs/research-health-module.md §四）。
// 漏服状态推导不落库（HealthLogStore.medState）。

/// 体重打点：一天一条，date 归一到 startOfDay，同日重录 = HealthLogStore 手写 upsert（fetch→改→save）。
@Model
final class WeightEntry {
    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var date: Date          // startOfDay 归一
    var weightKg: Double    // 存储恒 kg，展示按单位设置换算
    var note: String = ""
    var createdAt: Date = Date()

    init(profileId: String, date: Date, weightKg: Double, note: String = "") {
        self.profileId = profileId
        self.date = Calendar.current.startOfDay(for: date)
        self.weightKg = weightKg
        self.note = note
    }
}

/// 一种药的服用计划。停药走 isArchived 归档保历史，不删。
@Model
final class Medication {
    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var name: String            // 药名（通知文案直接用）
    var dosage: String          // 剂量人话："1 片" / "5mg"，不结构化
    var timesOfDay: [Int]       // 每日提醒时刻，分钟数 [480, 1260] = 8:00 / 21:00
    var reminderEnabled: Bool = true
    var isArchived: Bool = false
    var note: String = ""
    var createdAt: Date = Date()

    init(profileId: String, name: String, dosage: String, timesOfDay: [Int], reminderEnabled: Bool = true) {
        self.profileId = profileId
        self.name = name
        self.dosage = dosage
        self.timesOfDay = timesOfDay
        self.reminderEnabled = reminderEnabled
    }
}

/// 月经打点：一天一条（date 归一 startOfDay，手写 upsert），经期/周期由连续打点推导不落库。
@Model
final class CycleDay {
    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var date: Date          // startOfDay 归一
    var flow: String        // CycleFlow rawValue: spotting/light/medium/heavy
    var note: String = ""
    var createdAt: Date = Date()

    init(profileId: String, date: Date, flow: String) {
        self.profileId = profileId
        self.date = Calendar.current.startOfDay(for: date)
        self.flow = flow
    }
}

/// 亲密记录：一天一条（date 归一 startOfDay，手写 upsert），再点=取消。
/// 隐私拍板（plan-health-intimacy）：只活在自己的卡里 + AI 注入，日历/流水不露。
@Model
final class IntimacyEntry {
    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var date: Date          // startOfDay 归一
    var note: String = ""
    var createdAt: Date = Date()

    init(profileId: String, date: Date, note: String = "") {
        self.profileId = profileId
        self.date = Calendar.current.startOfDay(for: date)
        self.note = note
    }
}

/// 一次实际服药打卡。撤销打卡 = 删这条。
@Model
final class MedicationLog {
    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var medicationId: UUID
    var scheduledAt: Date?      // 对应的计划时刻（当天 date + minuteOfDay）；nil = 计划外补服
    var takenAt: Date

    init(profileId: String, medicationId: UUID, scheduledAt: Date?, takenAt: Date = Date()) {
        self.profileId = profileId
        self.medicationId = medicationId
        self.scheduledAt = scheduledAt
        self.takenAt = takenAt
    }
}
