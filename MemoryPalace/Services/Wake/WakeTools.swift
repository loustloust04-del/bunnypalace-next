import Foundation
import MemoryCore
#if os(iOS)
import UIKit
import WebKit
#endif

/// 醒来能用的工具（plan-wake-heartbeat §3.3）：只给「自动允许」的，或这个任务所在对话里她点过「都允许」的；
/// 后台没人点卡，要她点头的不给（记进 withheld，heartbeat 里写出来）。
/// 浏览器只在她点「现在跑一次」时给（她在看着；定时醒来突然弹全屏浏览器会吓人），每一步截图
@MainActor
enum WakeTools {
    struct Built {
        var tools: [WakeTool]
        var withheld: [String]
    }

    static func build(profileId: String, grants: PermissionGrants, withBrowser: Bool) -> Built {
        var tools: [WakeTool] = []
        var withheld: [String] = []
        func allowed(_ domain: PermissionDomain, _ names: [String]) -> Bool {
            let ok = PermissionCenter.injectionAllowed(domain, profileId: profileId, grants: grants)
            if !ok, PermissionCenter.capabilityEnabled(domain, profileId: profileId) { withheld += names }
            return ok
        }

        if WebSearchSettings.shared.selected != nil, allowed(.webSearch, [WebSearchToolService.clientDefinition.name]) {
            tools.append(tool(WebSearchToolService.clientDefinition, label: "搜索",
                              describe: { "搜索「\(arg($0, "query") ?? "")」" }) { args in
                let r = await WebSearchToolService.execute(inputJSON: args)
                return AgentToolOutput(r.text, isError: r.isError)
            })
        }
        if allowed(.webSearch, [BrowseURLTool.definition.name]) {
            tools.append(tool(BrowseURLTool.definition, label: "读网页", describe: { "读 \(shortURL(arg($0, "url")))" },
                              source: urlSource) { args in
                let r = await BrowseURLTool.execute(inputJSON: args)
                return AgentToolOutput(r.text, isError: r.isError)
            })
        }
        if ChromeBridgeTools.hubReady, allowed(.webSearch, [ChromeBridgeTools.readName]),
           let def = ChromeBridgeTools.definitions.first(where: { $0.name == ChromeBridgeTools.readName }) {
            tools.append(tool(def, label: "用电脑 Chrome 读网页", describe: { "用电脑 Chrome 读 \(shortURL(arg($0, "url")))" },
                              source: urlSource) { args in
                let r = await ChromeBridgeTools.execute(name: ChromeBridgeTools.readName, inputJSON: args)
                return AgentToolOutput(r.text, isError: r.isError)
            })
        }
        if allowed(.calendar, [CalendarTools.queryName]),
           let def = CalendarTools.definitions.first(where: { $0.name == CalendarTools.queryName }) {
            tools.append(tool(def, label: "看日历", describe: { _ in "看日历" }) { args in
                let r = await CalendarTools.execute(name: CalendarTools.queryName, args: DeviceToolIO.args(args))
                return AgentToolOutput(r.text, isError: r.isError)
            })
        }
        if allowed(.reminders, [RemindersTools.queryName]),
           let def = RemindersTools.definitions.first(where: { $0.name == RemindersTools.queryName }) {
            tools.append(tool(def, label: "看提醒事项", describe: { _ in "看提醒事项" }) { args in
                let r = await RemindersTools.execute(name: RemindersTools.queryName, args: DeviceToolIO.args(args))
                return AgentToolOutput(r.text, isError: r.isError)
            })
        }
        #if os(iOS)
        if withBrowser, allowed(.browserOperate, BrowserOperateTools.definitions.map(\.name)) {
            tools += browserTools()
        }
        #endif
        return Built(tools: tools, withheld: withheld)
    }

    // MARK: 浏览器（iOS，「现在跑一次」时）

    #if os(iOS)
    private static func browserTools() -> [WakeTool] {
        var out: [WakeTool] = []
        for def in BrowserOperateTools.definitions {
            out.append(browserTool(def))
        }
        return out
    }

