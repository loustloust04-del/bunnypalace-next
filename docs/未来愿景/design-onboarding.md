# Onboarding 设计

> 2026-08-26 · 粟粟+小雾。
> 状态：**iOS 已实现（小白线 + 酒馆线）**，worktree `settings-appearance`；HTML 原型 `onboarding-proto.html` 同目录。
> 上文：`产品架构与Onboarding设计讨论纪要_v2.md`（思路来源）、`design-lite-mode.md`（身份→lite/pro 默认值在这边落地）。
> **吉祥物规矩：以后不准用「小雾」——lite 引导吉祥物叫「小芽」，pro 叫「rosemary」。**

## 一句话

身份分流的引导：欢迎 → 你是谁 →（酒馆：导入角色卡/世界书/预设｜其他：Ta叫什么名字）→ 怎么称呼你 → 加 Provider → 选模型 →（酒馆跳过教练）→ 完成。**每一步都可交互、可跳过**，不强迫看说明书——说明书活在 docs/skill 里，用户靠跟 AI 交互学。

## 本期范围（v1 落地）

- **小白（newbie）+ 酒馆（tavern）+ 技术（tech，大概版）三条线已做完**。身份写一次 lite/pro 默认值：小白/陪伴→lite，酒馆/技术/保持神秘→pro；「我是小白」胶囊默认框选（薄荷绿 2pt 描边）。
- **TODO（以后要改，别忘）**：陪伴线 S6 必过+强调记忆、技术线 S4/S5 压缩成一屏（现在技术线只是教练屏换成连桌面工具，S4/S5 还没压缩）。
- 触发点：① 首次安装启动 `fullScreenCover`（`ContentView.swift` iOS 分支，`onboardingCompletedV1` 门）；② 设置页底部搜索框「?」按钮重走一遍（`SettingsView.swift`）。
- macOS 不做。

## 视觉：十字绣风墨绿点阵插画（禁 emoji）

参考：粟粟给的十字绣 flash 图（`Cross stitch flash + some of my fave inspo pics.jpeg` / `_ (1).jpeg`）——奶油底 + 深绿小点组成稀疏轮廓。
实现：`MemoryPalace/Views/Onboarding/PixelArtView.swift`，网格字符串（`'x'`=点）→ Canvas 墨绿（`#2E5233`）圆点。HTML 原型里的 `PIX_MOTIFS` 是同一组网格，**改一边同步另一边**。

motif 清单：`sprout`（小芽=S0/小白）、`key`（复古钥匙=S3 Provider，学原版：宝冠+双椭圆环+旗形齿+星芒点缀）、`spark`（四芒星=S4 模型）、`blossom`（开花=S5 教练/S6）、`heart`（心=S3 称呼/陪伴）、`ghostie`（小幽灵=保持神秘）、`gear`（齿轮=技术）、`card`（卡片=酒馆）、`quill`（羽毛笔=S2 AI 名）、`fork`（园艺叉=S1 身份 hero）。

## 参考组件（搜来的，不是拍脑袋）

