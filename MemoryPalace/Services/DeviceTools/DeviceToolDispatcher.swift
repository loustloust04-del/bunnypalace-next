import Foundation

/// 设备工具单入口（plan-设备工具 T7）：注册表定义 + 名字分发 + 最小 required 预检。
/// tool loop 只加一个 else-if；权限闸在 loop 里按 `PermissionDomain.forTool` 先于本入口判定。
/// 预检 = 对比线 A1 `ToolCallPreflight` 的最小版（只做 required 缺失的确定性拒绝，回灌 isError 让模型自愈）；A1 正式落地后并入。
enum DeviceToolDispatcher {
    static var definitions: [ToolDefinition] {
        var defs = CalendarTools.definitions + RemindersTools.definitions
            + [ClipboardTool.definition, OCRImageTool.definition, NotifyTool.definition, OpenURLTool.definition, DeviceInfoTool.definition]
        // plan-离线沙箱 phase1/phase2：macOS = 原生 shell，iOS = app 内 Alpine 沙箱，同名同 schema
        defs.append(RunCommandTool.definition)
        return defs
    }

    static var names: Set<String> { Set(definitions.map(\.name)) }

    static func handles(_ name: String) -> Bool { names.contains(name) }

    /// required 缺失 → 错误文本；nil = 通过。
    /// **主路径已由 `ToolCallPreflight`（A1）在 tool loop 里统一拦截**，这里保留为兜底：
    /// 设备工具若被别的入口直接调用（测试、未来的后台 agent），仍有一层确定性校验。
    static func preflight(name: String, args: [String: Any]) -> String? {
        guard let def = definitions.first(where: { $0.name == name }) else { return nil }
        let missing = def.required.filter { key in
            guard let v = args[key] else { return true }
            if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return v is NSNull
        }
        return missing.isEmpty ? nil : DeviceToolIO.fail("missing_param", "\(name) 缺必填参数：\(missing.joined(separator: ", "))").text
    }

    /// `monitorCommand` 只给 run_command：「运行」面板登记的命令文本（换过加密值时是占位版）
    @MainActor
    static func execute(name: String, inputJSON: String, profileId: String, conversationId: String?, monitorCommand: String? = nil) async -> DeviceToolExec {
        let args = DeviceToolIO.args(inputJSON)
        if let denial = preflight(name: name, args: args) { return DeviceToolExec(text: denial, isError: true) }
        switch name {
        case _ where CalendarTools.names.contains(name):
            return await CalendarTools.execute(name: name, args: args)
        case _ where RemindersTools.names.contains(name):
            return await RemindersTools.execute(name: name, args: args)
        case ClipboardTool.toolName:
            return ClipboardTool.execute(profileId: profileId, conversationId: conversationId)
        case OCRImageTool.toolName:
            return await OCRImageTool.execute(args: args, profileId: profileId)
        case NotifyTool.toolName:
            return await NotifyTool.execute(args: args)
        case OpenURLTool.toolName:
            return await OpenURLTool.execute(args: args)
        case DeviceInfoTool.toolName:
            return DeviceInfoTool.execute(args: args)
        case RunCommandTool.toolName:
            return await RunCommandTool.execute(args: args, profileId: profileId, conversationId: conversationId, monitorCommand: monitorCommand)
        default:
            return DeviceToolIO.fail("not_available", "未知设备工具 \(name)")
        }
    }

    /// 「到点叫一声」几条路的分工（#069）：这一轮下发了两条以上才说，只列下发了的；card-timer 卡随 card_guide 一起有
    static func timingHint(available: Set<String>) -> String? {
        var lines: [String] = []
        if available.contains(RemindersTools.createName) { lines.append("- 到点要叫对方做某事 → reminders_create（带 due）") }
        if available.contains(CalendarTools.createName) { lines.append("- 有起止时间的安排 → calendar_create") }
        if available.contains(NotifyTool.toolName) { lines.append("- 只是「N 分钟后叫我一声」→ notify_schedule") }
        guard lines.count >= 2 else { return nil }
        if available.contains(CardGuideTool.toolName) { lines.append("- 想在聊天里看着倒计时 → card-timer 卡") }
        return (["〔到点提醒〕对方让你提醒 / 叫 TA 时按这个分："] + lines).joined(separator: "\n")
    }

    /// 给模型的说明段（进 toolInjection 的 systemHint，与文件库段并列）。
    static var systemHint: String {
        var s = """
        <设备>
        你可以用设备工具读写用户的系统日历（calendar_*）、提醒事项（reminders_*）、读剪贴板（clipboard_read）、识别图片文字（ocr_image）、发本地通知（notify_schedule）、打开链接（open_url）、看设备状态（device_info）。这些都会真实改动用户设备上的数据，创建/删除前确认用户意图；被拒绝（permission_denied / authorization_denied）时如实告诉用户并指引去设置开启，不要重试。
        </设备>
        """
        // <命令> 段按平台分：两端同名同 schema，但隔离性、cwd、可用性契约完全不同，
        // 混一段写会让模型在 iOS 上以为自己能碰用户的文件系统。
        #if os(macOS)
        s += """

        <命令>
        你可以用 run_command 在用户的这台 Mac 上运行 shell 命令（zsh）。工作目录默认是当前楼层的文件库根，可以直接在里面 ls / grep / 跑脚本。每次调用是独立进程、无状态，命令返回时同一进程组里的后台进程会一并结束（自己 setsid / 交给 launchd 的守护进程除外——不要启动这类东西，没人替你收）；长任务给 timeout_seconds（默认 120，上限 600）；输出超过 15000 字符会截断头尾。改文件内容优先用 fs_write / fs_edit（原子写）。一轮回复结束后你不会再有执行任何东西的机会——不要许诺「我会继续监控」「稍后同步结果」，要等就在本轮等，要查就在本轮查。
        </命令>
        """
        #else
        s += """

        <命令>
        你可以用 run_command 在 app 内置的 Linux 沙箱里运行 shell 命令（Alpine Linux aarch64，busybox ash）。这是真隔离：沙箱里看不到、也改不了用户设备上的任何东西，用户的文件库要用 fs_* 工具读写。工作目录默认 /root。每次调用是独立进程、无状态（cd、变量、后台进程都不跨调用保留）。三条硬约束：① 每条命令有约 200ms 固定开销，别用它做循环里的小操作，能一条命令做完就别拆成十条；② app 必须停在前台：用户切走或锁屏后整个 app 会被系统挂起，正在跑的命令**原地冻结**（既不返回结果也不报错），回到前台才继续；内存紧张时 app 还可能被直接回收。所以长任务要先提醒用户别切走，别指望后台跑完；③ 沙箱不保证有网络，`apk add` 装包可能失败，不要把它当作方案的前提。长任务给 timeout_seconds（默认 120，上限 600）；输出超过 15000 字符会截断头尾。一轮回复结束后你不会再有执行任何东西的机会——不要许诺「我会继续监控」「稍后同步结果」，要等就在本轮等，要查就在本轮查。
        </命令>
        """
        #endif
        return s
    }
}
