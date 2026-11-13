import MemoryCore
import Foundation

// MARK: - 同一次提交的来源检查、Coverage、Preservation：三条路（自动写手、手动 agent、种子）共用，只记进运行记录，不拦、不另调模型

enum CatalogDiagnostics {
    /// 写手自报：一份输入（f 编号 / 原料路径）写进了哪儿，或者为什么没写
    struct Coverage: Equatable, Decodable {
        var input: String
        var at: String?
        var why: String?

        private enum CodingKeys: String, CodingKey { case input, at, why }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = try c.decode(CatalogJSON.Label.self, forKey: .input).value
            at = CatalogDiagnostics.text(try? c.decodeIfPresent(String.self, forKey: .at))
            why = CatalogDiagnostics.text(try? c.decodeIfPresent(String.self, forKey: .why))
        }
    }

    /// 写手自报：旧「现在」里的一件事这次保留了、因新证据改了，还是疑似漏了
    struct Preservation: Equatable, Decodable {
        var page: String?
        var old: String
        var status: String
        var new: String?
        var why: String?

        private enum CodingKeys: String, CodingKey { case page, old, status, new, why }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            page = CatalogDiagnostics.text(try? c.decodeIfPresent(String.self, forKey: .page)).map(CatalogPrompts.normalizedPath)
            old = try c.decode(String.self, forKey: .old).trimmingCharacters(in: .whitespacesAndNewlines)
            status = try c.decode(String.self, forKey: .status).trimmingCharacters(in: .whitespacesAndNewlines)
            new = CatalogDiagnostics.text(try? c.decodeIfPresent(String.self, forKey: .new))
            why = CatalogDiagnostics.text(try? c.decodeIfPresent(String.self, forKey: .why))
        }
    }

    fileprivate static func text(_ raw: String??) -> String? {
        guard let t = raw??.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: 正文和诊断分开解析

    static let keys: Set<String> = ["coverage", "preservation"]

    /// 一份输出拆成正文和诊断两段，各自解析。
    /// bodies = 正文按顺序可试的文本：开头那个完整 JSON 对象；顶层碰到诊断键时，诊断键之前那几个键自成一个对象（诊断写在最后、坏了或被截断都不连累正文）。
    /// truncated = 输出被截断：只信诊断键之前那段。diagnostics = 正文后面的下一个 JSON 对象（中间隔着代码围栏、空行、说明文字都行），或对象里的诊断键
    static func split(_ raw: String, truncated: Bool = false) -> (bodies: [String], diagnostics: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>"), let end = text.range(of: "</think>") {
            text = text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("```") {
            text = String(text.drop { $0 != "\n" && $0 != "{" })
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bytes = Array(text.utf8)
        guard bytes.first == UInt8(ascii: "{") else { return (truncated ? [] : [raw], nil) }
        let (full, cut) = object(bytes, from: 0)
        let cutBody = cut.map { String(decoding: bytes[..<$0.comma], as: UTF8.self) + "}" }
        if truncated { return (cutBody.map { [$0] } ?? [], nil) }
        let whole = full.map { String(decoding: bytes[...$0], as: UTF8.self) }
        let bodies = [whole, cutBody].compactMap { $0 } + (whole == nil ? [raw] : [])
        guard let full else { return (bodies, nil) }
        if let next = bytes[(full + 1)...].firstIndex(of: UInt8(ascii: "{")) {
            let end = object(bytes, from: next).end ?? bytes.count - 1
            return (bodies, String(decoding: bytes[next...end], as: UTF8.self))
        }
        return (bodies, cut.map { "{" + String(decoding: bytes[$0.key...], as: UTF8.self) } ?? whole)
    }

    /// 从 start 那个「{」起找完整的 JSON 对象：end = 收尾的「}」（截断了 = nil）；cut = 顶层第一个诊断键前面那个逗号和键的位置
    private static func object(_ bytes: [UInt8], from start: Int) -> (end: Int?, cut: (comma: Int, key: Int)?) {
        var depth = 0, inString = false, escaped = false, expectKey = false
        var keyStart = start
        var lastComma: Int?
        var cut: (comma: Int, key: Int)?
        for i in bytes.indices where i >= start {
            let b = bytes[i]
            if inString {
                if escaped {
                    escaped = false
                } else if b == UInt8(ascii: "\\") {
                    escaped = true
                } else if b == UInt8(ascii: "\"") {
                    inString = false
                    if cut == nil, depth == 1, expectKey, let comma = lastComma,
                       keys.contains(String(decoding: bytes[(keyStart + 1)..<i], as: UTF8.self)) {
                        cut = (comma, keyStart)
                    }
                }
                continue
            }
            switch b {
            case UInt8(ascii: "\""):
                inString = true
                keyStart = i
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                expectKey = depth == 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return (i, cut) }
            case UInt8(ascii: ","):
                if depth == 1 {
                    lastComma = i
                    expectKey = true
                }
            case UInt8(ascii: ":"):
                if depth == 1 { expectKey = false }
            default:
                break
            }
        }
        return (nil, cut)
    }

    private struct Envelope: Decodable {
        let coverage: [CatalogJSON.Lossy<Coverage>]?
        let preservation: [CatalogJSON.Lossy<Preservation>]?

        private enum CodingKeys: String, CodingKey { case coverage, preservation }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            coverage = (try? c.decodeIfPresent(CatalogJSON.Container<[CatalogJSON.Lossy<Coverage>]>.self, forKey: .coverage))??.value
            preservation = (try? c.decodeIfPresent(CatalogJSON.Container<[CatalogJSON.Lossy<Preservation>]>.self, forKey: .preservation))??.value
        }
    }

    /// 诊断那一段：坏了、截断了就是 nil（记未评估）
    static func decode(_ text: String?) -> (coverage: [Coverage]?, preservation: [Preservation]?) {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let env = CatalogJSON.decode(Envelope.self, t) else { return (nil, nil) }
        return (env.coverage?.compactMap(\.value), env.preservation?.compactMap(\.value))
    }

    // MARK: 记进运行记录

    /// 记一节进运行记录，返回锚点。final = 交审的那一份（条目已是最终保留的）；否则标成中间稿。
    /// 输入清单 = 这次实际提供过的全部碎片编号和原料路径
    @discardableResult
    static func record(_ parsed: CatalogItems.Parsed, sources: CatalogSources, final: Bool, title: String, run: CatalogRunRecord) -> String {
        let head = final ? "交审诊断（只记日志，按最终交审的条目算）" : "中间稿诊断（只记日志；这一份不是最后交审的）"
        return run.section("\(title) · \(head)", body: "### 来源检查\n" + faithfulness(parsed)
            + "\n\n### Coverage\n" + coverage(parsed, sources: sources)
            + "\n\n### Preservation\n" + preservation(parsed))
    }

    static func faithfulness(_ parsed: CatalogItems.Parsed) -> String {
        let lines = parsed.items.reduce(0) { n, item in
            switch item.change {
            case .newPage(let page): return n + page.records.count
            case .appendRecords(_, let added): return n + added.count
            default: return n
            }
        }
        let head = "留下 \(parsed.items.count) 条条目、\(lines) 行带出处的记录（出处只认这次实际给模型的原料，不等于事实验真）。"
        guard !parsed.dropReasons.isEmpty else { return head + "\n没丢。" }
        return head + "\n丢了 \(parsed.dropReasons.count) 处：\n" + parsed.dropReasons.map { "- " + $0 }.joined(separator: "\n")
    }

    /// 这次实际提供过的输入：碎片按编号顺序，原料按路径
    static func inputs(_ sources: CatalogSources) -> [String] {
        func number(_ label: String) -> Int { Int(label.dropFirst()) ?? .max }
        return sources.fragments.keys.sorted { (number($0), $0) < (number($1), $1) } + sources.files.keys.sorted()
    }

    static func coverage(_ parsed: CatalogItems.Parsed, sources: CatalogSources) -> String {
        let attached = Set(parsed.items.flatMap { $0.fragmentIds + ($0.covered ?? []) })
        let cited = parsed.items.flatMap(\.cites)
        let single = Set(parsed.single)
        /// nil = 不是这次给的输入
        func landed(_ input: String) -> Bool? {
            if let f = sources.fragments[input] { return attached.contains(f.id) }
            if let file = sources.files[input] { return cited.contains(file.cite) }
            return nil
        }
        var hit: [String] = [], notCovered: [String] = [], refuted: [String] = [], foreign: [String] = [], singles: [String] = []
        var told = Set<String>()
        for c in parsed.coverage ?? [] {
            guard let ok = landed(c.input) else {
                foreign.append("- \(c.input)")
                continue
            }
            told.insert(c.input)
            if let at = c.at {
                if ok {
                    hit.append("- \(c.input)：「\(at)」")
                } else {
                    refuted.append("- \(c.input)：写手说在「\(at)」，交审条目上没挂它（对应的行被丢了、没写、被门槛过滤，或写进「现在」没带编号）")
                }
            } else {
                notCovered.append("- \(c.input)" + (c.why.map { "：\($0)" } ?? "（没说原因）"))
            }
        }
        var silent: [String] = []
        for input in inputs(sources) where !told.contains(input) {
            if let f = sources.fragments[input], single.contains(f.id) {
                singles.append("- \(input)")
            } else {
                silent.append(input)
            }
        }
        var out = ["写手自报的去向，只当线索：编号挂在交审条目上，不等于这条输入的意思已经写全。"]
        if parsed.coverage == nil { out.append("这次没有可用的 coverage（没交、被截断或坏了）：全部算没交代。") }
        func group(_ title: String, _ lines: [String]) {
            if !lines.isEmpty { out.append(title + "：\n" + lines.joined(separator: "\n")) }
        }
        group("写进了页（交审条目上挂着）", hit)
        group("声明了没覆盖", notCovered)
        group("说写进了但不算覆盖", refuted)
        group("判单条就够、不进页", singles)
        if !silent.isEmpty { out.append("没交代（未评估）：" + silent.joined(separator: "、")) }
        group("不是这次给的输入，不算", foreign)
        return out.joined(separator: "\n")
    }

    static func preservation(_ parsed: CatalogItems.Parsed) -> String {
        let rewrites = parsed.items.compactMap { item -> (path: String, old: String, new: String)? in
            guard case .rewriteNow(let path, let old, let new, _) = item.change else { return nil }
            return (path, old, new)
        }
        let claims = parsed.preservation ?? []
        func line(_ p: Preservation) -> String {
            "- \(p.status)：\(p.old)" + (p.new.map { " → \($0)" } ?? "") + (p.why.map { "（\($0)）" } ?? "")
        }
        guard !rewrites.isEmpty else {
            return "这次没改已有页的「现在」，不用对照。" + (claims.isEmpty ? "" : "\n写手另外交代了：\n" + claims.map(line).joined(separator: "\n"))
        }
        var out = ["写手自报，代码不做字符串比对；疑似漏了也照样交审计台 › wiki › 整理提案。"]
        for r in rewrites {
            out.append("#### \(r.path)\n旧「现在」：\n\(CatalogRunRecord.code(r.old))\n新「现在」：\n\(CatalogRunRecord.code(r.new))")
            let mine = claims.filter { $0.page == r.path || ($0.page == nil && rewrites.count == 1) }
            if parsed.preservation == nil {
                out.append("未评估：这次没有可用的 preservation（没交、被截断或坏了）。")
            } else if mine.isEmpty {
                out.append("未评估：写手没说明这页旧事实的去向。")
            } else {
                out.append(mine.map(line).joined(separator: "\n"))
            }
        }
        return out.joined(separator: "\n\n")
    }
}

