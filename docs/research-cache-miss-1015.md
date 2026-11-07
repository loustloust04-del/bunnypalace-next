# research：Anthropic 提示缓存每轮只写不读（10-15）

派单：`~/Desktop/cc-rp/API链路/派单/prompt-缓存不命中.md`

## 现象 → 证据（粟粟 Air 10-15 拉的数据，只读拉到本机 scratchpad，不进 git）

用量账本 `usage.jsonl`，Anthropic 主聊天（`cr` = 读缓存，`cw` = 写缓存）：

| 时间 | 卡 | 对话 | 输入 | 读 | 写 |
|---|---|---|---|---|---|
| 10-09 23:01 ×4 | 卡 A | 346086 | 26.6k–28.5k | **25.3k** | 1.7k–3.1k |
| 10-11 21:49–21:51 | 卡 B（官方直连） | 346086 | 25.5k–26.1k | **24.9k–25.7k** | 0.3k–0.5k |
| 10-14 18:14–18:25 ×6 | 卡 A | 1E27AD | 25.6k–27.7k | **无** | ≈ 全部 |
| 10-15 15:21 / 15:22 | 卡 B | 1E27AD | 27.9k / 28.4k | **无** | ≈ 全部 |

10-11 之前同一对话连发能读到 ~25k；10-14 起两张卡、所有对话一次都没读到，连 system 那段都没读到 → 变的东西在前缀最前面（tools / system）。

`last-request/`（#089 存的真实发出 body）：拿两个对话的 body 比（同楼层、同一套工具），**24 个工具每一个的 JSON 键顺序都不一样**：

```
A: {"name":"fs_append","input_schema":{...,"properties":{"path":…,"content":…}},"description":…}
B: {"description":…,"name":"fs_append","input_schema":{...,"properties":{"content":…,"path":…}}}
```

顶层键顺序、system 块里 `type / text / cache_control` 的顺序也每次不同。

## 根因

`ChatService.swift` 四处发请求（OpenAI 兼容 :670 / :928、Anthropic :1218 / :1517）和 `ChatGPTOAuthProvider.swift` :67 / :100 都是
`JSONSerialization.data(withJSONObject: body)`，**没加 `.sortedKeys`**。Swift 字典每个实例的遍历顺序按存储地址取种子，每轮新建的字典顺序都不同 →
工具定义（`input_schema.properties`）、历史 `tool_use.input` 每轮渲染出来不一样 → 缓存前缀从第一个工具起就对不上。
Anthropic 官方文档 prompt caching 排错一节原话就点了 Swift / Go 的随机键顺序会打破缓存。

`ConversationViewModel.swift:3419` 早就按 name 给工具**数组**排了序（注释写了「顺序抖动 = 整段 miss」），但没管**每个工具对象里面**的键顺序。

为什么 10-11 前还能命中：没完全钉死（10-14 一天合了 #089 / #093 / #094，工具定义 / 历史 tool_use 的构造路径都动过）。不影响结论——字节证据是直接的，修法也不依赖它。

## 两个不是 bug 的

- **1E27AD 10-15 15:24 那条**：输入从 28.4k 掉到 20.2k、读 0——那一轮她把工具全关了（body 里 tools 为空），工具变了本来就要整段重写一次。
- **thinking**：同一对话 thinking 参数不变就不影响；中途改思考档会让消息段缓存断一次（官方行为）。

## 修法

请求体统一 `.sortedKeys` 序列化（`BaseChatProvider.encodeBody`），六处都走它。键排序只改 JSON 里键的先后，语义不变；
检查器「上一次真实发出」看到的也变成排好序的。金样测试本来就是排序后比，不受影响。

回归测试 `CachePrefixStabilityTests`：同一对话（a2 带一轮 fs_read 工具调用，input 三个键）连发两条，取 `SentRequestStore` 里真发出去的字节，
tools / system / thinking / model 逐字节相同、上一轮断点那条 assistant 之前每条消息逐字节相同；六例：官方卡缓存友好、中转拉黑（不挂标）、缓存友好关、工具总开关关、opus-5-5 思考、OpenAI 兼容。
