import Foundation

/// 模型分拣（C3 页「分拣：模型」，默认是代码）：模型读碎片和此刻实际的 wiki 索引，逐条判归哪页 / 开新页 / 单条就够 / 暂存。
/// 代码只查判得准的：能解析、每条都判了、page 在索引里、new 的类和路径合法、已有页不当新页；不过给一次重写，再不过本轮不提方向。
/// 新页同一路径下凑够 3 条才提；不够的和暂存的留在池里下次再判。timeline_proposals（A4 时间轴的新话题）照同样的规矩核，交成只来自时间轴的开页方向
enum CatalogModelSorter {
    struct Sorted: Equatable, Sendable {
        var grouped: CatalogSorter.Grouped
        var single: [UUID] = []
        /// 暂存、或新页还不到 3 条的：留在池里
        var waiting = 0
    }

    struct Reply: Decodable {
        struct New: Decodable {
            let kind: String
            let title: String?
            let path: String
            let aliases: [String]?
        }

        struct Verdict: Decodable {
            let f: CatalogJSON.Label
            let page: String?
            let new: New?
            let single: Bool?
            let stash: String?
            let why: String?
        }

        struct Proposal: Decodable {
            let kind: String
            let title: String?
            let path: String
            let aliases: [String]?
            let reason: String?
            let days: [String]?
        }

        let fragments: [Verdict]
        let timelineProposals: [Proposal]?

        private enum CodingKeys: String, CodingKey {
            case fragments
            case timelineProposals = "timeline_proposals"
        }
    }

    /// 时间轴这几天都没有话题（A4 关着、没准备好、没聊）
    static let timelineNone = "暂无"

    /// 「A4 时间轴」那一栏：最近几天每天的话题词（A4 一天一条那次顺带给的）
    static func timelineText(_ days: [CatalogTimeline.Day]) -> String {
        let shown = days.filter { !$0.topics.isEmpty }
        guard !shown.isEmpty else { return timelineNone }
        return shown.map { "- \($0.date) · 话题：" + $0.topics.joined(separator: "、") }.joined(separator: "\n")
    }