extension CatalogPrompts {
    /// 两样诊断（只记日志，写不写都不影响条目收不收）。standalone = 写手：跟在正文对象后面另输出一个对象；否则写在 submit_proposal 参数最后。
    /// seed = 输入是这一项目录的原料路径
    static func diagnostics(names: MemoryExtractor.Names, standalone: Bool, seed: Bool = false) -> String {
        let input = seed ? "这一项目录用到的每份原料（路径）" : "这次给你的每条碎片（f 编号）"
        let now = seed ? "" : "写进「现在」的，在那一条 new_page / rewrite_now 上也写 \"fragments\":[\"f3\"]。"
        let place = standalone
            ? "正文对象交完后，另起一行可以再输出一个诊断对象 {\"coverage\":[…],\"preservation\":[…]}"
            : "submit_proposal 参数里可以再带 coverage、preservation，写在所有正文字段之后"
        return """
        诊断（\(place)）：
        coverage：\(input)各写一条，写进了哪儿，或者为什么没写：{"input":"\(seed ? "memory/cc/user_ship.md" : "f3")","at":"人/星砚 · 记录"}、{"input":"\(seed ? "memory/cc/user_misc.md" : "f4")","why":"只是随口一提"}。\(now)
        preservation（交了 rewrite_now 才写）：对照那一页旧的「现在」，旧事实一件一条：还在的写 {"page":"…","old":"旧事实","status":"保留"}；有新证据改了的写 "status":"改了","new":"新说法","why":"哪条新原料"；新「现在」里没有、也没有新证据的写 "status":"疑似漏了"。
        正文优先：篇幅不够就整段省略诊断，不要为了诊断少写正文。诊断只给\(names.user)看，照实写，没把握的就写没把握。
        """
    }
}
