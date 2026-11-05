# research — 隐私合规（隐私政策 / 服务条款的事实基础）

> 目的：为隐私政策与服务条款正文建立可追溯的事实基础。
> 结论先行：**写正文之前，先挖出两个会阻断上架的问题**（§一、§二），它们比正文更急。
> 所有结论均带代码位置；无法确认的标「未确认」，不猜。

## 一、⚠️ 隐私清单缺声明 —— App Store Connect 会直接拒收

### 1.1 Apple 的规则原文

> "Starting May 1, 2024, apps that don't describe their use of required reason API in their privacy manifest file aren't accepted by App Store Connect."
> —— [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)（xcdocs 取回原文）

不是审核时人工挑刺，是**上传即被自动拒**（ITMS-91053）。粟粟正在走 TestFlight，**提交就会撞上**。

### 1.2 现状：清单只声明了 UserDefaults

`MemoryPalace/PrivacyInfo.xcprivacy` 逐字：

```xml
NSPrivacyTracking           → false
NSPrivacyTrackingDomains    → （空）
NSPrivacyCollectedDataTypes → （空）
NSPrivacyAccessedAPITypes   → 仅 UserDefaults，理由 CA92.1
```

### 1.3 实际用到但未声明的两类

**FileTimestamp** —— 至少 12 处：

| 文件:行 | 用法 |
|---|---|
| `Services/SyncStore.swift:354,435,520` | `.contentModificationDateKey` |
| `Services/FileLibraryStore.swift:217,234,245` | `attributesOfItem` / `.contentModificationDateKey` |
| `Services/AudiobookFileManager.swift:103` | `attributesOfItem` |
| `Services/FeedbackStore.swift:39` | `attributesOfItem[.modificationDate]`（构建时间） |
| `Views/Vocab/VocabSettingsTab.swift:18-19` | `attributesOfItem[.modificationDate]` |
| `Views/MemoryPageContent.swift:526-527` | `attributesOfItem[.modificationDate]` |

Apple 归入此类的 API 含 `modificationDate` / `creationDate` / `contentModificationDateKey` / `stat` / `lstat` / `getattrlist` 等。注意 `attributesOfItem` 本身不在列表，但它底层走 `lstat`，Apple 的检查基于二进制符号，**会被检出**。

**DiskSpace** —— 2 处：

| 文件:行 | 用法 |
|---|---|
| `Services/BackupStore.swift:781-782` | `volumeAvailableCapacityForImportantUsageKey` |
| `Services/DeviceTools/DeviceInfoTool.swift:37,40-42` | 同上 + `volumeTotalCapacityKey` |

### 1.4 官方 reason 定义（原文，用于选码）

**FileTimestamp**：
- `DDA9.1` — 向使用设备的人显示文件时间戳。**信息及其衍生信息不得离开设备**。
- `C617.1` — 访问 **app container / app group container / app 的 CloudKit container** 内文件的时间戳、大小或其他元数据。
- `3B52.1` — 访问**用户明确授予访问权**的文件或目录（如 document picker）的元数据。
- `0A2A.1` — **仅限第三方 SDK** 的包装函数，app 不可用。（ZIPFoundation 自带清单用的正是这个，符合它的身份；主 app 不能照抄）

**DiskSpace**：
- `85F4.1` — 向用户显示磁盘空间。**不得离开设备**（例外：局域网内同一用户的另一台设备，需明确许可，且不得经互联网）。
- `E174.1` — 检查空间是否足够写入，或空间不足时删文件。**app 行为必须随空间变化且用户可观察**。**不得离开设备**（例外：空间不足时不下载）。
- `7D9E.1` — 用于用户**主动提交**的 bug 报告，且必须向用户显著展示。
- `B728.1` — 健康研究 app 专用，不适用。

### 1.5 该选哪几个

- FileTimestamp → **`C617.1` + `3B52.1`**
  C617.1 覆盖 app 容器内（备份、文件库、单词库、有声书、构建时间）；3B52.1 覆盖 document picker 导入的外部文件 —— app 确有此路径（`MemoryPalaceApp.swift:1208` fileImporter、`StickerImportSheet.swift:173` NSOpenPanel、多处 `startAccessingSecurityScopedResource`）。
- DiskSpace → **`E174.1`**（仅 BackupStore 的用法符合：写备份前检查空间，行为随空间变化且用户可见）

**每个 bundle 各自声明**：ZIPFoundation 有自己的清单管自己的代码，不能替主 app 声明；主 app 自己的 12 处必须写在主清单里。

## 二、⚠️ `device_info` 的 storage 与 DiskSpace 政策冲突

`Services/DeviceTools/DeviceInfoTool.swift:35-42`：`kind=storage` 返回 `free_gb` / `total_gb`。

这是**给 AI 用的工具**（`ToolDefinition`，system 类「永远放行，不进权限页」，`:6`）。工具结果会作为 tool result **回传给模型** —— 而模型默认是用户配置的**云端**服务商。

