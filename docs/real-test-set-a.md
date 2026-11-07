# 真测试集A

固定原料与真机 C3 播种验证。本文仅保留流程、计数与阻塞，不保存原文、密钥、楼层 UUID、设备备份或模型日志。

## 本次状态（2026-10-23，B 已完成）

**175 份原料已就位，粟粟可以亲手点「从 CC 记忆播种」。** 只写唯一「真测试集A」楼层的 `memory/cc/`，全部回读逐份 SHA-256 校验通过，总计 366479 字节。mask lease 已释放；未代点播种、未审批、未启动模型、未改产品代码、未提交。

车头告知粟粟已在 14 上切 Pro、配好 Anthropic key、C3 选 Haiku 4.5。本会话只读核实了设备上的 7 个楼层，其中测试楼层同名唯一，profileId、slug 与楼层 manifest 一致；CC 同步关闭且目标为空。

设备安装版仍为 `47d1d5ee`，按文件名“含 private_”排除，会跳过补回的 1 份普通项目记录。这是车头明确告知的已知问题，不为测试集改产品代码、不删除原料；后续报告区分投递 175 与该安装版预计候选 174，实际模型读取尚未发生。

## 私密数据边界

- 根目录：`~/.mp-test-data/真测试集A/`。整个目录永远不复制进任何仓库。
- 来源：指定 ccrp Claude Code 项目的 `memory/`，以及该项目 `CLAUDE.md`。
- 仅排除文件名以 `private_` 开头的文件（不分大小写），不打开、不复制；名字中间含该字样的普通项目记录照常纳入。不按 type、标题、索引或「日记 / diary」字样筛选。只取顶层普通 Markdown，不跟随符号链接。
- 只替换密钥、token、密码、私钥或带凭据 URL；保留其余原文。
- 正则检查常见前缀、Bearer、凭据赋值、私钥、长串，再逐行语义复核新增文件；复核只输出行号与类别，不输出原文。relay key 只在内存/标准输入中参与逐值 `grep -F`，不进入命令参数或扫描输出。
- `去敏记录.md` 保存文件/原行号/删除类型，不保存原值；跳过项只记数量。私密 `manifest.json` 保存份数、仅作统计的类型、各文件字节数/SHA-256 与总字节数。
- 人工复核发生过 1 次自然语言密码回显事故；已替换数据中的该密码，私密记录如实注明，不将该事故表述成“全程无凭据回显”。

## 原料计数

| 项目 | 份数 |
|---|---:|
| 原始 memory 文件 | 175 |
| 跳过文件名以 private_ 开头（不分大小写） | 1 |
| 按日记字样跳过 | 0 |
| 纳入 memory（含 MEMORY.md） | 174 |
| 另加 CLAUDE 原料 | 1 |
| 固定集文件合计 | 175 |
| user | 17 |
| project | 43 |
| feedback | 110 |
| reference | 3 |
| 无类型（索引与 CLAUDE） | 2 |
| 按约定应纳入的 CC 候选 | 175 |
| 当前安装版预计纳入 / 跳过 | 174 / 1 |

粟粟已澄清私人文件约定是大小写不敏感的 private_ 前缀，不是任意位置包含。此前按安装版规则只准备 174 份的口径已更正；固定集包含补回的普通项目记录，共 174 份 memory + CLAUDE 1 份 = **175 份**。安装版已知跳过 1 份，不等于原料漏推；尚未播种，不能把预计候选数记成实际读取数。

CLAUDE.md 直接使用去敏原文，设备文件名仍为 `ccrp_CLAUDE.md`，不再添加 `type: project` 外壳。所有类型仅作统计，feedback/reference/无类型同样进入候选；候选数不等于模型已读取数。

固定集仍仅删除 1 处密码；174 份与源文件逐字节一致，另 1 份仅替换该密码。两份本地生成集逐份相同，总计 **366479 字节**。本次补回文件的正则与 23 行语义复核未发现密钥，复核不回显原文。原有去敏不变；逐值零命中与投递回读证据保存在家目录。

## 真实产品入口与上设备规则

- `project.yml:350`：iOS bundle 为 `com.susu.MemoryPalace.ios`。
- `CCMemorySync.swift`：通常从 cc-bridge 同步到选定楼层的 `memory/cc/`；同步是全局目标且会删除不在远端清单的文件。固定集不更改现有同步目标。
- `CatalogSeed.swift` / `CCMemorySync.swift`：安装版读取 `memory/cc` 顶层可读、非符号链接且正文非空的普通 Markdown；不按 type 或「日记」筛选。其“文件名含 private_”规则与粟粟确认的前缀约定不一致，会少纳入 1 份；规则修复由别的工作处理，本任务不改产品代码。
- `CatalogSeedTask.swift`：种子还读取本楼层 Prompt 的人填文字与已有 wiki。
- `FileLibraryStore.swift`：本地路径是 app 容器 `Documents/记忆宫殿/floors/<slug>/memory/cc/`；普通文件库的 `filesystem/` 不是该位置。
- `ProfileManager` / `BlobStore`：楼层列表是 `Library/Application Support/MemoryPalace/blobs/savedProfiles`；同目录保存 slug 映射。B 只读核实这些元数据，不写共享楼层列表。

B 已执行：申请 mask lease，核实唯一楼层身份与同步目标，备份共享元数据及目标位置状态（原先不存在）。通过安装 bundle 路径匹配主程序，按精确 pid 退出 app，重读身份/同步/目标状态后，只推该楼层 `memory/cc/` 的 175 份；完整拷回并逐份比对字节数和 SHA-256。投递前后 `savedProfiles`、slug 映射及楼层 manifest 逐字节不变，主 app 保持退出。完成后已释放 lease，没有写其他楼层、共享列表、偏好或 wiki。

