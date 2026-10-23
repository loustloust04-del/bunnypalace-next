import Foundation

/// 告诉模型怎么写聊天卡片（research-chat-cards §4.7）。只列已实现类型；固定文字放历史之前，不破坏缓存前缀。
/// CC 会话不走 system（sendCCFireAndForget 只发最后一条 user）：CC 版在 cc-bridge/card-guide.ts，经 MCP instructions 注入（§9），两边同改。
enum ChatCardPromptGuide {
    /// 测试对照用；产品代码不改它
    nonisolated(unsafe) static var isEnabledForTesting = true

    static let text = """
    [聊天卡片]
    对话界面能把特定代码块渲染成可交互的卡片。需要时直接在回复里写这样的代码块：

    ```card-todo
    {"id":"t-xxxx","title":"周末","items":[{"text":"买牛奶","done":false}]}
    ```

    - 代码块语言名要写全：```card-todo、```card-dice、```card-timer、```card-chart、```card-music、```card-ask、```card-word、```card-timeline（不要只写 music / chart）。
    - card-todo：待办清单。字段 id（字符串）、title（可空）、items（每项 text + done）、date（可选，yyyy-MM-dd，对方加进待办时排在哪天，不写就是当天）。对方可以一键把整张卡加进自己的待办；加进去之后对方勾选会以 [附带事件] 告诉你，以事件为准，不用为了同步勾选再发新卡。
    - card-dice：骰子。要掷骰子 / 抽签时调用 roll_dice 工具（真随机），它返回一段 card-dice 代码块和一行结果摘要，把代码块原样放进回复；不要自己编结果。对方发来还没掷的骰子卡、让你替 TA 掷时，把那张卡的 id 传给 roll_dice（连同它的 dice 或 options、title），结果就落在原卡上。没有 roll_dice 工具时，发不带 result 的卡让对方自己掷：数字骰 {"id":"d-xxxx","title":"…","dice":"2d6+1"}（NdM±K，N 1–20，M 2–1000，K 不超过 1000），选项抽签 {"id":…,"title":…,"options":["A","B"]}。
    - card-timer：倒计时 {"id":"c-xxxx","title":"泡面","seconds":180,"autoStart":true}。autoStart 为 true 时从这条消息发出起开始计时（默认），false 时等对方点开始。时间到时对方会收到提醒，并自动发一条「⏰ 计时结束」给你。
    - card-chart：图表 {"id":"g-xxxx","type":"bar","title":"写结论，如：周三睡得最少","subtitle":"可空：怎么读，如「一格 = 1 小时」","source":"可空：数据来源","unit":"小时","series":[{"name":"睡眠","points":[["周一",7.5],["周二",6]]}]}。type 为 bar（对比，一格一格能数的梯格柱）/ line（趋势，发丝折线）/ pie（占比，一圈 100 格，只能 1 条系列、数值不为负）；series 最多 4 条，每条最多 60 个 [标签, 数值]，同一条里标签不重复。title 写看出来的结论，不写「柱状图」。数据要真实，不确定就别画。
      对方能点图例开关系列、点多时切「近 7 / 近 30」、选中一项点「问问这个」把它引用给你接着问。
      试算（bar / line）：不给 series，改给 params（滑块，最多 4 个，如 {"key":"m","label":"每月存","min":100,"max":5000,"step":100,"value":1000,"unit":"元"}）、x（{"from":1,"to":12,"label":"第{x}月"}，最多 60 个点）、formulas（[{"name":"余额","y":"m*x*(1+r/100*x/24)"}]，最多 4 条；只能用数字、+ - * / ^、括号、x、参数 key 和 min max round abs sqrt）。对方拖滑块，图当场重算。
      更多 type（各自只认自己的数据）：area 发丝面积（同 line，看形态）/ hbar 横条排名（≤2 条、≤12 类）/ stack 堆叠（series = 各段，≤12 类、不为负）/ diverging 正负条（1 条，可负，≤16 行）/ hundred 百格占比（1 条、≤6 类）/ barcode 条码（1 条，≤120 天）/ stream 河流构成随时间（2–5 条、不为负）/ calendar 一整年日历 {"days":[["2026-01-01",3],…]}（≤370 天）/ heat 点阵热力 {"rows":["周一",…],"cols":["9点",…],"values":[[…],…]}（≤8×24）/ candle K 线 {"candles":[["10-01",开,高,低,收],…]} / dumbbell 前后对比 {"pairNames":["改版前","改版后"],"pairs":[["邀请",14,6],…]}（≤8 行）。
      还有：scatter 散点 {"xLabel":"价格","yLabel":"满意度","points":[["名字",x,y],…]}（≤40）/ histogram 直方（1 条，标签 = 分箱）/ box 箱线 {"groups":[["组名",[原始值…]],…]}（≤6 组）/ waterfall 瀑布（1 条：首项起点、之后带符号增减，"total":"净利" 末尾补合计）/ gauge 进度表盘 {"value":73,"target":100} / funnel 漏斗（1 条，按步骤顺序）/ treemap 矩形树 {"groups":[{"name":"住","items":[["房租",4200],…]},…]}（≤30 格）。选图：比大小 bar / hbar，看趋势 line / area，占比 pie / hundred，构成 stack / stream，前后对比 dumbbell，分布 histogram / box / scatter，增减分解 waterfall，进度 gauge，转化 funnel，层级份额 treemap。
    - card-music：音乐 {"id":"m-xxxx","title":"歌名","artist":"歌手","cover":"https://…","url":"https://…mp3","link":"https://…"}。url 只能是 https 的直链音频文件（mp3 / m4a / aac / wav），没有就不写，只给 link（歌曲页面）；不要编造链接。内置曲：url 写 builtin:slowtide 是「慢潮」（1 分 36 秒的舒缓电子小曲，app 本地合成、不联网），只在对方想随便听点什么、或想听你的曲子时用，title 写「慢潮」；对方点名某首歌而你没有直链时只给 link，不要用内置曲代替。对方点开始才播放，不会发消息给你。
    - card-word：生词卡 {"word":"ephemeral","note":"可选：语境或提示"}。会显示词典音标和释义、对方生词本里的状态，对方能加入词库、标认识、打开词条（点了会以 [附带事件] 告诉你）。不需要 id；一张卡一个词，释义不用你写。
    - card-timeline：时间线 {"id":"l-xxxx","title":"这周","items":[{"time":"周一 10-01","title":"做完网页卡","note":"可选","at":"2026-10-01","quote":"可选：原话里的一句"}]}。把一串事件或计划排在一条线上（这周安排、一件事怎么推进的），1–30 项，按时间先后写。at 写 yyyy-MM-dd 或 yyyy-MM-ddTHH:mm，app 据此分已过去 / 还没到并画「现在」线；没有具体日期可写 "done":true/false。quote 写对话里某条消息的一句原话，对方点这项会跳过去。只读，对方不能在卡上改。
    - card-ask：向对方提问的卡。想让对方在几个方向里挑一个（选项模式 {"id":"q-xxxx","question":"…","options":["A","B"],"multi":false}，options 2–6 个，multi 为 true 时可多选），或要对方填一个具体值（问答模式 {"id":"q-xxxx","question":"…","placeholder":"…"}）时用。对方答完，卡会带着 picked（选中的下标）或 answer 发回来。闲聊和答案显而易见的问题别用。有 ask_user 工具时，只是让对方在几个选项里点一个就用 ask_user；card-ask 留给要对方填值、填表、填敏感值的时候。
      要对方填密码、token 这类敏感值时加 "secure":true。对方填完 answer 是 {{secret:…}} 占位，你看不到真值；需要用时把占位原样写进 run_command 或 MCP 工具的参数，app 执行前会征得对方同意再替换。不要让对方用明文告诉你。加密卡可以带 site（网址），会显示在卡上和输入单子上方。
      要对方一次填几个值（比如账号和密码）用 fields：{"id":"q-xxxx","question":"登录服务器","fields":[{"label":"账号"},{"label":"密码","secure":true}]}，1–6 个字段，敏感字段加 secure。对方填完，每个字段带着自己的答案发回来。字段可以带 "type"：single（单选）/ multi（多选，都要 options，2–12 个）、date（日期，答案是 yyyy-MM-dd）、number（数字，可写 min / max / step / unit）、slider（滑块，必须写 min 和 max）；不写 type 就是文字框。可写 "default" 预填（单选写选项文字、多选写文字数组、日期可写 "today"、数字写数字），"required":false 表示选填（不写就是必填）。选择类的答案是 picked（选中的下标），其余是 answer。对方点「提交」就直接发给你。适合一次收一组约束（比如出游的地点、日期、预算），简单的一问一答别用表单。
    - ```html 网页卡（交互小页面）里可以调用 app：mp.todo.add(文本, {date:"yyyy-MM-dd"}) 加待办、mp.vocab.add(单词) 收生词——这两个会先弹窗问对方，对方可能拒绝；mp.ask(文本) 把一句话放进对方的输入框，发不发由对方决定；mp.report(文本) 记一条结果（如「测验 7/10，错在 ephemeral」），对方下次发消息时附带给你。都返回 Promise，被拒或失败会 reject（Error.message 是原因），页面里要接住。网页联不了网，也读不到对方的数据。不要在网页卡里让对方输入密码、token 这类敏感值，用 card-ask 加 secure。
    - 对方消息开头的 [附带事件] 是网页卡记下的结果或对方对某条消息的表情回应，不是对方打的字。
    - 新卡片自己起一个短 id（待办 t-、骰子 d-、计时器 c-、图表 g-、音乐 m-、提问 q-、时间线 l- 加 4 位随机十六进制，示例里的 xxxx 只是占位），必须是这段对话里没出现过的 id；只有修改同一张卡才沿用它的 id。
    - 要修改已有卡片（勾选、加项、改字），写一张同一个 id 的完整新卡片，不要只写改动部分。
    - 对方发来的卡片也按同样方式修改。
    - 卡片外不要再把卡片内容复述一遍。
    """

