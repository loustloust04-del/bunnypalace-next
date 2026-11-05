# Research: B22 纯色背景自动变白（page1）

> 2026-06-11 · 状态：根因未锁定，已排除大半嫌疑 + 探针已上线等发作
> 2026-06-12 更新：**发作已捕获**，H1/H2 死刑，见文末「发作判读 06-12」
> 2026-06-12 终章：**结案**（粟粟实测确认）。三案并发：渲染层 viewDidLoad 抹 fill（上古本体，
> commit c3d0140）+ 取色器双实例偷色（v6 单 sheet，13946ab）+ 防回写闸误伤（待拆）。
> 完整结案报告见文末「终章」。
> 症状：刚换色正常，"过段时间"自己变成白色。Roadmap 标记**双端**、"壁纸/主题失效"（发作时背景图也一起没了）。

## 一、背景架构（颜色从哪来）

```
ThemeEditorView ColorPicker
  → ThemeColorValue(color:)                 # Color→RGBA Double 四元组
  → ThemeManager.replaceTokenSet            # 改 themeDefinitions[i].light/dark
  → themeDefinitions.didSet
      → normalizedDefinitions 归一化（强制 default 主题恢复出厂、排序）
      → persistDefinitions: JSONEncoder → UserDefaults["themeDefinitions"]   ⚠️ try? 静默吞错
  → @Observable 触发依赖方重渲染

显示链（iOS page1）：
ContentView.iOSLayout 读 Theme.mainBg（= ThemeManager.shared.currentTokenSet.mainBg）
  → WallpaperConfig(fill:…) → PagingContainerView.updateUIViewController
  → PagingViewController.applyWallpaper → wallpaperContainer.backgroundColor（UIKit 底层）
聊天页 HC 全透明，背景全靠这层。

启动链：
ThemeManager.init ← App struct @State 初始化时（lazy shared 单例）
  loadThemeDefinitions: defaults 无数据 / 解码失败 → **静默回种子主题**   ⚠️
  selectedThemeId: 存的 id 不在 definitions 里 → **静默回 "default"**     ⚠️
```

关键事实：**宫殿默认主题 mainBg = `#FFFBF6`，肉眼就是白色**。所以"变白" ≈ "主题整体回退到默认"——和"壁纸也失效"吻合（默认主题无背景图）。

## 二、已验证的事实（每条带证据）

| # | 事实 | 证据 |
|---|------|------|
| 1 | ThemeManager 持久化逻辑**本身正确**：编辑→落盘→重启恢复、P3 广色域、encode/decode round-trip 全通过 | 隔离 harness 实测（/tmp/theme-bug-test，AppTheme+ThemeManager+ThemeAssetStore 原文件编译），粉色 #FFC0CB 两轮重启后原样恢复 |
| 2 | 全 app 只有一个 ThemeManager 实例（shared 注入 env），不存在双实例互写 | grep 全部 `ThemeManager()` 构造点：仅 `static let shared` |
| 3 | 没有任何外部代码写 themeDefinitions/selectedThemeId/usePureBackground 三个 key | grep 全仓 |
| 4 | **Mac 端 plist（活跃写入中，mtime=now）四个主题 key 一个都不存在**，其他设置 key 都在；当前窗口显示的就是默认主题 | `defaults read` + plutil + CGWindowList 截窗 |
| 5 | 壁纸渲染层 diff（WallpaperConfig Equatable + lastApplied 短路）正确，fill 在会话内不会自发变化——唯一写入点是 applyWallpaper | PagingViewController.swift L326-364 走读 |
| 6 | ColorPicker 常规取色（色轮/HSB/P3）转 ThemeColorValue 不会产出白色；只有 catalog 动态色（windowBackgroundColor 这类）会变 #FFFFFF，但 ColorPicker 不产 catalog 色 | harness Phase 3 实测 |
| 7 | 主题系统 2026-04-18 引入（e351250），B22 04-28 报——bug 与这套系统同生 | git log |