    private static func browserTool(_ def: ToolDefinition) -> WakeTool {
        let name = def.name
        let reads = name == BrowserOperateTools.lookName
        let describe: @Sendable (String) -> String = { args in describeBrowser(name, args) }
        // 动作回的最后一行是「现在这页：标题　网址」（BrowserOperator.pageLine）
        let source: @Sendable (String, AgentToolOutput) -> WakeSource? = { _, out in
            reads || out.isError ? nil : pageSource(out.content)
        }
        var snapshot: (@Sendable () async -> Data?)?
        if !reads {
            snapshot = { () async -> Data? in await WakeTools.browserSnapshot() }
        }
        // 写动作（发布 / 购买……）照旧在浏览器里弹卡问她；对话 id 用「wake」，授权不落到任何真对话
        let run: @Sendable @MainActor (String) async -> AgentToolOutput = { args in
            let r = await BrowserOperateTools.execute(name: name, inputJSON: args, conversationId: "wake")
            return AgentToolOutput(r.text, isError: r.isError)
        }
        return tool(def, label: "花园浏览器", describe: describe, source: source, snapshot: snapshot, run: run)
    }

    nonisolated static func pageSource(_ text: String) -> WakeSource? {
        guard let line = text.components(separatedBy: "\n").last(where: { $0.contains("现在这页：") }),
              let range = line.range(of: #"https?://\S+"#, options: .regularExpression) else { return nil }
        let title = line.components(separatedBy: "现在这页：").last?.components(separatedBy: "　").first
        return WakeSource(url: String(line[range]), title: title == "（无标题）" ? nil : title)
    }

    nonisolated private static func describeBrowser(_ name: String, _ args: String) -> String {
        switch name {
        case BrowserOperateTools.openName: return "打开 \(shortURL(arg(args, "url")))"
        case BrowserOperateTools.lookName: return "看这一页"
        case BrowserOperateTools.clickName: return "点了一下"
        case BrowserOperateTools.typeName: return "填字"
        case BrowserOperateTools.scrollName: return arg(args, "direction") == "up" ? "往上翻" : "往下翻"
        case BrowserOperateTools.backName: return "后退"
        default: return "操作浏览器"
        }
    }

    /// 当前花园浏览器整页一张，600px 宽
    private static func browserSnapshot() async -> Data? {
        guard let webView = BrowserOperator.shared.controller?.webView, webView.bounds.width > 0 else { return nil }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 600
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        return await Task.detached(priority: .utility) { image.jpegData(compressionQuality: 0.6) }.value
    }
    #endif

    // MARK: 拼装

    private static func tool(_ def: ToolDefinition, label: String, describe: @escaping @Sendable (String) -> String,
                             source: @escaping @Sendable (String, AgentToolOutput) -> WakeSource? = { _, _ in nil },
                             snapshot: (@Sendable () async -> Data?)? = nil,
                             run: @escaping @Sendable @MainActor (String) async -> AgentToolOutput) -> WakeTool {
        WakeTool(spec: spec(def), label: label, describe: describe, source: source, snapshot: snapshot) { args in
            await run(args)
        }
    }

    static func spec(_ def: ToolDefinition) -> AgentToolSpec {
        let schema: [String: Any] = ["type": "object", "properties": def.properties, "required": def.required]
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
        return AgentToolSpec(name: def.name, description: def.description, schema: String(decoding: data, as: UTF8.self))
    }

    nonisolated static func arg(_ json: String, _ key: String) -> String? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return (obj?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「openai.com/blog/xx」：去掉协议和 www，太长截断
    nonisolated static func shortURL(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "网页" }
        var s = raw.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s.count > 48 ? String(s.prefix(47)) + "…" : s
    }

    private static let urlSource: @Sendable (String, AgentToolOutput) -> WakeSource? = { args, _ in
        arg(args, "url").map { WakeSource(url: $0) }
    }
}
