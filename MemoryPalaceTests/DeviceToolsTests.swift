import XCTest
@testable import 记忆花园

/// 设备工具 P1（plan-设备工具 T8）：日期解析 / required 预检 / 域映射 / 注册表准入 / envelope。
final class DeviceToolsTests: XCTestCase {

    // MARK: 日期

    func testParseDate_relativeAndKeywords() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DeviceToolIO.parseDate("now", now: now), now)
        XCTAssertEqual(DeviceToolIO.parseDate("+2h", now: now), now.addingTimeInterval(7200))
        XCTAssertEqual(DeviceToolIO.parseDate("-7d", now: now), now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(DeviceToolIO.parseDate("+30m", now: now), now.addingTimeInterval(1800))
        XCTAssertEqual(DeviceToolIO.parseDate("today", now: now), Calendar.current.startOfDay(for: now))
        XCTAssertNil(DeviceToolIO.parseDate("garbage"))
        XCTAssertNil(DeviceToolIO.parseDate(""))
    }

    func testParseDate_isoLocalAndZoned() {
        // 无时区 = 设备本地
        let local = DeviceToolIO.parseDate("2026-08-25T09:30")
        let comps = local.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
        XCTAssertEqual(comps?.hour, 9); XCTAssertEqual(comps?.minute, 30)
        XCTAssertNotNil(DeviceToolIO.parseDate("2026-08-25T09:30:00+08:00"))
        XCTAssertNotNil(DeviceToolIO.parseDate("2026-08-25"))
        // 输出本地 ISO 能被自己解析回来
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let back = DeviceToolIO.parseDate(DeviceToolIO.iso(d))
        XCTAssertEqual(back.map { Int($0.timeIntervalSince1970) }, Int(d.timeIntervalSince1970), "iso() 输出必须能被 parseDate 回读")
    }

    // MARK: 预检（对比线 A1 最小版）

    func testPreflight_missingRequiredIsRejected() {
        XCTAssertNotNil(DeviceToolDispatcher.preflight(name: "calendar_delete", args: [:]))
        XCTAssertNotNil(DeviceToolDispatcher.preflight(name: "calendar_delete", args: ["id": "  "]), "空串按缺失")
        XCTAssertNil(DeviceToolDispatcher.preflight(name: "calendar_delete", args: ["id": "abc"]))
        XCTAssertNotNil(DeviceToolDispatcher.preflight(name: "reminders_create", args: ["due": "+1h"]))
        XCTAssertNil(DeviceToolDispatcher.preflight(name: "calendar_query", args: [:]), "无 required 的工具直过")
        let text = DeviceToolDispatcher.preflight(name: "calendar_create", args: [:]) ?? ""
        XCTAssertTrue(text.contains("missing_param") && text.contains("title") && text.contains("start"))
    }

    // MARK: 域映射（研究 §四洞 2：日历/提醒各归各域）

    func testForTool_deviceDomains() {
        XCTAssertEqual(PermissionDomain.forTool(named: "calendar_query"), .calendar)
        XCTAssertEqual(PermissionDomain.forTool(named: "calendar_delete"), .calendar)
        XCTAssertEqual(PermissionDomain.forTool(named: "reminders_create"), .reminders)
        XCTAssertEqual(PermissionDomain.forTool(named: "clipboard_read"), .clipboard)
        XCTAssertEqual(PermissionDomain.forTool(named: "notify_schedule"), .notifications)
        XCTAssertEqual(PermissionDomain.forTool(named: "open_url"), .toolsMaster)
        XCTAssertEqual(PermissionDomain.forTool(named: "device_info"), .toolsMaster)
        XCTAssertEqual(PermissionDomain.forTool(named: "ocr_image"), .toolsMaster)
    }

    /// #069：「到点提醒」分工只列下发了的；不到两条路不说
    func testTimingHintListsOnlyAvailable() {
        XCTAssertNil(DeviceToolDispatcher.timingHint(available: ["calendar_create"]))
        let two = DeviceToolDispatcher.timingHint(available: ["calendar_create", "notify_schedule"]) ?? ""
        XCTAssertTrue(two.contains("calendar_create") && two.contains("notify_schedule"))
        XCTAssertFalse(two.contains("reminders_create"))
        XCTAssertFalse(two.contains("card-timer"), "没发 card_guide 不提倒计时卡")
        let all = DeviceToolDispatcher.timingHint(available: ["calendar_create", "notify_schedule", "reminders_create", "card_guide"]) ?? ""
        XCTAssertTrue(all.contains("reminders_create") && all.contains("card-timer"))
    }

    func testNewDomainsDefaultOff() {
        for d in [PermissionDomain.calendar, .reminders, .clipboard, .notifications] {
            UserDefaults.standard.removeObject(forKey: d.storageKey)
            XCTAssertEqual(PermissionCenter.level(d), .notAllowed, "\(d) 新能力默认关")
        }
    }

    // MARK: 注册表准入（每个设备工具必须有域；名字不撞现有工具）

    @MainActor
    func testRegistryAdmission() {
        let names = DeviceToolDispatcher.definitions.map(\.name)
        #if os(macOS)
        XCTAssertEqual(names.count, 12)   // 11 设备工具 + run_command（plan-离线沙箱-phase1，macOS only）
        #else
        XCTAssertEqual(names.count, 11)
        #endif
        XCTAssertEqual(Set(names).count, names.count, "工具名唯一")
        for n in names { XCTAssertTrue(DeviceToolDispatcher.handles(n)) }
        // 全部下发时注册表能看到它们（各域 bypass；shell 也显式设，测试宿主是真 app、真库的迁移状态不可信）
        // 真 prefs：先存旧值，defer 恢复——测试中途崩溃不能把真 app 留在 perm.shell=bypass（shell 裸奔）
        let domains: [PermissionDomain] = [.calendar, .reminders, .clipboard, .notifications, .shell]
        let saved = domains.map { ($0, UserDefaults.standard.object(forKey: $0.storageKey), UserDefaults.standard.object(forKey: $0.legacy.key)) }
        defer {
            for (d, lvl, legacy) in saved {
                if let lvl { UserDefaults.standard.set(lvl, forKey: d.storageKey) } else { UserDefaults.standard.removeObject(forKey: d.storageKey) }
                if let legacy { UserDefaults.standard.set(legacy, forKey: d.legacy.key) } else { UserDefaults.standard.removeObject(forKey: d.legacy.key) }
            }
        }
        for d in domains { PermissionCenter.setLevel(.bypass, for: d) }
        let on = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        for n in names { XCTAssertTrue(on.contains(n), "\(n) 应在注册表下发") }
        // 域关掉 → 该域工具不下发，其它域不受影响
        PermissionCenter.setLevel(.notAllowed, for: .calendar)
        let off = ToolRegistry.enabledDefinitions(.init(family: .openAI, deferMCP: false)).map(\.name)
        XCTAssertFalse(off.contains("calendar_query"))
        XCTAssertTrue(off.contains("reminders_query"))
    }

    // MARK: envelope

    func testEnvelopeShapes() {
        let ok = DeviceToolIO.ok(["a": 1])
        XCTAssertFalse(ok.isError)
        XCTAssertTrue(ok.text.contains("\"ok\":true") && ok.text.contains("\"a\":1"))
        let bad = DeviceToolIO.fail("timeout", "x")
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.text.contains("\"code\":\"timeout\""))
    }
}