对照 §1.4：DiskSpace 四个 reason **没有任何一个允许把磁盘空间发到互联网**。85F4.1 与 E174.1 都明写 "may not be sent off-device"，85F4.1 的局域网例外还特别排除了互联网；7D9E.1 只允许随用户主动提交的 bug 报告走。

即：**只要 device_info 的 storage 能被云端模型调用，就没有可声明的合法 reason**。

> 同文件的 `battery`（`UIDevice.batteryLevel`）与 `physical_memory_gb`（`ProcessInfo.physicalMemory`）**不在** required reason API 列表内，不受此限。问题只出在 storage。

<⧫ 粟粟拍：
  A. 删掉 `kind=storage`（最干净，battery/info 保留）
  B. storage 只在本地模型（Ollama 等）下可用 —— 要按 provider 判，实现脆弱，且"本地"的判定容易漏
  C. 保留现状，接受政策违反的风险
  我倾向 A：这个 kind 的实用价值低，换不来一条无解的合规缺口。
⧫>

## 三、数据流全景（隐私政策的事实基础）

### 3.1 对外网络出口

| 出口 | 目标 | 发什么 | 默认 |
|---|---|---|---|
| AI 对话 | **用户自配服务商**（17 家预设） | 对话正文、附件、系统提示、记忆事实；**健康/日历数据在启用后随对话一并发送** | 不填 key 不联网 |
| 联网搜索 | Tavily/Exa/Brave/Perplexity 等 12 家 | 搜索查询词 | **默认关**（`PermissionCenter:62`） |
| 语音合成 | `api.elevenlabs.io` | 待合成文本 | 需自填 key |
| MCP server | **用户自配 URL** | 工具名/参数/结果 | 用户添加；有 `sendToolsEnabled` 总开关 |
| CC Bridge hub | **默认局域网**，用户自己的 Mac | 对话内容、APNs token | 需扫码配对 |
| APNs | **经 CC hub 转发**，app 不直连 Apple | token + env + preview 偏好；模拟器不上报 | 需推送授权 |
| Agora | CC hub | ws 消息 | **默认关**（`AgoraFeatureGate:8`） |
| 应用内浏览器 | 用户导航到的站点 | 用户操作决定 | 用户主动 |

**零遥测**：全仓无 Sentry / Crashlytics / Firebase / Mixpanel / Amplitude / PostHog。反馈面板只本地落盘，**无上传代码**。
**不联网的模块**：交易、单词、阅读（三者均无 `URLSession`，数据只经 AI 对话出去）。

### 3.2 本地存储

- **SwiftData**：`~/Library/Application Support/MemoryPalace/unified.store`，**显式 `cloudKitDatabase: .none`**（`MemoryPalaceApp.swift:195`）→ 数据库永不进 CloudKit
- **Keychain**：API key，service `com.susu.MemoryPalace.apikey`；`kSecAttrSynchronizable` 由 `apiKeyCloudSync` 控制，**默认关**
- **App Group** `group.com.susu.MemoryPalace`：chat-index / profile-cards / 头像（供推送扩展读标题）
- **iCloud** `iCloud.com.susu.MemoryPalace`：**只同步文件库 `filesystem/`，默认关**（`FileLibraryStore:28-35`，注释原文「记忆树永远本地」）

### 3.3 权限与实际用途

| 权限 | 实际用途 |
|---|---|
| 本地网络 | 连 Mac 上的 CC Bridge hub、本机 AI 代理 |
| 日历 / 提醒（含 Full Access） | AI 按要求增删查 |
| 相册读 / 写 | 选图发 AI / 保存便签图 |
| 相机 | 扫码配对、拍照发 AI |
| HealthKit 读 | 步数/睡眠/活动/心率/锻炼 → **随对话发给用户配置的 AI** |
| HealthKit 写 | **从不写入**，仅为满足 Apple 模板规范而声明 |

## 四、隐私政策正文的硬约束（据上述事实）

1. **绝不能写「数据不出设备」**。对话正文默认就会发给用户选的服务商；健康与日历数据在启用后也随对话出去。准确表述是：**「我们不收集；但你发出的内容会到达你自己选择的服务商」**，并点明健康/日历的去向。
2. 可以写且属实的：无自建后端、零遥测、无广告、不追踪（`NSPrivacyTracking=false`）、API key 只存 Keychain、数据库不进 iCloud。
3. 要点名各项默认状态（联网搜索默认关、Agora 默认关、iCloud 文件同步默认关、API key 云同步默认关）—— 默认关是实打实的隐私优势，值得写。
4. HealthKit「只读不写」要明说。

## 五、下一步

- [ ] 粟粟拍 §二 的 A/B/C
- [ ] 修 `PrivacyInfo.xcprivacy`（补 FileTimestamp C617.1+3B52.1、DiskSpace E174.1；若选 A 则 DeviceInfoTool 同步改）
- [ ] 写隐私政策正文 → 粟粟审
- [ ] 写服务条款正文 → 粟粟审
- [ ] 两页实现 + 搜索注册表 + 验证
- [ ] `manual/facts/` 说明书同步