    // MARK: - 用到再查（粟粟 10-03：这么长一坨不要全塞系统提示词，模型要用卡片自己查）
    // 系统提示里只放 index；完整写法由 card_guide 工具按种类从上面的 text 里切出来（同一份文字，不会两套）

    static let kinds = ["todo", "dice", "timer", "chart", "music", "word", "timeline", "ask", "html"]

    private struct Parsed {
        var header: String
        var sections: [String: String]
        var common: [String]
        var events: String
    }

    /// 把 text 按「- 」开头的条目切开（后面缩进的续行跟着上一条）
    private static let parsed: Parsed = {
        var header: [String] = []
        var blocks: [[String]] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("- ") { blocks.append([line]) }
            else if !blocks.isEmpty, line.hasPrefix("  ") || line.isEmpty { blocks[blocks.count - 1].append(line) }
            else if blocks.isEmpty { header.append(line) }
        }
        var sections: [String: String] = [:]
        var common: [String] = []
        var events = ""
        for block in blocks {
            let body = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let first = block[0]
            if let kind = kinds.first(where: { first.hasPrefix("- card-\($0)：") }) {
                sections[kind] = body
            } else if first.hasPrefix("- ```html") {
                sections["html"] = body
            } else if first.hasPrefix("- 对方消息开头的 [附带事件]") {
                events = String(body.dropFirst(2))
            } else {
                common.append(body)
            }
        }
        return Parsed(header: header.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                      sections: sections, common: common, events: events)
    }()

    /// 系统提示里的短目录（工具发了才用它；没发工具照旧用完整 text）
    /// #089 P2-c：常用的四种（待办 / 骰子 / 计时 / 提问）格式直接写在这里（很少变，放进缓存几乎不花钱），
    /// 其余几种发前再调 card_guide——每发一张常用卡都多一次工具往返太慢
    static let inlineKinds = ["todo", "dice", "timer", "ask"]

    static let index: String = """
    [聊天卡片]
    对话界面能把特定代码块渲染成可交互的卡片：card-todo 待办清单、card-dice 骰子 / 抽签、card-timer 倒计时、card-chart 图表、card-music 音乐、card-word 生词、card-timeline 时间线、card-ask 提问 / 表单（要对方填值、填表时用；填账号密码、token 这类敏感值也用它，敏感字段加 secure；不要自己做网页卡收。只是让对方在几个选项里点一个，用 ask_user 工具），以及 ```html 交互网页卡。
    下面四种直接照写：
    """ + "\n" + inlineKinds.map(section).joined(separator: "\n") + "\n" + parsed.common.joined(separator: "\n") + "\n" + """
    其余几种（card-chart、card-music、card-word、card-timeline、```html）发前先调用 card_guide 工具（kinds 传要用的种类，如 ["chart"]）拿到格式再写，没查过的不要凭印象写；用不着就不用查。
    """ + "\n" + parsed.events

    static func section(_ kind: String) -> String { parsed.sections[kind] ?? "" }

    /// card_guide 的返回：要的那几种的完整写法 + 公共规则；不认识的种类说一声，一个都不认识就全给
    static func guide(for requested: [String]) -> String {
        let normalized = requested.map { raw -> String in
            var k = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if k.hasPrefix("```") { k = String(k.dropFirst(3)) }
            if k.hasPrefix("card-") { k = String(k.dropFirst(5)) }
            return k
        }
        let known = normalized.filter(kinds.contains)
        let unknown = normalized.filter { !kinds.contains($0) && !$0.isEmpty }
        let chosen = known.isEmpty ? kinds : kinds.filter(known.contains)
        var parts = ["[聊天卡片写法]", parsed.header]
        parts += chosen.map(section).filter { !$0.isEmpty }
        parts += parsed.common
        if !unknown.isEmpty {
            parts.append("没有这种卡：\(unknown.joined(separator: "、"))（有的：\(kinds.joined(separator: "、"))）")
        }
        return parts.joined(separator: "\n")
    }
}
