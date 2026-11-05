# 建议：开发流程七条可优化项

> 2026-09-02 · 🎩 写（构建提速一刀收口时在机器上看到的）· 粟粟「先记到信箱」· 状态：**待粟粟挑**
> 证据都在 [research-ish-spm-modularize](../research-ish-spm-modularize.md) / [report-build-speed-2026-09-02](../report-build-speed-2026-09-02.md) / [review-build-speed](../review-build-speed.md)。按性价比排序，只做一件就做第 1 条。

## 1. 机器并发是第一瓶颈，比任何工程配置都大 ⭐

- 现象：下午 load 长期 75–270，29 个终端 session，三台模拟器常驻，Docker VM 吃 CPU，另两个 CC session 同时跑 UI 测试和构建。同一次全量 load 200 下 10.6 分钟，空机约 4–5 分钟。shim 只能让 xcodebuild 排队，管不到模拟器和 Docker。
- 建议：同一时刻只让一条 lane 干「会 build」的活，其余 research / 写文档；Hermes 不用就停 Docker（09-02 已停）；派单前 `uptime` > 20 就不派构建型任务。
- 代价：零代码，是派单纪律。

## 2. 每个 worktree 一份 DerivedData，首次全量十几分钟

- 现象：12 份 DerivedData 共 39G；新 worktree 首次 iOS 全量 701s。编译缓存试过：跨目录命中一半、SwiftCompile 总时间只降 5%、CAS 每份 +0.6G，救不了。
- 建议：小活直接在 master 做（规则已有，但今天仍有多个 agent worktree 在编）；lane 用完立刻删 worktree + 它的 DerivedData；长期 lane 复用不新建。
- 代价：纪律 + 一条清理脚本。

## 3. 各 session 的 xcodebuild 写法不统一，每次切换都在付税

- 现象：今天看到三种写法：模拟器 `id=`、模拟器 `name=`、命令行带 `DEVELOPMENT_TEAM=` 覆盖。命令行 build setting 对 SPM 包也生效，两种写法交替就让包重编（SwiftStreamingMarkdown 46 批 + Equatable 3 批）再拖 app 重新 emit module，约 40–100s/次。**这条是从 R1/F1 现象推的，F3 对照没跑完，未证实。**
- 建议：定唯一一条 iOS 构建命令进 CLAUDE.md：模拟器固定用 id，不在命令行传任何 build setting（Team ID 已在 project.yml）。最省事的落法是 shim 自动纠正。
- 代价：shim 加十几行，半小时。

## 4. 给构建时间留数据，别靠感觉

- 现象：「经常十几分钟」查下来是三种不同场景混在一起（脚本重写头 / 新 worktree 全量 / 过载）。试点时私有 DerivedData 跑完即删，逐任务时长也跟着没了。
- 建议：shim 顺手记一行日志到 `~/.local/share/mp-build-times.log`：时间、cwd、目的地、load、墙钟，并默认加 `-showBuildTimingSummary`。下次觉得慢，一行命令看出是哪种慢。
- 代价：三十行脚本。可与第 3 条一起做。

## 5. 单模块 13 万行的固定税

- 现象：任何 Swift 改动都付 `SwiftEmitModule`，空机 10s、忙时 60s。慢表达式扫描 133 条 / 177s：`ContentView.swift:143 body` 45s + `:596 iOSLayout` 26s 占四成；Sidebar / SearchService / RecallTool 的 `#Predicate` 系约 30s。
- 建议：先做便宜的——ContentView 两个 getter 按现有分支拆成 `@ViewBuilder` 子属性，`#Predicate` 拆小，不改行为，做完复跑同参数看数字。拆 Swift 包是周级工程，上面几条都做完还嫌慢再谈。
- 代价：半天，另起 plan。

## 6. 两个正确性 / 固定成本坑顺手补

- cc-bridge 重编哈希只盖 8/30 源文件（`scripts/build-cc-bridge.sh:32-41`）：改 `stream-runner.ts` `askuser.ts` `terminal-*.ts` 等不会重编 bundle 里的 hub，可能一直在跑旧 hub。修法：哈希 `cc-bridge/*.ts` 去掉 `*.test.ts`。五分钟。
- asset catalog 按设备 thinning：换目的地必重跑，空机 7–10s、忙时 24–68s，还会重生成 `GeneratedAssetSymbols.swift` 拖一次 emit module。Debug 配置 `ENABLE_ONLY_ACTIVE_RESOURCES = NO` 候选，先量再做。

## 7. 文档本身在变成负担

- 现象：NOW.md 规则 ≤100 行，现在 250 行，每个 session 开工都要读完；PROJECT_ROADMAP.md 等几个文件被别的 session 改了一下午没提交，一直躺在 master 工作树里。
- 建议：NOW.md 只留「现在在做什么」+ 链接，做完的块沉到 roadmap / CHANGELOG；每个 session 改完文档当场提交，别让半成品在共享工作树里过夜。
- 代价：一次整理 + 纪律。
