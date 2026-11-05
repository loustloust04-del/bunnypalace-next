# 1003 开源清理（第 1 批 7 单 → #006–#012）

来源：memorypalace-5f（misc 工位，开源规划 session）10-03 SendMessage，转述「粟粟批了 docs/plan-open-source.html（misc fc32e735）的方案和决策；5f 提出把清理交给 Dex，她 5 分钟没反对」——**不是粟粟在 Dex 窗口亲口说的**。目标：10/31 冻结，11 月第一周公开。细节和证据在 docs/audit-open-source.md §6（misc ece1e1de）。

第 2 批（W3–W4：README / BUILDING / ARCHITECTURE / CONTRIBUTING + CLA-assistant、GitHub Actions 干净克隆编译、Team / bundle / AppGroup / iCloud / Sparkle 改 xcconfig，fork 默认关自动更新）和第 3 批（只在 10/31 冻结日、合并队列空时跟 Warden 协调：209 个文件约 440 处提到粟粟 / 小克 / 小雾的注释一次扫完；纯决策史删掉、技术原因保留去人名；然后出快照推 replica882/mneme-atrium，该仓已公开）**到时候再建任务**，现在不进 todo。

不归 Dex：吊销 app 专用密码（粟粟自己做）、问 OpenMinis 作者 App Store 豁免（粟粟发）。

原话（第 1 批）照录：

> Batch 1, start now. These avoid files that in-flight zones are editing:
> 1. Licenses: add rootshell + Wake attribution in 3 places, refresh THIRD_PARTY_LICENSES.md, fix the cc-bridge ATTRIBUTION, add the GPLv3 + OpenMinis header to the 7 Sandbox/ish glue files, add the Alpine GPL source-offer note. (audit §5, §6 "W2 许可")
> 2. Clean-room rewrite of DustEffect.metal and SpoilerDust.swift from an algorithm description. Telegram's versions are GPLv2, which is incompatible with AGPL. Do not look at the Telegram source while writing. (~3h)
> 3. Delete Services/CCReplayCleaner.swift plus its settings entry.
> 4. Add a PERSONAL_APPS compile flag covering 死亡天平, 军机处/warroom, 交易/trading, PMBoard, and the kimi-p LAN provider. The private build stays unchanged; the public snapshot excludes them.
> 5. Buildability: make the gitignored resources in project.yml optional, have build-cc-bridge.sh read signing identity/Team from env (ad-hoc by default), commit bun.lock and the root Package.resolved, add a sha256 check to the rootfs download, fix the build-cc-bridge cache-key bug, state Xcode 26+. (audit §4)
> 6. Write scripts/export-public.sh as a whitelist export to a clean dir. This script stays in the private repo. (audit §3)
> 7. Replace the persona names in AI/UI strings (about a dozen) with persona variables. Strings only, NOT comments. (audit §2.2 #3, #6, #9)