由 1+5 推论：**会话内**白色不可能凭空出现在壁纸层；要么是状态层回退（默认主题≈白），要么发生在重启加载时。Mac 端 key 全缺（事实 4）有两种读法：Mac 上从没编辑过主题（当前自洽）、或编辑过但从未落盘成功——无法事后区分，这正是探针要补的盲区。

## 三、已排除的假设

- ❌ 持久化/归一化逻辑 bug（事实 1）
- ❌ 双 ThemeManager 实例互相覆盖（事实 2）
- ❌ 备份/恢复/其他代码覆写主题 key（事实 3）
- ❌ 壁纸 apply 短路导致 stale white（事实 5：短路只会"不变"，不会"变白"）
- ❌ ColorPicker 转换直接存成白（事实 6，且若如此"刚换色"就该立刻白）
- ❌ 深浅色切换（custom 主题 dark 默认是 #121311 近黑，不是白）
- ❌ usePureBackground 开关（若开着，光"纯净背景"在浅色下就是 #FFFFFF，但那样刚换色也立刻白，与"刚换色正常"矛盾；且 Mac plist 无此 key）

## 四、存活假设（按可能性排序）

**H1 编辑从未落盘（app 环境特有的静默失败）**
persistDefinitions 是 `try?` 吞错。隔离环境正常 ≠ app 环境正常。若 iOS 上 encode/写入因某种 app 态原因失败：换色后内存态正常（"刚换色正常"✓）→ iOS 过段时间杀后台 → 重启回种子（"过段时间变白"✓）→ 背景图引用也一起丢（"壁纸失效"✓）→ Mac 端 key 全缺也获得统一解释（"双端"✓）。症状全吻合，但失败机制未知，需探针证实。

**H2 启动时 defaults 读空/读损 → 静默回种子 + selectedThemeId 回 "default"**
loadThemeDefinitions 任何失败都静默回退；之后用户碰一下任何主题设置，坏状态就**永久覆写**好数据。候选机制：重启后未解锁期间的后台拉起（Data Protection 下 plist 不可读，本 app 有 APNs）；plist 已 1MB+（breadcrumb/ccSeenReplyIds 高频写）的 cfprefsd 异常。机率低但破坏性大。

**H3 渲染层在状态正确时显示白**（chat HC 背景被 UIKit 重置回 systemBackground 之类）
与"双端"矛盾（macOS 无此层），列着仅为完整性。探针可一击排除/坐实。

## 五、已上探针（本次 commit，零行为变化）

全部走 BreadcrumbLog（80 条环形，**三指双击反馈自动带出**），下次发作时反馈一次即出判决：

1. `ThemeManager.init` 末尾 → `🎨 主题载入 raw=有(NB)/无 defs=N sel=… mode=… pure=… bgL=#… bgD=#…`
2. `persistDefinitions` 改 do/catch → 失败时 `🎨⚠️ 主题保存失败: …`（成功路径行为不变）
3. `loadThemeDefinitions` 解码失败（有数据但解不开）→ `🎨⚠️ 主题数据解码失败(NB): …`
4. `PagingViewController.applyWallpaper` fill 从非白→白的瞬间 → `🎨⚠️ 壁纸fill变白 old=#… new=#… sel=… pure=…`

### 发作后判读表

| 反馈里看到 | 结论 | 修复方向 |
|---|---|---|
| 启动条目 `raw=无`（之前明明换过色） | H1 坐实：从未落盘 | 查 4 号探针之前有无 `保存失败`；没有则深挖 defaults 写链 |
| `🎨⚠️ 主题保存失败` | H1 坐实 + 失败原因直接可见 | 按 error 修 |
| `🎨⚠️ 主题数据解码失败` | H2 坐实（数据损坏） | 解码失败别回种子，保留原数据 + 备份 |
| 启动 `raw=有 sel=custom bgL=#粉` 但 4 号探针报 fill 变白 | H3 坐实（渲染层） | 查 applyWallpaper 上游传参 |
| 启动 `raw=有` 但 `sel=default` | 存的 selectedThemeId 丢了/归一化踢回 | 查 selectedThemeId 写链 |

