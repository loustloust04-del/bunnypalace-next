# Review：问问题打通 CC 桥

> Plan: [plan-问问题-cc桥.md](plan-问问题-cc桥.md) 14/14 ✅（2026-08-04）
> E2E：真实 hub + 一次性模拟器 + 隔离 session（mp-cc-aNNNNNN 唯一名，测后全 kill）。

## 一、E2E 实证清单（hub log + 截图双证）

| 路径 | 证据 |
|---|---|
| PreToolUse→hub→帧→app 弹卡 | `askuser pre chat=… q=2 session=mp-cc-a…` + 卡截图 |
| app 答题→键序落 TUI | tmux pane 实录：数字选中/多选 toggle/Tab→Review→"1" 提交全落 |
| PostToolUse 权威收账 | `askuser post … answered=2` |
| resolved→Q/A 真实 user 泡 | 截图：「Q: 今晚想吃什么? A: 泡面 / Q: 睡前想干嘛? A: 看书, 色色」+ CC 回复原文复述一致 |
| X/下拉跳过 | `drive ok skip=true` → Esc 落 TUI → `declined (app_skip)` → 「A:（用户没有选择，跳过了这个问题）」泡 |
| tmux 侧抢答 | tmux 按 "1" → post → app 卡同步收 + 「A: 竖着」泡落 |
| declined 兜底 | Esc 实测不触发 PostToolUse → reply 到达清账路径（设计即此，declined 泡走 app_skip/resolveOnReply） |

## 二、E2E 途中修掉的两个真 bug

1. **Review 页没有 "Esc to cancel" 页脚**：driveAnswer 原判定「页脚缺失=卡已收」在 Review 页假 ok
   不按 Submit——单测 fixture 错带页脚没拦住。修：先查 Review 再判页脚；fixture 改真实形态 + stuck 用例。
2. **resolved 帧无补发**：app 收帧瞬间离线（测试 runner 杀 app 撞见）Q/A 泡永久丢。
   修：hub 内存 resolvedLog（50 条）连接时补发，app 按 ccMessageId 三层去重。

## 三、E2E 自动化踩坑（记档，下次模拟器 GUI 直接抄）

- **idb/cliclick 的合成触摸对 SwiftUI sheet 内部全部穿透**（sheet 外正常）；MobAI/XCTest 注入通道可以点 sheet。
  cliclick 还需辅助功能权限（本机没开）。模拟器要点 sheet：XCUITest 或 MobAI，别用 idb。
- XCUITest 的 typeText 在 sheet 循环后焦点 flake（keyboards.count 会假阴），
  与被测功能无关；E2E 测试留档 `AskUserCCBridgeE2EUITests`（ASKUSER_E2E=1 手动跑）。
- session picker 的「被占用」行是 disabled——旧测试 session 名绑上轮对话后点了没反应，唯一名每轮新建。
- 长文本输入框长高后发送键上移，固定坐标 tap 会打到模型 chip。

## 四、生产资源接触记录（全部已复原/无害）

- 测试 sim 连生产 hub 期间 `set_cc_config` 覆盖过 push 名（助手），她的 app 重连后已重写回（狗狗）✓
- mp-cc-2 的「新建」tap 因 sheet 穿透从未生效——6 月的 conv-l2 旧绑定**没动**
- session-map 里留了 mp-cc-ask1/mp-cc-aNNNN 几条测试绑定（惰性，无 tmux session，无害）
- 生产 mp-cc / mp-cc-30 / mp-cc-6 已轮替（只 kill-session；下条消息 --resume 带记忆重生 + 吃到 hooks）

## 四·五、上线后事故修（2026-08-06）

**q=2 全部 ui_gone**：粟粟手机终端 attach 把 tmux pane 压到 **52 列**——单题短页脚（48 字符）
放得下、多题长页脚（…Tab/Arrow keys…59 字符）被省略号整段截断，存活校验锚「Esc to cancel」
必假阴 → hub 拒发键（防盲发保护误伤），app 选了但 TUI 没动。
修：存活/完成判定全部改**结构锚**（题面前缀去空白容折行 + 左缘编号行 `1.`——行号贴左缘多窄都活）
不再依赖页脚；52 列实案进测试。教训：**tmux TUI 文案锚点必须假设 pane 可能被 attach 端压得很窄，
页脚/状态行这类右侧内容会被省略号吃掉，锚要选左缘短结构。**

## 五、边界与债

- **hooks 是启动快照**：三条生产 session 已轮替；粟粟若新建别的 session 天然带 hooks（settings.json 项目级）
- **app 侧 X=整卡 Esc**：已答部分作废（TUI 语义所限，API 路径是"已答保留"）——plan 拍板已记
- **多客户端**：先答者赢，晚到答案回 ask_user_stale 收卡；未做双端同弹实测（协议对称，风险低）
- **resolvedLog 内存态**：hub 重启 + app 离线双重合时 Q/A 泡仍可能丢（CC 回复不丢）；接受
- **Mac app 的 hook 自装**：CCThinkingHookInstaller 已扩展（bundle 带 askuser-hook.py）；本次是手工装的 repo 路径版，Mac app 下次启动幂等跳过
- cc-bridge/tools-schema.json 仍未重导出（无消费方，见主刀 review）