| 来源 | 偷什么 |
|---|---|
| [Duolingo onboarding](https://goodux.appcues.com/blog/duolingo-user-onboarding) | 一屏只问一个问题 + 进度点；个性化分流做成"答题"而不是"读文档" |
| Airbnb 搜索（帮我写教练已抄） | 叠卡：当前问题展开成大卡，答过的收成一行摘要可点回去改 |
| [Lovable onboarding teardown](https://aiuxplayground.com/teardowns/lovable/onboarding) | 全屏 wizard，每屏同一位置放品牌物（我们是小芽🌱），暖色渐变底不断戏 |
| [Cherry Studio #13421](https://github.com/CherryHQ/cherry-studio/issues/13421) | 工程结构照抄：`onboardingCompleted` 布尔 + 设置里"重走引导"入口 + 全部可跳过 |
| Minis 三步引导（v2 纪要） | 加 provider → 选模型 → 开始对话 的阶梯顺序；步骤未完成时下一步置灰并说明"请先完成第 N 步" |
| Pillow onboarding（录屏逐帧拆的，见下） | 称呼最先问、标题带名字、细进度条顶栏、每屏一个大插画、成功屏收尾 |

## Pillow 录屏拆解（2026-08-26，76 秒完整流程）

流程：欢迎（"congrats you are in"）→ ① 怎么称呼你 → ② 生日 → ③ 性别 → ④ 代词 → ⑤ 最近在想什么 → 通知预权限屏 → 付费墙 → "mental clarity, unlocked" 成功屏。

五个直接偷的点：

1. **称呼最先问，之后每屏标题都带名字**——"hey su, welcome in"、"in the story of su, your gender is?"、"what's been on your mind lately, su?"。名字是个性化杠杆，成本几乎为零，后面每一屏都因此不像表单。→ 我们把教练第三题「称呼」提前成独立一屏（S3），教练变两问。
2. **顶栏三件套**：细进度条（不是圆点）+ "1/5" 计数 + 右上 skip + 左上返回箭头。→ 替掉我们的圆点。
3. **每屏一个大插画**（风格化小怪物），屏间转场是色块全屏 morph。→ 我们每屏一个大号花园物（🌱🔑🧠🌷🌸），转场先不做 morph，普通 push。
4. **选项 = 大 pill 按钮**，未选灰、选中带主色；「self-describe」永远垫底且颜色更深；next 没选东西时是暗的。→ 采纳"next 未激活置灰"。
5. **文案全是 lowercase 口语**，像朋友说话不像表单。→ 中文版对应物：短句、带名字、不用敬语堆。

不学它的：黑底荧光绿配色（我们是奶白花园，学结构不学皮）、生日/性别/代词三屏（跟 AI 工具无关）、付费墙（没订阅）。预权限屏记下备用——以后加通知时照抄："先用自己的屏讲价值，再弹系统框"。

## 流程总览

```
S0 欢迎 ──→ S1 你是谁 ──→ S2 Ta叫什么名字 ──→ S3 怎么称呼你 ──→ S4 加 Provider ──→ S5 选模型 ──→ S6 提示词教练 ──→ S7 开始对话
   │            │   └── 酒馆线：S2 换「导入角色卡/世界书/预设」┘                  │               │      └── 酒馆线跳过 ────────┘
   │            │                │                  │                │               │
   └── 保持神秘 ─┴→ 直接扔主屏 ────┴── 每屏右上「跳过」─┴────────────────┴── 可随时退出，主屏不锁
```

- **S1 选「保持神秘」= 全部跳过**，落主屏（先经过 S7 变体「好，不问了」），设置搜索框「?」帮助入口保留。
- **S3 之后每屏标题都带名字**（Pillow 偷的）："su，先拿把钥匙"、"su，挑个脑子"。名字只用于文案称呼，不进 prompt——进 prompt 的是 S6 教练产物。
- S4 没配 key 也能跳过——主屏第一条消息发送时引导回来补（轻提示，不弹窗轰炸）。
- S6 就是设置里「帮我写」那套问卡（LitePersonaCoachView），**同一个组件复用**，onboarding 只是它的第二个入口。称呼题已提前到 S3；v1 里教练组件本身没动（仍三问），onboarding 侧只放入口屏，两问化是后续的事。

## S1 身份分流

> v1 落地现状：**小白线和酒馆线已分流**（下表 ✅），陪伴/技术仍走小白流程，只是文案不同（TODO）。

| 身份卡 | 默认模式 | 引导差异 |
|---|---|---|
| 我是小白（默认框选） | lite | S4/S5 给最啰嗦的引导语（key 去哪拿、以后去哪改）✅ |
| 酒馆用户 | pro | ✅ S2 换「导入你的角色卡、预设和世界书」（.json/.png，三行 fileImporter），S6 教练整屏跳过（角色卡已回答"Ta是谁"） |
| 长期陪伴 | lite | ✅ S6 教练屏多「导入聊天记录」（直开 ImportView sheet，让 Ta 吃历史对话当记忆）；TODO：S6 必过+强调记忆模块会记住 |
| 技术用户 | pro | ✅ S6 教练整屏换成「连桌面工具」（Claude Code / Codex / 终端三行说明 + 扫码配对 cc-bridge，配对逻辑同设置页）；大概版，app 本体还在动，以后细化 |
| 保持神秘 | pro | ✅ 结束 onboarding，直接主屏 |

身份只写一次默认值（lite/pro + 引导路径），之后用户在设置里随时能改——跟 lite 文档的"不按身份锁死"一致。

## 分屏规格

### S0 欢迎
```
┌──────────────────────┐
│                      │
│     [sprout 点阵]     │  ← 小芽 pop 入场
│   欢迎来到记忆花园     │
│   三样东西就能开工     │
│                      │
│   [ 开始 ]           │
│   随便看看 →（=保持神秘）│
└──────────────────────┘
```

### S1 你是谁
Pillow 同款布局：左题 → 居中 hero 大画（园艺叉）→ 五个**胶囊选项**（居中标题+一句话），一屏放得下，无滚动。点了直接进 S2，不要"确认"按钮。返回钮 1:1 复用聊天页 page1 的玻璃返回键（`GlassBackButton`）。

### S2 Ta叫什么名字
AI 名不偷偷默认——独立一屏问。羽毛笔 hero，大输入框居中，placeholder 用吉祥物默认名（lite=小芽 / pro=rosemary，**不准再用小雾**），空着继续 = 就叫默认名，写 `assistantName` AppStorage；重走时已改名会带出来。此屏之后 S3 标题变成「{Ta的名字}该怎么称呼你？」。

### S2 酒馆线：导入你的角色卡、预设和世界书（替代「Ta叫什么名字」）
三行导入入口：角色卡（.json/.png，走 `CharacterCardManager.importFromFile`）、世界书（.json，酒馆 entries 数组/对象双格式解析，绑 `currentProfile.linkedWorldBookIDs`）、预设（.json，`PresetManager.importFromSillyTavern` + 绑 `currentProfile.presetId`）。导成功的行尾出绿「✓ 名字」；没有也没事，右栏卡库随时能补。

### S3 怎么称呼你（Pillow 第一题同款）
一个大输入框居中，placeholder "你的名字"，键盘直接弹起。右下圆形 → 按钮，输入前置灰。此屏答完，后面每屏标题带名字。

### S4 加 Provider
- provider 卡列表：OpenAI / Anthropic / Gemini / OpenAI 兼容（自定义 baseURL）
- 选中展开 key 输入框（secure）+「连一下试试」按钮（真发一条 ping 请求，绿√红×）
- **连上（绿√）约 0.8 秒后自动进 S5 拉模型列表**，手动「下一步」保留兜底
- 小白身份多一句："key 在 provider 官网的 API 页面拿，贴进来就行"
- 右上「跳过」（酒馆线跳过直达 S7）

### S5 选模型
- 从 S4 配的 provider 拉模型列表，radio 单选，每行带价格档提示（便宜/中等/旗舰）
- 预选一个便宜款当默认（🌛副模型逻辑同源），**便宜款行内带薄荷绿 ★**
- 底部指路小字分身份：小白="★ 省钱默认款…兼差当后台小模型 / 以后想换模型、加 key：设置 → 模型（API）里都有，找不到就点搜索框的「?」"；其他="★ 省钱默认款 · 之后都在 设置 → API 改"
- 没配 provider 跳进来的：显示"还没钥匙"，引导回 S4 或跳过

### S6 提示词教练
复用 `LitePersonaCoachView`，onboarding 里只用两问（场景/风格——称呼已在 S3 拿走）。生成 → 写入助手设定+用户描述插槽 → 预览两行 → 「就用这个」。
**酒馆身份整屏跳过**（角色卡已经回答了"Ta是谁"）。
**陪伴身份多一个次级按钮「导入聊天记录」**：点了直接开 `ImportView` sheet（同 ContentView 那套：large detent + 隐藏 drag 指示 + sidebarBg 底色），导完回来继续教练或跳过。

### S6 技术线：连桌面工具（替代教练屏，大概版）
技术用户不要帮写提示词——教练整屏换成桌面工具页：三行说明（Claude Code「Mac 端 ~/.claude 会话搬进来」/ Codex「同一个桥配对一次两边通用」/ 终端「手机上跑 Mac 的 shell」）+ 「扫码配对」按钮开 `CCPairScannerSheet`（配对逻辑与 `CCSettingsView.applyPairing` 同路径：写 `ccBridgeBaseURLOverride`/备份地址 + cc-bridge key + WS 重连），配对成功按钮变「已连上，下一步」。底下小字指路「设置 → 编程工具」。app 本体还在动，此屏是占位级大概版，以后细化。
顺带修了一个全 app 的坑：`CCPairScannerSheet` 原来没有关闭按钮，扫不到码只能杀 app——加了左上角黑圆底 ×，设置页三处调用（CC/Codex/API 凭据编辑）一起受益。

### S5 开始对话
sprout → spark → blossom 三个点阵逐棵 pop（绽放动画的像素版），一句话"都准备好了"（带名字），按钮「开始对话」落主屏。ghost 变体：「好，不问了」+「进屋」。

## 状态与工程

```swift
@AppStorage("onboardingCompletedV1") var completed = false        // 完成或保持神秘都置 true
@AppStorage("onboardingIdentity")    var identity: String         // newbie / tavern / companion / tech / ghost
@AppStorage("onboardingUserName")    var userName: String         // 称呼，只用于文案
```

- App 启动（iOS）：`onboardingCompletedV1 == false` → `ContentView.iOSLayout` 上 `.fullScreenCover` 出 `OnboardingFlowView`。
- 设置页底部搜索框「?」→ 重走一遍（`SettingsView` 里 `.fullScreenCover`）。
- 身份→lite/pro：写完默认值后不再干预（`settings.proMode` 一次性写入）。
- 每屏顶栏（Pillow 三件套）：细进度条 + "2/6" 计数 + 左上返回箭头 + 右上「跳过」。每屏标题上方放该屏的像素 motif。

## 不做

- 不做账号/登录——key 就是账号
- 不做强制观看——每一屏都能跳
- 不做内置 Demo Key——门槛前置是筛选（v2 纪要原则 1）
- 不做服务端——所有状态本地 AppStorage
- 不做教学说明书——教学靠 S4 教练和后续对话里 AI 自己带
- macOS 版暂不做（Editor 端用户都是技术的，不需要哄）

## 原型

`onboarding-proto.html`（同目录）——六屏可点击走查，花园配色（#FBF8F3 底 / 薄荷绿主色）+ 墨绿点阵插画（`PIX_MOTIFS`，与 Swift `PixelMotif` 同网格），Nunito。