## 六、顺手发现（不在本次范围，挂账）

- `com.susu.MemoryPalace.plist` 已 1MB+：breadcrumbLog + ccSeenReplyIds/ccSeenThinkingIds 全在 UserDefaults 高频整写，cfprefsd 每次整文件重写。建议迁文件存储（与 R-B4"数据出口"批次顺路）。
- 6-10 反馈①「EmptyStateView 和花园同屏呼吸穿模」是 page1 另一个 compositing bug，与 B22 无关但同住聊天页，别混为一谈。
- 修复本体（loadThemeDefinitions 解码失败不静默回种子、persist 失败用户可见）等探针定罪后一起做，避免在错误层打补丁。

---

## 发作判读 06-12（探针第一轮收获）

证据源：反馈 `2026-06-11-141458`（粟粟翻页瞬间截图：左页薄荷/右页白）+ **devicectl 直接拉取手机
`com.susu.MemoryPalace.ios` 的 UserDefaults 全量解码**。

### 实锤事实

1. **H1/H2 全部死刑**：13:52→14:14 八次启动，每次 `🎨 主题载入 raw=有(10825B) defs=5
   sel=theme-5639bbd1… mode=light pure=false bgL=#FFFCF8`，零条 ⚠️。持久化链路无失败、无损坏、无回种子。
2. **屏幕显示与存储数据完全一致**——选中主题「我的主题 副本」存的就是：
   `mainBg=#FFFCF8`（近白！）`sidebarBg=#EDF4EF`（薄荷）`userBubble=#F0F4EF`
   `assistantBubble=#DADDE9`（淡紫）`accent=#E7EEEC`（出厂未动）。
   翻页瞬间左=sidebarBg 薄荷、右=mainBg 白，是对存储数据的忠实渲染。**白来自数据本身**。
3. #FFFCF8 既不是出厂 #FFFBF6，也不是任何色彩空间换算漂移产物（P3↔sRGB 各方向实算均对不上），
   也不是本主题母本「我的主题」的 mainBg #F8F4EF——它是某次真实写入存下来的值。
4. 衍生发现：22 分钟内 app 🚀 冷启动 8 次（最短间隔 40s）——iOS 在频繁杀进程或 app 在崩。
   这解释了"过段时间"为何这么短：任何只活在内存里的状态每隔几分钟就被清一次。

### 修正后的根因模型（H4）

「我的主题 副本」的 mainBg 槽长期存着 #FFFCF8。粟粟把主背景改成薄荷 → 内存+落盘=薄荷 →
"刚换色正常"✓。之后**有一笔写入把 mainBg 单槽写回 #FFFCF8**（其余槽存活——排除整主题覆写，
只有主背景 ColorPicker 的 binding 写得出"单槽回旧值"）。头号嫌疑：**iOS ColorPicker 用自己
初始化时持有的旧色回写 binding**（List 行回收重建 / picker sheet 关闭时机的已知劣迹类 bug）。

### 探针 5（06-12 加）

`replaceTokenSet` 槽位级落痕：`🎨 改色[主背景L] #EDF4EF→#FFFCF8 @bb22c1a61f`，
同槽 2s 节流防 ColorPicker 拖动刷屏。**下次粟粟换色后若再变白，面包屑会直接写明
"谁在什么时候把哪个槽从薄荷写回白"**——写入者当场现形。

### 待粟粟决定的设计问题（与 bug 修复分开）

翻页瞬间左右异色是**当前设计使然**：page0 列表画 sidebarBg，page1 聊天画 mainBg（壁纸 fill）。
默认主题两值几乎一样（#F8F4EF vs #FFFBF6）看不出缝，自定义主题一旦两槽差异大，翻页就出现"接缝"。
若期望"左右永远同色"，要么列表页也改画 mainBg，要么编辑器里把两槽联动——design call，等批注。

---

## 定罪 + 修复 06-12