    static func system(names: MemoryExtractor.Names) -> String {
        let u = names.user
        return """
        这不是在跟你聊天。你在给 \(u) 和 \(names.char) 的记忆 wiki 做分拣和提案。

        ## 你的工作

        逐条看碎片，同时扫时间轴。对每条碎片做一个判断：归到已有页 / 提案开新页 / 单条就够 / 暂存。同时检查时间轴里有没有 wiki 还没覆盖的新话题。

        ## 输入

        1. 碎片（subject / content / tags / speaker）：这次新来的，加上以前暂存、还没归页的
        2. A4 时间轴（最近几天每天的话题词；没有就写「暂无」）
        3. wiki 索引（此刻实际有的页：路径 + 标题 + 别名 + 钩子）。wiki 是 \(u) 的，页随时会被新建、改名、删掉、改触发词；只认这次给的索引，不要假设还有别的页

        ## 八类

        用户 / 人 / 物 / 地点 / 时间 / 事 / 项目 / 主题

        用户 = \(u) 本人。页挂在 楼层/\(u)/ 下，怎么分页看索引里现有的页；没有合适的就提开新页，按这条说的方面自己起页名。
        人 = \(u) 认识的人。一人一页。
        项目 = \(u) 在做的事。一个项目一页。
        事 = 跨很多天的一件事（一场 drama、一次搬家），有起因经过结果。
        主题 = \(u) 关注的领域（学日语、投资）。
        物 / 地点 / 时间 = 字面意思。

        路径写成「支 / 分组 / 页名」，第一段只能是「工程」或「楼层」：工程 = 项目、代码、app；楼层 = \(u) 本人、你们之间、生活里的人事物。


        ## 分拣决策树（每条碎片按顺序走，命中就停）

        ### 第一步：对照 wiki 索引，这条说的是哪个东西、哪个话题？

        先看 subject：它等于某页的标题 / 别名，是很强的线索，但不是标准答案——subject 可能写偏、同一个东西可能有好几个叫法。再结合 tags、content 和索引里每页的标题、别名、钩子，判断这条碎片说的是谁 / 什么、讲的是哪个话题。

        → 说的就是索引里某一页的那个东西 / 话题 → 归到那一页。结束。
        → 没有对应的页 → 走第二步。

        ⚠ 按「说的是谁 / 什么」归，不按 content 里碰巧出现的某个词归（见正反例「饼干」）。
        ⚠ 说的是 \(u) 本人 → 走第二步。

        ### 第二步：\(u) 本人的页

        subject 指向 \(u) 本人时，对照索引里现有的 楼层/\(u)/ 下的页，用 tags 和 content 判断这条说的是哪一方面：

        → 索引里有讲这一方面的页 → 归到那一页。结束。
        → 没有合适的页 → 这是一个新东西（kind = 用户，path = 楼层/\(u)/页名），走第三步。

        ⚠ 有更具体的页就归更具体的，不要全堆到一页。

        ### 第三步：新东西够不够 3 条？

        这批碎片里（含以前暂存的）说的是同一个新东西的，一共几条？叫法不同但说的是同一个东西也算同一个；\(u) 本人的新页按同一方面算。

        → ≥ 3 条 → 每条都写 new，用同一个 path，提案开新页。
        → 不到 3 条 → 走第四步。

        ### 第四步：single 还是暂存？

        同时满足以下三条 → single（单条就够，不进 wiki）：
        1. 几乎不变的事实（生日、血型、"喜欢蓝色"这种）
        2. 自己就完整（不需要其他碎片补充上下文）
        3. 不属于任何已有页的话题范围

        三条有任何一条不满足 → 暂存（攒到同一个东西凑够 3 条再开页）。

        ⚠ 宁可暂存不要乱 single。
        ⚠ 如果碎片说的是「会变的状态」（在吃的药、项目进度、当前住址），不能 single——它需要进某页的「现在」段，以后会被更新。


        ## 时间轴提案

        扫完碎片后，扫时间轴。检查：

        时间轴里连续 ≥2 天出现的话题/人名/项目名 + wiki 索引里没有对应页 + 碎片里也没有覆盖
        → 提案开新页（放进 timeline_proposals）。

        时间轴里只出现 1 天的 → 不提案（可能是一次性话题）。时间轴「暂无」→ timeline_proposals 写空数组。


        ## 正反例

        ### 归到已有页
        碎片 subject="饼干" content="又胖了半斤" → wiki 索引有"楼层/人/饼干" → 说的是饼干 → 归到 楼层/人/饼干 ✓
        ✗ 看到"胖"就归到 楼层/\(u)/身体（那是 \(u) 的身体页，饼干是猫）

        碎片 subject="橘子" content="饼干（大名橘子）今天又胖了" → 索引里"楼层/人/饼干"的别名、钩子说的是同一只猫 → 归到 楼层/人/饼干 ✓
        ✗ 因为 subject 不等于"饼干"就当成新东西暂存

        ### \(u) 本人的页
        索引里 楼层/\(u)/ 下有：楼层/\(u)/概要、楼层/\(u)/身体
        碎片 subject="\(u)" content="对花生过敏" tags=["过敏","身体"]
        → subject 是 \(u) → 对照现有的页 → 说的是身体 → 归到 楼层/\(u)/身体 ✓
        ✗ 归到 楼层/\(u)/概要（有更具体的页）
        ✗ 开新页"过敏"（不是新话题，是身体页的内容）

        ### 开新页
        碎片 f1 subject="田中老师" content="日语课老师"
        碎片 f2 subject="田中老师" content="每周三上课"
        碎片 f3 subject="田中老师" content="布置了 N2 模拟题"
        → wiki 索引无"田中老师" → 这批同 subject 3 条 → f1、f2、f3 都写 new 楼层/人/田中老师 ✓
        ✗ 只有 f1、f2 两条时就开页（不到 3 条，暂存）

        ### single
        碎片 subject="\(u)" content="生日是 12 月 3 日" tags=["生日"]
        → 几乎不变 ✓ 自己完整 ✓ 不属于已有页话题？
        → 检查：索引里有 楼层/\(u)/概要 → 生日属于概要话题 → 不满足第三条 → 归到 楼层/\(u)/概要，不 single ✓
        ✗ 标 single（生日应该写进概要页）

        碎片 subject="\(u)" content="血型是 O 型" tags=["血型"]
        → 几乎不变 ✓ 自己完整 ✓ 索引里没有讲 \(u) 基本情况的页 ✓
        → single ✓

        ### 时间轴提案
        时间轴：10-20 毕设、10-21 毕设进度、10-22 毕设赶工
        wiki 索引：无"毕设"相关页
        → 连续 3 天 → 提案 timeline_proposals: 楼层/项目/毕设，days 写 10-20、10-21、10-22 三天 ✓

        ### 同 subject 分到 \(u) 的不同页
        索引里有：楼层/\(u)/身体、楼层/\(u)/偏好、楼层/\(u)/计划
        碎片 f1 subject="\(u)" content="花生过敏" tags=["过敏","身体"]  → 楼层/\(u)/身体
        碎片 f2 subject="\(u)" content="喜欢侘寂风" tags=["审美","偏好"]  → 楼层/\(u)/偏好
        碎片 f3 subject="\(u)" content="想跳槽做产品" tags=["计划","工作"]  → 楼层/\(u)/计划
        → 三条都是 subject="\(u)"，但说的方面不同，分到三页 ✓
        ✗ 全归到一页（索引里有更具体的页时不要堆在一起）


        ## 输出格式

        只输出一个 JSON 对象，不要别的字：
        {"fragments":[
          {"f":"f1","page":"楼层/\(u)/身体","why":"说的是 \(u) 的花生过敏"},
          {"f":"f2","new":{"kind":"人","title":"田中老师","path":"楼层/人/田中老师","aliases":["田中","日语老师"]},"why":"日语课老师，第 3 条了"},
          {"f":"f3","single":true},
          {"f":"f4","stash":"饼干"}
        ],
        "timeline_proposals":[
          {"kind":"项目","title":"毕设","path":"楼层/项目/毕设","days":["2026-10-20","2026-10-21","2026-10-22"],"reason":"时间轴连续3天出现毕设但wiki无此页"}
        ]}

        - 每条碎片必须有 f 编号 + page / new / single / stash 四选一
        - page 照抄 wiki 索引里的路径
        - new 必须有 kind / title / path（aliases 可选）；kind 是八类之一，path 第一段是 工程 或 楼层；同一个 path 的几条 new，kind 和 title 写成一样
        - why 可选：一句话说为什么这样判（归页、开新页时写），给 \(u) 审批时看
        - stash 的值 = 这个新东西的名字（暂存到凑够 3 条）
        - timeline_proposals 可以为空数组；每条要有 kind / title / path / days，kind 是八类之一、path 第一段是 工程 或 楼层、索引里还没有这页；days 照抄时间轴里依据的那几天日期
        - 同一个主题只用一个目标：碎片归的页 / 开的新页和 timeline_proposals 说的是同一个东西时，用同一个 path，标题写成一样

        ## 检查清单

        □ JSON 能 parse？
        □ 每条碎片都有判断（page / new / single / stash）？没有遗漏的碎片？
        □ page 指向的路径在 wiki 索引里存在？
        □ new 的 kind 是八类之一（用户 / 人 / 物 / 地点 / 时间 / 事 / 项目 / 主题）、path 第一段是 工程 或 楼层？
        □ subject 是 \(u) 名字的碎片都对照了 楼层/\(u)/ 下现有的页？没有全堆到一页？
        □ single 的碎片同时满足三条（不变+完整+不属于已有页）？
        □ 「会变的状态」没有被标 single？
        """
    }

