import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// device_info：设备/电量/存储。system 类（永远放行，不进权限页，Minis 同款分类）。
enum DeviceInfoTool {
    static let toolName = "device_info"

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "读取用户设备的基本信息：kind=info（型号/系统版本/本 app 内存占用）、battery（电量与充电状态，iOS）、storage（磁盘可用空间）。",
            properties: ["kind": ["type": "string", "enum": ["info", "battery", "storage"], "description": "默认 info"]],
            required: []
        )
    }

    @MainActor
    static func execute(args: [String: Any]) -> DeviceToolExec {
        switch DeviceToolIO.str(args, "kind") ?? "info" {
        case "battery":
            #if canImport(UIKit)
            let dev = UIDevice.current
            dev.isBatteryMonitoringEnabled = true
            let level = dev.batteryLevel
            let state: String = switch dev.batteryState {
                case .charging: "charging"; case .full: "full"; case .unplugged: "unplugged"; default: "unknown"
            }
            return level < 0 ? DeviceToolIO.fail("not_available", "电量读不到（模拟器/未知）")
                             : DeviceToolIO.ok(["level_percent": Int(level * 100), "state": state])
            #else
            return DeviceToolIO.fail("not_available", "macOS 不提供电量读取")
            #endif
        case "storage":
            let home = URL(fileURLWithPath: NSHomeDirectory())
            guard let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else {
                return DeviceToolIO.fail("failed", "读取磁盘容量失败")
            }
            let free = Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
            let total = Double(v.volumeTotalCapacity ?? 0) / 1e9
            return DeviceToolIO.ok(["free_gb": round(free * 10) / 10, "total_gb": round(total * 10) / 10])
        default:
            var d: [String: Any] = [
                "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "app_memory_mb": residentMB(),
                "physical_memory_gb": round(Double(ProcessInfo.processInfo.physicalMemory) / 1e9 * 10) / 10,
            ]
            #if canImport(UIKit)
            d["model"] = UIDevice.current.model
            d["name"] = UIDevice.current.name
            #else
            d["model"] = "Mac"
            d["name"] = Host.current().localizedName ?? ""
            #endif
            return DeviceToolIO.ok(d)
        }
    }

    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}
