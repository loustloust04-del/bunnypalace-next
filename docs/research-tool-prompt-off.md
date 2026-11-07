# research：工具关了，工具说明还在（10-15）

派单：`~/Desktop/cc-rp/API链路/派单/prompt-工具关了说明还在.md`
粟粟 10-15 口径：**工具有总开关；哪个工具关了就不带那一串提示词。**
另：抽屉页已加常驻小字「聊到一半开关工具，下一条整段重写缓存，只贵这一条，最好开聊前设好」（ddff38a2f）。

## 她 Air 上现在的状态（10-15 拉的偏好 + 最后一次真实请求）

- 工具总开关（`perm.toolsMaster`）开着；文件库权限、记忆权限关；抽屉里全局关了 18 个（ask_user、card_guide、roll_dice、日历 / 提醒 / 通知 / 剪贴板、run_command、web_search、recall …）。
- 1E27AD 15:24 那次真实 body：`tools` 已经是空的，`toolInjectionDetailed` 那一整套说明一个字没发（对的）。
- **但 system 里还有一大段 `[聊天卡片]`，而且是全量版**：card_guide 一关，卡片说明从「目录」退回全文（图表的二十几种 type 全写进去），反而更长；里面还提到 roll_dice、ask_user、run_command 这些她关掉的工具。她在检查器里看到的「一大串」主要就是它。

## 每段说明现在由谁放进来（file:line）

| 段 | 放进来的条件 | 问题 |
|---|---|---|
| 整套工具说明 | `ConversationViewModel.swift:3420` 这一轮 tools 为空就整段不发 | ✅ 全关时对的 |
| `<文件库>` | `:3421` 只看文件库**权限**（`fileLibraryOn`） | 抽屉里把 fs_* 全关、权限开着 → 照发。里面还捎着纪念日 / 健康 / 交易写法（那几段不是工具） |
| 〔更多工具〕 | `:3428` 收起的工具；关掉的已被 `ToolRegistry.enabledDefinitions` 滤掉 | ✅ |
| `<设备>` + `<命令>` | `:3435` 只要有**任一**设备工具就整段发（`DeviceToolDispatcher.swift:71`） | 文字固定列出全部 7 类设备工具 + 整段 run_command 说明，关掉的也在 |
| 〔到点提醒〕 | `DeviceToolDispatcher.swift:60` 按名字逐行 | ✅ |
| 〔回忆〕〔我的记忆〕 | `:3440 / :3445` 按 recall / remember 在不在 | ✅ |
| 联网搜索引用说明 | `:3450` 有搜索工具 + OpenAI 系 | ✅ |
| 〔当前能用的工具〕 | `:3458` 按真实 tools 生成 | ✅ |
| `[聊天卡片]` | `PromptAssembler.swift:655` **永远发**；card_guide 下发 → 目录，没下发（工具关 / 总开关关 / CC）→ 全文 | 关了 card_guide 反而发全文；文中写死 roll_dice / ask_user / run_command |
| `<语音条>` | `VoicePromptInjector`，跟「主动发语音」开关 | 不是工具，有自己的开关 |
| 关不掉的 | tool_search / inspect / invoke（`ToolRegistry.drawerExempt`）：只在有工具收进「更多工具」或 MCP 太多时才出现；另有一个隐藏子应用的工具不在抽屉里露出，有自己的门控 | 元工具会跟着自动消失，不需要开关 |

工具总开关：现在只在「设置 → MCP」里（`PermissionDomain.toolsMaster`）。关了 = 不发 tools、上表第一行那套说明全不发，但 `[聊天卡片]` 全文照发。

## 方案（粟粟 10-15 选 A = go）

1. **总开关放到工具抽屉页最上面**（同一个 `perm.toolsMaster`，设置 → MCP 那个不动，两边联动）。关掉 = 不发任何工具 + 所有工具说明都不发（含卡片段，见第 3 条）。
2. **每段说明只在它对应的工具这一轮真下发（或在〔更多工具〕里能调）时才出现**：
   - `<文件库>`：至少一个 fs_* 下发才发（不再只看权限）。纪念日 / 健康 / 交易那几行目前挂在 `<文件库>` 里跟着走，行为不变。
   - `<设备>`：只列这一轮真有的设备工具；`<命令>` 只在 run_command 下发时才有。
3. **`[聊天卡片]`** ← 粟粟 10-15 选 **A**：
   - **A（推荐，最贴你的口径）**：card_guide 关 = 卡片说明整段不发。模型就不会主动发卡片；你发来的 / 历史里的卡照常显示。
   - B：card_guide 关 = 只留一小段目录（几行），不再展开全文。
   - C：卡片单独一个开关，跟 card_guide 脱钩。
   - 不管选哪个：卡片说明里提到 roll_dice / ask_user / run_command 的句子，只在那个工具真下发时才出现。
4. `<语音条>`：不是工具，跟「主动发语音」开关走，**不动**。
5. 测试：`InspectorRealPathTests` 补「抽屉全关」「总开关关」两例（预览 = 实发，system 里没有任何工具说明）；「只开一两个」一例（只出现那几个的说明）；金样 G1–G8 只允许说明段的预期 diff。
6. 缓存：改完后开关工具会连带改 system，效果和现在改 tools 一样——那一条整段重写一次（抽屉页小字已经提醒）。

### todo

- [ ] 抽屉页顶部加工具总开关（联动 perm.toolsMaster），设置搜索注册表同步
- [ ] `<文件库>` 改按 fs_* 是否下发
- [ ] `<设备>` 按可用工具逐项列；`<命令>` 按 run_command
- [ ] `[聊天卡片]` 按你选的 A / B / C；工具名句子按可用性
- [ ] 总开关关 → 卡片段按第 3 条处理
- [ ] InspectorRealPathTests 三例 + 金样核 diff
- [ ] astra 审一轮