    static func user(_ pool: [CatalogFragment], pages: [WikiInjectionSnapshot.Page], timeline: [CatalogTimeline.Day] = []) -> String {
        let fragments = pool.enumerated().map { i, f in
            "- \(CatalogSorter.label(i)) · \(f.day) · subject：\(f.subject ?? "未知") · speaker：\(f.speaker ?? "未知") · tags："
                + (f.keywords.isEmpty ? "无" : f.keywords.joined(separator: "、")) + " · \(f.content)"
                + (f.organizedAt != nil ? "（以前判过单条就够）" : "")
        }
        let index = pages.map { p in
            "- \(p.path) · 标题：\(p.title)" + (p.triggers.isEmpty ? "" : " · 别名：" + p.triggers.joined(separator: "、"))
                + (p.hook.isEmpty ? "" : " · 钩子：\(p.hook)")
        }
        return [
            "【碎片】（共 \(pool.count) 条）\n" + fragments.joined(separator: "\n"),
            "【A4 时间轴】\n" + timelineText(timeline),
            "【wiki 索引】（此刻实际有的页，共 \(pages.count) 页）\n" + (index.isEmpty ? "（wiki 还是空的）" : index.joined(separator: "\n")),
        ].joined(separator: "\n\n")
    }

    /// 只查代码判得准的；不过把每条原因一起交回（重写时回灌给模型）
    static func check(_ raw: String, pool: [CatalogFragment], pages: [WikiInjectionSnapshot.Page],
                      timeline: [CatalogTimeline.Day] = []) -> Result<Sorted, CatalogJSON.Failure> {
        let reply: Reply
        do {
            reply = try CatalogJSON.decodeValue(Reply.self, FragmentPool.strictObjectText(raw) ?? raw)
        } catch {
            return .failure(.init(message: "不是合格的 JSON 对象：" + ((error as? CatalogJSON.Failure)?.message ?? error.localizedDescription)))
        }
        let labels = pool.indices.map(CatalogSorter.label)
        let byLabel = Dictionary(uniqueKeysWithValues: zip(labels, pool))
        let byPath = Dictionary(pages.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var problems: [String] = []
        var seen = Set<String>()
        var order: [String] = []
        var groups: [String: CatalogSorter.Topic] = [:]
        var whys: [String: [String]] = [:]
        var single: [UUID] = []
        var waiting = 0
        func note(_ why: String?, _ path: String) {
            guard let why = why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty, !(whys[path] ?? []).contains(why) else { return }
            whys[path, default: []].append(why)
        }
        for v in reply.fragments {
            let label = v.f.value
            guard let fragment = byLabel[label] else { problems.append("\(label)：没有这条碎片"); continue }
            guard seen.insert(label).inserted else { problems.append("\(label)：判了不止一次"); continue }
            guard [v.page != nil, v.new != nil, v.single == true, v.stash != nil].filter({ $0 }).count == 1 else {
                problems.append("\(label)：page / new / single / stash 必须正好写一个")
                continue
            }
            if let raw = v.page {
                let path = CatalogPrompts.normalizedPath(raw)
                guard let page = byPath[path] else { problems.append("\(label)：page「\(raw)」不在 wiki 索引里"); continue }
                if groups[path] == nil {
                    order.append(path)
                    groups[path] = .init(path: path, title: page.title, kind: nil, aliases: page.triggers, existing: true)
                }
                groups[path]!.fragmentIds.append(fragment.id)
                note(v.why, path)
            } else if let new = v.new {
                let path = CatalogPrompts.normalizedPath(new.path)
                guard let kind = WikiPage.Kind(rawValue: new.kind.trimmingCharacters(in: .whitespaces)) else {
                    problems.append("\(label)：new 的 kind「\(new.kind)」不是八类之一（用户 / 人 / 物 / 地点 / 时间 / 事 / 项目 / 主题）")
                    continue
                }
                guard WikiStore.isValidPagePath(path) else { problems.append("\(label)：new 的 path「\(new.path)」不合法（第一段只能是工程或楼层）"); continue }
                guard byPath[path] == nil else { problems.append("\(label)：「\(path)」已经有这页，应该写 page"); continue }
                let title = new.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { problems.append("\(label)：new 缺 title"); continue }
                if let first = groups[path] {
                    guard first.kind == kind, first.title == title else {
                        problems.append("\(label)：同一个 path「\(path)」的 new，kind / title 和前面的不一致（前面是 \(first.kind?.rawValue ?? "")「\(first.title)」）")
                        continue
                    }
                } else {
                    order.append(path)
                    groups[path] = .init(path: path, title: title, kind: kind, existing: false)
                }
                groups[path]!.aliases = WikiStore.normalizedWords(groups[path]!.aliases + (new.aliases ?? []))
                groups[path]!.fragmentIds.append(fragment.id)
                note(v.why, path)
            } else if v.single == true {
                single.append(fragment.id)
            } else {
                waiting += 1
            }
        }
        let missing = labels.filter { !seen.contains($0) }
        if !missing.isEmpty { problems.append("没判：" + missing.joined(separator: "、")) }
        let proposals = reply.timelineProposals ?? []
        let hasTimeline = timelineText(timeline) != timelineNone
        if !hasTimeline, !proposals.isEmpty { problems.append("timeline_proposals：时间轴是「暂无」，应该写空数组") }
        var fromTimeline: [CatalogSorter.Topic] = []
        for (i, tp) in proposals.enumerated() where hasTimeline {
            let at = "timeline_proposals[\(i)]"
            let path = CatalogPrompts.normalizedPath(tp.path)
            guard let kind = WikiPage.Kind(rawValue: tp.kind.trimmingCharacters(in: .whitespaces)) else {
                problems.append("\(at)：kind「\(tp.kind)」不是八类之一（用户 / 人 / 物 / 地点 / 时间 / 事 / 项目 / 主题）")
                continue
            }
            guard WikiStore.isValidPagePath(path) else { problems.append("\(at)：path「\(tp.path)」不合法（第一段只能是工程或楼层）"); continue }
            guard byPath[path] == nil else { problems.append("\(at)：「\(path)」已经有这页，不用提开页"); continue }
            let title = tp.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { problems.append("\(at)：缺 title"); continue }
            let given = Set(timeline.map(\.date))
            let days = WikiStore.normalizedWords(tp.days ?? [])
            guard !days.isEmpty else { problems.append("\(at)：days 要写依据的日期（照抄时间轴里的）"); continue }
            let unknown = days.filter { !given.contains($0) }
            guard unknown.isEmpty else { problems.append("\(at)：days 里的「\(unknown.joined(separator: "、"))」时间轴里没有"); continue }
            if let g = groups[path], g.fragmentIds.count >= CatalogSorter.newPageThreshold { continue }
            guard !fromTimeline.contains(where: { $0.path == path }) else { continue }
            var t = CatalogSorter.Topic(path: path, title: title, kind: kind, aliases: WikiStore.normalizedWords(tp.aliases ?? []), existing: false)
            let why = tp.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            t.reason = "模型 · A4 时间轴：提开新页（\(kind.rawValue)）" + (why.isEmpty ? "" : "——\(why)")
                + "；只来自时间轴：批了就开页，不用凑 \(CatalogSorter.newPageThreshold) 条碎片"
            t.days = days.sorted()
            fromTimeline.append(t)
        }
        var targets: [String: [String]] = [:]
        var shown: [String: String] = [:]
        var opening = Set<String>()
        for t in order.compactMap({ groups[$0] }) + fromTimeline {
            let k = CatalogSorter.key(t.title)
            shown[k] = shown[k] ?? t.title
            if !t.existing { opening.insert(k) }
            if !(targets[k] ?? []).contains(t.path) { targets[k, default: []].append(t.path) }
        }
        for (k, paths) in targets.sorted(by: { $0.key < $1.key }) where paths.count > 1 && opening.contains(k) {
            problems.append("「\(shown[k]!)」用了不止一个目标（\(paths.joined(separator: "、"))）：同一个主题统一成一个 path，碎片和 timeline_proposals 都用它")
        }
        guard problems.isEmpty else { return .failure(.init(message: problems.joined(separator: "\n"))) }
        let fresh = Set(pool.filter { $0.organizedAt == nil }.map(\.id))
        var topics: [CatalogSorter.Topic] = []
        for path in order {
            var t = groups[path]!
            if !t.existing, t.fragmentIds.count < CatalogSorter.newPageThreshold {
                waiting += t.fragmentIds.count
                continue
            }
            let said = (whys[path] ?? []).prefix(3).joined(separator: "；")
            t.reason = "模型：" + (t.existing ? "归到这页" : "提开新页（\(t.kind?.rawValue ?? "")）") + (said.isEmpty ? "" : "——\(said)")
            if t.fragmentIds.contains(where: fresh.contains) { topics.append(t) }
        }
        return .success(Sorted(grouped: .init(topics: CatalogSorter.ordered(topics), unclear: 0, timeline: fromTimeline),
                               single: single.filter(fresh.contains), waiting: waiting))
    }

    /// 上次成功分拣、且方向都存下了的输入指纹（碎片 + 实时索引 + 模型 + 提示词）：完全一样就不再付费重判；任何一样变了就失效
    static func fingerprint(_ pool: [CatalogFragment], pages: [WikiInjectionSnapshot.Page], timeline: [CatalogTimeline.Day] = [],
                            names: MemoryExtractor.Names, model: String) -> String {
        WikiStore.version(of: Data([system(names: names), user(pool, pages: pages, timeline: timeline), model].joined(separator: "\u{0}").utf8))
    }

    static func fingerprintURL(_ wiki: WikiStore) -> URL {
        wiki.root.appendingPathComponent(".sort", isDirectory: true).appendingPathComponent("fingerprint.txt")
    }

    static func lastFingerprint(_ wiki: WikiStore) -> String? {
        (try? Data(contentsOf: fingerprintURL(wiki))).map { String(decoding: $0, as: UTF8.self) }
    }

    static func remember(_ fingerprint: String, wiki: WikiStore) {
        try? WikiStore.writeAtomic(Data(fingerprint.utf8), to: fingerprintURL(wiki))
    }

    /// 一次调用 + 不过给一次重写（回灌原因）；nil = 预算闸 / 空输出；两次都不过抛 `.format`
    static func run(_ pool: [CatalogFragment], pages: [WikiInjectionSnapshot.Page], timeline: [CatalogTimeline.Day] = [],
                    names: MemoryExtractor.Names, caller: SessionSegmentWriter.Caller, drafts: CatalogDrafts?, cancel: CatalogCancel? = nil,
                    run: CatalogRunRecord? = nil) async throws -> Sorted? {
        let system = system(names: names)
        let user = user(pool, pages: pages, timeline: timeline)
        var note = ""
        for attempt in 0...1 {
            try cancel?.check()
            let round = "模型分拣 · 第 \(attempt + 1) 次"
            let reply = try await CatalogJSON.request(system: system, user: attempt == 0 ? user : user + CatalogJSON.retryNote + "\n" + note,
                                                      caller: caller, run: run, name: round)
            try cancel?.check()
            guard let raw = reply else { return nil }
            let checked = await Task.detached(priority: .utility) {
                drafts?.save(raw, name: attempt == 0 ? "模型分拣" : "模型分拣-重写")
                return check(raw, pool: pool, pages: pages, timeline: timeline)
            }.value
            switch checked {
            case .success(let sorted):
                run?.section("\(round) · 校验", body: "通过。")
                return sorted
            case .failure(let failure):
                note = failure.message
                run?.section("\(round) · 校验", body: "没过：\n" + CatalogRunRecord.code(failure.message)
                    + (attempt == 0 ? "\n\n给一次重写，把上面的原因回灌。" : "\n\n重写也没过，本轮不提方向。"))
                CacheDiagLog.shared.log("📚 整理编目: 模型分拣没过校验，" + (attempt == 0 ? "重写" : "本轮不提方向"))
            }
        }
        throw MemoryWriterError.format("模型分拣两次都没过校验：\(note)")
    }
}
