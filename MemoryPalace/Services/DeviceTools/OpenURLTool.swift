import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// open_url：打开链接。system 类（永远放行，不进权限页）。
/// 白名单只有 http(s) + settings（`mp://` 等对比线 C4 URL spec——MP 目前 0 个注册 scheme）。不让模型开任意 scheme。
enum OpenURLTool {
    static let toolName = "open_url"

    static var definition: ToolDefinition {
        ToolDefinition(
            name: toolName,
            description: "在用户设备上打开一个链接：http/https 网址，或 \"settings\" 打开本 app 的系统设置页。其他 scheme 不允许。只是在对方设备上打开，你看不到页面内容。",
            properties: ["url": ["type": "string"]],
            required: ["url"]
        )
    }

    @MainActor
    static func execute(args: [String: Any]) async -> DeviceToolExec {
        guard let raw = DeviceToolIO.str(args, "url") else { return DeviceToolIO.fail("missing_param", "缺 url") }
        let target: URL
        if raw.lowercased() == "settings" || raw.lowercased().hasPrefix("settings:") {
            #if canImport(UIKit)
            guard let u = URL(string: UIApplication.openSettingsURLString) else { return DeviceToolIO.fail("failed", "系统设置 URL 不可用") }
            #else
            guard let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return DeviceToolIO.fail("failed", "系统设置 URL 不可用") }
            #endif
            target = u
        } else {
            guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return DeviceToolIO.fail("invalid_param", "只允许 http/https 链接或 settings")
            }
            target = u
        }
        #if canImport(UIKit)
        let opened = await UIApplication.shared.open(target)
        #else
        let opened = NSWorkspace.shared.open(target)
        #endif
        return opened ? DeviceToolIO.ok(["opened": true, "url": target.absoluteString])
                      : DeviceToolIO.fail("failed", "系统拒绝打开：\(target.absoluteString)")
    }
}
