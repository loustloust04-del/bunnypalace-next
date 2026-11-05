# Review：权限管理 P1（实现复盘）

> 2026-08-24 · worktree-permissions · plan-权限管理 T0-T9 落地复盘。
> 状态：✅ 代码验证收口（2026-08-24 01:41）——iOS/macOS build 绿 + 全套 585/585 绿（含新 PermissionCenterTests 8 例；13 个旧默认断言测试已更新到新真相源）+ build 产物待装 iPhone 14（unavailable，包已备好）。
> **有意偏差记账**：plan T10 的「复现器两路径实证」未做独立 XCUITest——askOnce 逻辑面由单测锚死（grants/档位/组合器），弹卡 GUI 归粟粟真机清单 §四首验。要补机器人复现器随 P2。

## 一、边界情况（没处理的输入异常 / 并发 / 失败重试 / 空状态）

1. **regenerate / editAndResend 不弹 askOnce 卡**：重生成路径未插前置 ask（6 个 assemblePrompt 调用点只改造了 sendMessage 主路径）。未答域在这些路径 = 安全不注入。影响面：用户把某域调成「每次询问」后不发新消息直接重新生成 → 该域这轮不注入。修法简单（同一 helper 插三处）但每处都要 Task 化重构，P1 按风险/收益放过。
2. **后台组装路径（语音通话等）askOnce = 不注入**：设计即此（plan §2 安全缺省），但用户视角「通话里 AI 不知道健康了」可能像 bug——文案没有任何提示。观察项。
3. **弹卡 30s 超时 = 本次拒**且**写入 deny 记录**——超时和手点「本次不要」不可区分，用户回来发现域被 deny 只能换对话或调档位。OpenMinis 超时不落 session grant（下次再问），我们落库了：语义更强，可能过强。观察项。
4. **并发发送**：PermissionPromptCenter 单卡队列（前卡未结清后来者自旋等待 100ms 轮询）——两个对话同时触发 ask 时第二个的卡会排队弹。自旋不优雅但有界。
5. **迁移的老装机判定 = 库里有对话**：零对话的老用户（存在但罕见）会被当新装吃收紧默认。已知取舍。
6. CC 桥对话（ccBridge provider）不走 toolInjection/组装 → 权限页对 CC 对话的注入域无效（CC 侧材料是 hub 组装的）。本来如此，权限页 footer 未说明。债。

## 二、与下一模块交互的风险（接口契约 / 数据格式 / 时序 / 共享状态）

1. **旧 Bool key 仍在被投影维护**（setLevel 同步写）——任何**新代码**若直读旧 key 而不走 PermissionCenter，在 askOnce 档会读到 false。写新代码的纪律：闸判定一律 `PermissionCenter.*`。ConfigSchema 里旧 key 仍在册（用户导入导出兼容），导入旧 config 会只改旧 key 不改 perm.*——**导入后档位与旧 key 可能失同步**。P2 该给 ConfigImporter 加 perm 同步钩子。⚠️ 这是最可能咬人的一条。
2. `Conversation.permGrantsRaw` 新字段进备份/同步/导出面了吗——**没查**（备份/同步/映射/覆盖检查五处 DTO 镜像是引用注入刀踩过的坑）。验证项：全套测试里若有 DTO 快照测试会抓到。
3. P3 AI 改设置工具必须走 `aiWritable` 过滤 + setLevel（不能直写 defaults）——标记已埋，强制未实装。
4. agora `speech_mode` 等 hub 真相源域不在权限页管辖，权限页只管 app 侧闸。

## 三、技术债

1. memory / voiceProactive 两档取舍（askOnce 挂 P2，MemoryService 穿 grants 是独立刀）
2. agent+共读行 = 跳转不是适配器（closure 多播挂 P2）
3. regenerate/editAndResend 前置 ask 缺位（边界 1）
4. ConfigImporter 导入旧 key 与 perm.* 失同步（风险 1）
5. pocket askOnce 未实装弹卡（pocket_cmd 到达在 WS handler，P1 pocket 的 askOnce 档行为=notAllowed 同义——**UI 该藏 askOnce 没藏**，收口前修或记）
6. 拒绝文案纯文字无深链（P2 挂 mp:// scheme 调研）

## 四、粟粟真机清单（T11 装机后）

- [ ] 设置→权限：三区看一遍，健康子页五行
- [ ] 把「交易」调成「每次询问」→ 发一句 → 弹卡 → 允许 → 同对话第二句不再问
- [ ] 把「体重」调「不允许」→ 问 AI 体重 → 它看不到
- [ ] 原 tab 联动：设置→健康 改档 → 设置→权限 里同步变（反向也试）
- [ ] 工具 askOnce：文件库调「每次询问」→ 让 AI 读文件 → 调用时弹卡；拒绝 → AI 收到 permission_denied 并提到设置
- [ ] 新装语义不验（你是老装机，迁移应保持一切现状——重点验：**升级后什么都没变**）
