import Foundation

/// 「目录化」元工具（Cherry / 官端做法）：不全量内联 schema，只暴露 3 个元工具，
/// 让模型先 tool_search 搜目录 → tool_inspect 看参数 → tool_invoke 调用。
/// 目录 = MCP 工具海（超阈值时）+ 收在「更多工具」里的内建工具（#069）；常用内建工具仍直接内联。
/// 内建的 tool_invoke 在 tool loop 开头拆回真名执行，不走这里的 resolve。
enum MetaTools {
    static let searchName = "tool_search"
    static let inspectName = "tool_inspect"
    static let invokeName = "tool_invoke"

    static let names: Set<String> = [searchName, inspectName, invokeName]

    /// (名字, 描述, JSON-schema properties, required)
    private static let specs: [(String, String, [String: Any], [String])] = [
        (searchName,
         "按关键词搜索没直接展开的工具（收在「更多工具」里的内建工具、外部 MCP 工具）。返回名字、来源、简介。需要某种能力但工具清单里没有时先用它；query 留空则列出全部。",
         ["query": ["type": "string", "description": "关键词，如「天气」「发推」；留空列出全部"]],
         []),
        (inspectName,
         "查看一个或多个没直接展开的工具的完整参数 schema，调用前用它确认参数。",
         ["names": ["type": "array", "items": ["type": "string"], "description": "工具名列表"]],
         ["names"]),
        (invokeName,
         "调用一个没直接展开的工具（〔更多工具〕里列的，或 tool_search 搜到的）。name 只填工具名本身（如 ocr_image），不要带来源、命名空间或方括号；arguments 是符合该工具 schema 的参数对象（无参数填 {}）。",
         ["name": ["type": "string"], "arguments": ["type": "object", "description": "该工具的参数对象"]],
         ["name", "arguments"]),
    ]

    /// 统一定义（MCP > 阈值时经 ToolRegistry 注入）
    static var definitions: [ToolDefinition] {
        specs.map { (name, desc, props, req) in
            ToolDefinition(name: name, description: desc, properties: props, required: req)
        }
    }

    // MARK: - 目录搜索 / 查看（纯函数，吃 catalog）

    /// 命名空间：mcp:<serverName>
    static func namespace(_ t: MCPResolvedTool) -> String { "mcp:\(t.serverName)" }

    /// query 模糊匹配 name/description；空 query 返回全部。紧凑文本：名字 · 命名空间 · 简介。
    /// builtins = 收在「更多工具」里、这一轮可用的内建工具，排在前面、来源标「内建」；
    /// reserved = 全部内建工具名：MCP 跟任何内建同名都不列（执行端裸名一律按内建走，列了也调不到）
    static func search(query: String, catalog: [MCPResolvedTool], builtins: [ToolDefinition] = [], reserved: Set<String> = []) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func hit(_ name: String, _ desc: String) -> Bool { q.isEmpty || name.lowercased().contains(q) || desc.lowercased().contains(q) }
        let hidden = reserved.union(builtins.map(\.name))
        // #089 P3-b：收起的内建工具一句话和系统提示〔更多工具〕同源（tuckedBlurbs），两处不会改了一处忘了另一处
        func blurb(_ d: ToolDefinition) -> String { ToolRegistry.tuckedBlurbs[d.name] ?? d.description }
        let builtinHits = builtins.filter { hit($0.name, $0.description) || hit($0.name, blurb($0)) }
        let hits = catalog.filter { !hidden.contains($0.tool.name) && hit($0.tool.name, $0.tool.description) }
        if hits.isEmpty && builtinHits.isEmpty {
            let spaces = (builtins.isEmpty ? [] : ["内建(\(builtins.count))"]) + (catalog.isEmpty ? [] : [namespacesSummary(catalog)])
            return "无匹配工具。可用：\(spaces.joined(separator: "、"))"
        }
        // 名字打头，来源放末尾括号 —— 避免模型把 [来源] 当成名字的一部分。
        return (builtinHits.map { "· \($0.name) — \(blurb($0))  (来源 内建)" }
            + hits.map { "· \($0.tool.name) — \($0.tool.description)  (来源 \(namespace($0)))" }).joined(separator: "\n")
    }

    /// 把模型可能带装饰的 name 归一化到 catalog 里的真实工具名。
    /// 容错：去空格 / 去 [...] / 去 mcp:server 前缀 / 大小写 / 包含。
    static func resolve(_ raw: String, catalog: [MCPResolvedTool]) -> String? {
        let names = catalog.map(\.tool.name)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if names.contains(trimmed) { return trimmed }
        // 取空格或 '[' 之前的裸名
        let bare = String(trimmed.prefix(while: { $0 != " " && $0 != "[" })).trimmingCharacters(in: .whitespaces)
        if names.contains(bare) { return bare }
        // 去掉 namespace 前缀（mcp:server/tool 或 mcp:server:tool）取最后一段
        if let last = bare.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init), names.contains(last) {
            return last
        }
        // 大小写不敏感 / 互相包含
        if let m = names.first(where: { $0.lowercased() == trimmed.lowercased() }) { return m }
        if let m = names.first(where: { trimmed.lowercased().contains($0.lowercased()) }) { return m }
        return nil
    }

    /// 返回指定工具的完整参数 schema（JSON）。
    static func inspect(names: [String], catalog: [MCPResolvedTool], builtins: [ToolDefinition] = [], reserved: Set<String> = []) -> String {
        guard !names.isEmpty else { return "请提供要查看的工具名（names）。" }
        var blocks: [String] = []
        for name in names {
            if let d = builtins.first(where: { $0.name == name }) {
                var schema: [String: Any] = ["type": "object", "properties": d.properties]
                if !d.required.isEmpty { schema["required"] = d.required }
                let schemaText = (try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                blocks.append("\(name) [内建] — \(d.description)\n参数 schema:\n\(schemaText)")
                continue
            }
            if reserved.contains(name) {
                blocks.append("\(name): 内建工具，不在「更多工具」里（在工具清单里就直接调，不在就是这一轮没开）")
                continue
            }
            guard let t = catalog.first(where: { $0.tool.name == name }) else {
                blocks.append("\(name): 未找到（用 tool_search 确认名字）")
                continue
            }
            let schemaText = (try? JSONSerialization.data(withJSONObject: t.tool.schemaAny(), options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            blocks.append("\(name) [\(namespace(t))] — \(t.tool.description)\n参数 schema:\n\(schemaText)")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// namespace → 工具数量，拼成 "mcp:天气(12)、mcp:推特(8)"
    static func namespacesSummary(_ catalog: [MCPResolvedTool]) -> String {
        var counts: [String: Int] = [:]
        for t in catalog { counts[namespace(t), default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)(\($0.value))" }.joined(separator: "、")
    }
}