C3 必须用官方 Anthropic 端点、`claude-haiku-4-5-20251001`，且只使用指定官方凭据；不将 key 输入 app 界面。没有安全无界面入口时由本人在 app 配置，不用测试 runner 替代真楼层。

目录进入审计台后停止；目录与正文都留给本人审批。

### 配置入口与作用域

正式建楼层入口为「设置 › 通用 › 楼层 › 新建楼层」。Pro 是设置首页的界面密度拨杆，存全局 `settings.proMode`，不是楼层字段。现有 Debug seed 只生成性能/小样数据，没有指定真楼层、CC Markdown 或真实 key 的导入入口。

现成的免手输 key 路线是「设置 › config › 导入」的加密配置包。`ConfigSecrets.restore` 只替换包内指定 account，未带 account 不动；因此可在核实专用 credential id 后只导入该 account 的 key，而非替换全部凭据。此路线仍需要可用 UI；没有发现 launch 参数/环境变量直接配置真实 key 的产品钩子。全量备份恢复会替换全部楼层，不用于本次。

**C3 模型选择是全局 `mem_model_c3`，不是楼层独立配置**（`CatalogSorter.swift:6-12`、`FragmentPool.swift:88-101`）；值为 `<credentialId>/<modelId>`。不能把改该键描述成只改测试楼层。此次未改它；后续由车头确定如何隔离其他楼层的 C3 运行。也不能把默认 `claude-haiku-4-5` 别名当成任务书要求的已验证日期锁定模型。

若需本人手配，路径为「设置 › 模型和API › + › Anthropic › API Key」，模型使用任务书指定的日期锁定 ID；C3 选择在「设置 › 记忆 › 写入 › C3 整理编目 › 模型」。本轮 A 未进行配置。

## 拉日志

```bash
bash scripts/real-set-a-pull.sh
```

脚本要求私密 `~/.mp-test-data/真测试集A/device.json`：

- `floorSlug`、`profileId`：已核实的真实映射。
- `identityVerified: true`：核实完成后才设置。
- 可选 `deviceId` 必须匹配固定 mask。

可传 `--floor-slug`，但必须与已验证身份一致。缺失身份即失败，不扫描其他楼层寻找替代。

只读拉回该层完整 `memory/wiki`，因此包含 `.runs` 整理记录、`.proposals` 目录/正文提案、`task.json` 全部回合与 wiki 页面。输出在家目录 `runs/<yyyy-MM-dd-HHmm>/wiki/`，同分钟已有快照就拒绝覆盖。原始拷回数据仅短暂存在 0700 私密临时目录，脱敏后才发布快照；错误日志也先脱敏。全部 relay key 的原字节及 JSON 转义形式替换 `[REDACTED]`，最后重新逐值确认零命中。

运行中拷贝不是事务快照，应在 agent 等待审批后拉取。产品 `.runs` 只保留 30 天，需及时归档。

## 验证与历史实测

| 项目 | 结果 |
|---|---:|
| 模型 read / search / submit 调用 | 0 / 0 / 0（未启动） |
| 目录项 / 正文提案 | 0 / 0（未生成） |
| 模型轮数 / token | 0 / 0（未请求） |
| 本次模型费用 | $0（未请求） |
| 模型耗时 | 不适用，未启动 |
| build 冻结 | 1 |
| 物理设备自动化发现阻塞 | 1 类 |
| 人工去敏发现密码 | 1 处 |
| 人工复核凭据回显事故 | 1 次 |
| 密钥逐值核对残留 | 0 |
| B 推送 / 回读核对文件 | 175 / 175 |
| B 回读总字节 | 366479 |
| B SHA-256 / 文件集合差异 | 0 / 0 |
| B 回读已知凭据残留 | 0 |
| B 共享列表 / slug 映射 / 楼层 manifest 变化 | 0 / 0 / 0 |
| B lease | 已释放 |

已运行拉取脚本：缺失已验证身份时 exit 1，输出 `verified_identity_missing_or_invalid`，未拷其他楼层。实际脱敏函数以无私人内容的输入验证 UTF-8、混合 JSON 转义、UTF-16 LE/BE 四类，全部清零；JSON 语义和无密钥字节保持不变。未取得真实播种记录；完整设备拉取成功路径尚未验证。

第二轮 A 的历史证据：当时 174 份集合用真实 `CatalogSeed.swift` / `CCMemorySync.swift` 编译本地只读扫描 smoke，接收 174、跳过/空正文 0；类型统计与当时 manifest 一致。这不表示当前 175 份会被安装版全部接收。本次 B 的实际设备证明是上表 175 份推送及逐份回读校验；没有真实模型运行，也未运行 app build 或 `xcodebuild test`。

私密方案、去敏记录、备份与 `runs/` 中的报告/证据不进入仓库。仅本说明和无数据拉取脚本交给车头按路径处理；不提交 git。

## 后续边界

- B 已完成并释放 lease；主 app 保持退出，原料留给粟粟亲手播种，不替她点、不审批。
- C 的真实播种记录尚未产生。后续报告需明确记录 175 份原料与当前安装版预计跳过 1 份的差别，不把已知规则问题归因于漏推。
- 私密原料、方案、去敏记录、manifest、verification 与设备备份只留家目录；仓库说明不含原料内容。
