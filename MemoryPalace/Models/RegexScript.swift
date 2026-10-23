import Foundation

// MARK: - Regex Script (酒馆正则脚本)

struct RegexScript: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var scriptName: String = ""
    var findRegex: String = ""           // 正则表达式（含 flags，如 /pattern/s）
    var replaceString: String = ""       // 替换模板（$1 $2 捕获组, {{match}} = $0）
    var placement: [Int] = [2]           // 1=用户消息, 2=AI消息, 3=命令, 5=世界书, 6=推理
    var disabled: Bool = false
    // ⚠️ 默认两 flag 都 false（普通模式 = SillyTavern "User Input" 时机，不渲染不发送时跑）。
    // 原 markdownOnly 默认 true 是陷阱：用户新建 script 想"只擦发送"会勾上 promptOnly 但漏关 markdownOnly，
    // 双开 → 楼层渲染时也被擦空（2026-06-16 🔴破限事故根因）。改默认 false，要哪个时机用户主动勾。
    var markdownOnly: Bool = false       // true=渲染时替换（楼层显示前）
    var promptOnly: Bool = false         // true=发送 API 时替换（请求体里）
    var runOnEdit: Bool = true
    var trimStrings: [String] = []       // 从结果中移除的字符串
    var substituteRegex: Int = 0         // 0=不替换, 1=替换宏（原样）, 2=替换宏（转义）
    var minDepth: Int? = nil             // promptOnly: 最小消息深度（0=最新）
    var maxDepth: Int? = nil             // promptOnly: 最大消息深度

    /// 从 TavernCard extensions.regex_scripts[] 的 JSON 字典解析
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.scriptName = dict["scriptName"] as? String ?? ""
        self.findRegex = dict["findRegex"] as? String ?? ""
        self.replaceString = dict["replaceString"] as? String ?? ""
        self.placement = dict["placement"] as? [Int] ?? [2]
        self.disabled = dict["disabled"] as? Bool ?? false
        // 老 SillyTavern export 缺字段时默认 false（"User Input" 时机），不再默认渲染时擦
        self.markdownOnly = dict["markdownOnly"] as? Bool ?? false
        self.promptOnly = dict["promptOnly"] as? Bool ?? false
        self.runOnEdit = dict["runOnEdit"] as? Bool ?? true
        self.trimStrings = dict["trimStrings"] as? [String] ?? []
        self.substituteRegex = dict["substituteRegex"] as? Int ?? 0
        self.minDepth = dict["minDepth"] as? Int
        self.maxDepth = dict["maxDepth"] as? Int
    }

    init() {}
}

// MARK: - Regex Engine (兼容酒馆)

struct RegexEngine {

    /// 酒馆 placement 常量
    static let placementUserInput = 1
    static let placementAIOutput = 2

    /// 对文本应用正则脚本
    ///
    /// - messagePlacement: 1=用户消息, 2=AI消息
    /// - isMarkdown: true=渲染显示模式
    /// - isPrompt: true=API发送模式
    /// - depth: 消息深度（0=最新消息，仅 promptOnly 用）
    /// - userName/charName: 宏替换用
    static func apply(
        scripts: [RegexScript],
        text: String,
        messagePlacement: Int,
        isMarkdown: Bool = false,
        isPrompt: Bool = false,
        depth: Int? = nil,
        userName: String = "",
        charName: String = ""
    ) -> String {
        var result = text

        for script in scripts {
            guard !script.disabled else { continue }

            // 上下文过滤（对齐酒馆逻辑）
            let shouldRun: Bool
            if script.markdownOnly && script.promptOnly {
                shouldRun = isMarkdown || isPrompt
            } else if script.markdownOnly {
                shouldRun = isMarkdown
            } else if script.promptOnly {
                shouldRun = isPrompt
            } else {
                shouldRun = !isMarkdown && !isPrompt
            }
            guard shouldRun else { continue }

            // 检查 placement
            guard script.placement.contains(messagePlacement) else { continue }

            // 深度过滤（仅 promptOnly 模式）
            if isPrompt, let depth = depth {
                if let min = script.minDepth, min >= 0, depth < min { continue }
                if let max = script.maxDepth, max >= 0, depth > max { continue }
            }

            // 构造 findRegex（substituteRegex 宏替换）
            var findPattern = script.findRegex
            if script.substituteRegex > 0 && (!userName.isEmpty || !charName.isEmpty) {
                findPattern = MacroExpander.expandForRegex(
                    findPattern,
                    userName: userName,
                    charName: charName,
                    escape: script.substituteRegex == 2
                )
            }

            // 解析正则
            guard let (pattern, options) = parseRegex(findPattern) else { continue }

            do {
                let regex = try NSRegularExpression(pattern: pattern, options: options)
                let range = NSRange(result.startIndex..<result.endIndex, in: result)

                // 替换模板：{{match}} → $0
                let template = script.replaceString
                    .replacingOccurrences(of: "{{match}}", with: "$0", options: .caseInsensitive)

                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
            } catch {
                continue
            }

            // trimStrings
            for trim in script.trimStrings where !trim.isEmpty {
                result = result.replacingOccurrences(of: trim, with: "")
            }
        }

        // 最后对结果做宏替换
        if !userName.isEmpty || !charName.isEmpty {
            result = MacroExpander.expand(result, userName: userName, charName: charName)
        }

        return result
    }

    /// 正则页测试区用（卡库 ⑤b）：和 `apply` 同一套宏替换 + 解析 + 编译，编译失败返回错误说明；查找为空返回 nil
    static func compileError(for script: RegexScript, userName: String = "", charName: String = "") -> String? {
        var findPattern = script.findRegex
        if script.substituteRegex > 0 && (!userName.isEmpty || !charName.isEmpty) {
            findPattern = MacroExpander.expandForRegex(findPattern, userName: userName, charName: charName,
                                                       escape: script.substituteRegex == 2)
        }
        guard let (pattern, options) = parseRegex(findPattern) else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: options)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 解析酒馆格式正则：`/pattern/flags` → (pattern, NSRegularExpression.Options)
    private static func parseRegex(_ raw: String) -> (String, NSRegularExpression.Options)? {
        var input = raw.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return nil }

        guard input.hasPrefix("/") else {
            return (input, [])
        }

        input = String(input.dropFirst())

        guard let lastSlash = input.lastIndex(of: "/") else {
            return (input, [])
        }

        let pattern = String(input[input.startIndex..<lastSlash])
        let flags = String(input[input.index(after: lastSlash)...])

        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("x") { options.insert(.allowCommentsAndWhitespace) }
        // g = global，NSRegularExpression 默认全局替换

        return (pattern, options)
    }
}