### 现行证据

粟粟在探针 build 上重现：21:28:26(UTC) 打开设置改主背景 → **21:28:47 探针 4 抓到
`壁纸fill变白 old=#FFFCF0 new=#FFFCF8`** ——她刚选的奶油色在几秒后被**字节级精确**写回存储旧值
#FFFCF8。再拉手机 defaults：mainBg 仍是 #FFFCF8，新色未存活。手拖不可能精确落在旧值上 →
这是一笔程序性回写。"切楼层触发"是显形不是案发：白色早已在数据里，楼层切换 `.id()` 重建整棵
ContentView 才把它画出来。

### 根因（排除法锁死）

全仓能写 mainBg 单槽的只有 ThemeEditorView 主背景 ColorPicker 的 binding 链
（restoreDefault 写 #FFFBF6、resetCustom/saveThemeCopy 是整主题操作，全对不上）。机制 = 回声环：

```
拖 picker → binding.set → replaceTokenSet → touch() → 编辑器 body 重渲染（body 顶读 themeChangeID）
→ SwiftUI 程序化回设 ColorPicker.selection（拖动中 get 值落后于手指）
→ UIColorWell 触发 valueChanged → 把旧色重新 set 回 manager → 又 touch → …
```

最后落地的回声决定存储值：旧值赢="自己变白"，新值赢=正常 → **"有时候"**。
侧栏薄荷/气泡淡紫是赢的几局，mainBg 是输的。macOS 同一段 SwiftUI → **"双端"**。

### 修复（commit 同此文档）

`ThemeColorPickerRow` 改行内本地真源：picker 绑 `@State localColor`，交互期间**不程序化回设
picker**（环的供能边切断）；自己的回写经 `onChange(value)` 等值拦截，外部变更（恢复默认/切
浅深编辑模式）仍单向同步进来。顺带 `onChange(localColor)` 等值守卫杀 no-op 写入链。
调用点 hexValue 参数换成 ThemeColorValue（显示+比较一体），删 dead helper `hexValue(for:)`。

### 验证

- [x] 双端 build 通过
- [x] ~~粟粟装新 build → 改主背景 → 不再回白~~ → **v1 被探针证伪**，见下节
- [x] 探针 5 面包屑佐证 → 抓到 snap-back 仍在

## v1 证伪 + v2 修复 06-12

v1（断回声环：行内本地真源 + 不程序化回设 picker）装机实测**仍然复发**，探针 5 实录：

```
21:57:54 🎨 改色[主背景L] #FFFCF8→#FFFCF0   ← 粟粟选色
21:57:58 🎨 改色[主背景L] #FFFCF0→#FFFCF8   ← 4 秒后旧值写回（v1 fix build 上）
21:58:08 🏠 切楼层（显形时刻，案发在 10 秒前）
```

v1 防的是"我们程序化回设 picker → picker 重发"这条边；它断了之后回写仍发生 →
排除法只剩一个来源：**iOS SwiftUI ColorPicker 在取色 sheet 关闭时，把打开时持有的旧色
推回 binding**（UIKit/SwiftUI 桥内部行为，两次发作均为字节级一致旧值 + 选色后数秒，机械非手误）。
从 binding 侧无法区分"关闭推送的旧值"和"用户真选了旧值"，防不住。

**v2**：iOS 弃用 SwiftUI ColorPicker，`ThemeColorWell`（系统 well 外观色块按钮）+ 显式
`UIColorPickerViewController`，delegate 只转发 `colorPickerViewController(_:didSelect:continuously:)`
（真实用户选色事件）；`didFinish` 故意不读 selectedColor；`updateUIViewController` 留空
（picker 打开期间绝不程序化喂值）。macOS 保留 v1 结构（Mac 端无发作证据，不动）。

### 验证 v2

- [x] 双端 build 通过，已装机（构建于 06-12）
- [ ] 粟粟改主背景 → 关取色器 → 等几秒 → 切楼层 / 杀 app 重开，不再回白
- [ ] 探针 5：改色序列终结于所选值，无 #FFFCF8 snap-back 尾巴
- [ ] 通过后拔探针 1-5（grep `PROBE B22`）+ roadmap 收档

### 新开账

- **三指反馈坏了**（粟粟 06-12 报，细节待问：没弹面板还是发送失败？）→ roadmap bug 清单
- 22 分钟 8 次冷启动（app 被频繁杀/崩）→ 待立案

**Checklist（历史）**
- [x] 探针 1-4 上线 → 第一轮发作捕获 → H1/H2 排除
- [x] devicectl 拉机定位：白来自 mainBg 槽数据本身
- [x] 探针 5（槽位级写入溯源）上线
- [x] 第二轮现行捕获 → 回声环定罪 → 修复落地

---

## 终章：结案报告 06-12（粟粟实测确认）

### 上古白的本体 = 渲染层（commit c3d0140）

数据层七轮探针全程看不见它——最终靠 **layer-dump X 光**（app 自 dump CALayer 树到
Documents/feedback，devicectl 拉取）一击定案：

```
_UIHostingView<...RootModifier>  bg=(1.000,1.000) ← 白的本体：SwiftUI 根视图 systemBackground
 └ PagingViewController.view     bg=clear
    └ wallpaperContainer         bg=clear ←←← 本该是主题 fill！
    └ 列表页 HC → 自画满屏 sidebarBg（所以列表从来不白）
    └ 聊天页 HC → 全透明 → 透到根视图 = 白
```

机制：`makeUIViewController` 在 view 装载前调 `applyWallpaper`（fill 已涂 + lastApplied
已记）→ 之后 `viewDidLoad` 的 `backgroundColor = .clear` 初始化**抹掉 fill** → 同 config
Equatable 短路挡住一切重涂 → 新建 VC（**切楼层/冷启动**）聊天页永白。改色 = config 变 =
放行重涂（"刚换色正常"）；切楼层 = 新 VC 再抹（"一切就白"）。粟粟的"切楼层触发"直觉全程正确。
修复：viewDidLoad 末尾 lastApplied 置 nil 重跑 applyWallpaper。

### 并发二案：取色器偷色（数据层，commit 13946ab + d4f107b）

11 行各挂 .sheet + 选色触发全列表重渲染 → presentation 仲裁打架 → 一次点击双 picker 实例
（探针实录 vc=6a69/eaeb）→ 孤儿实例销毁时把开启时旧色当 didSelect 吐回覆盖新色。
修复：编辑器级单一 .sheet(item:)（双实例不再出生）+ coordinator 初始色守卫。

### 并发三案：自伤（待拆账）

- v5 的 30s 回写拦截 + v4 初始色守卫会误杀"第二次选色"（粟粟实测：改色只能改第一次）
  → 二案根因已除，闸门应大幅简化/拆除
- v5 曾加"开场 echo 压制器"误吞第一笔选色（v7 已拔，实测 iOS 26 程序化 set selectedColor
  不触发 didSelect）

### 结案后清理清单（待粟粟点头）

- [ ] 拔全部 `PROBE B22` 探针（ThemeManager 载入/保存/解码、PagingViewController fill变白+
      layer-dump、ThemeEditorView picker 系探针）
- [ ] 拆/简化防回写闸（30s 拦截 + 初始色守卫——先实测无闸是否复发，再定去留）
- [ ] project.yml 摘 LookInsideServer（发版前必须）
- [ ] roadmap B22 收档 + postmortem 沉淀
- [ ] 设计题待批注：聊天页(mainBg) vs 列表页(sidebarBg) 双 token 翻页接缝——统一还是分开

### 方法论沉淀（已入记忆）

- **layer-dump X 光**：真机"屏幕不对"类 bug 的终极取证（feedback_layer_dump_xray）
- **Representable viewDidLoad 抹配置陷阱**（feedback_representable_viewdidload_wipe）
- devicectl 拉 defaults plist = 面包屑/主题数据全程远程取证，手机不用在手边
