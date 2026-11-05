# 问题：iSH 模块 SPM 包化——加速增量编译

> 2026-09-02 · 粟粟提 · 小克(opus4.6)写
> 状态：**已答**（09-02 🎩）→ [`docs/research-ish-spm-modularize.md`](../research-ish-spm-modularize.md)。结论：不做 SPM 化（≤2s/次）；iSH 拖慢是真的但机制是 `build-ish.sh` 每次被触发都重写 `deps/include/ish/*.h` → bridging header 变 → 481 个 Swift 全重编（本机实测 25s vs 87–113s）；修脚本幂等 + 模拟器排除 x86_64 两行药 → **已落地 `cd0760fa`**（换目的地 SwiftCompile 501 → 0）；编译缓存/慢表达式试点数字在 [`report-build-speed-2026-09-02.md`](../report-build-speed-2026-09-02.md)（缓存不开；ContentView.body 45s 是下一刀）

## 问题

Air 增量编译经常要十几分钟。主要慢在 iSH 模块——iSH 是一个完整的 iOS 内置 Linux 沙箱（Alpine + 虚拟机层），代码量大、C/汇编混编，每次主 app 改动如果触发 iSH 重编就很慢。

## 想做什么

把 iSH 相关代码拆成独立的 **Swift Package**（SPM 本地包），这样：
- iSH 自己代码没变 → 不重编（Xcode 增量编译按 target 粒度判断）
- 主 app 只需要 import 这个包，改主 app 代码不触发 iSH 重编
- 编译时间从"每次都编 iSH"变成"只有动了 iSH 才编 iSH"

## 需要 code CC 回答的

1. **当前 iSH 的编译依赖关系是什么？** iSH 代码在仓库的什么位置？它跟主 app 有哪些接口点？能不能干净地切开？

2. **SPM 包化的具体方案？**
   - 哪些文件/目录进包？
   - Package.swift 怎么写（C target + Swift target 混编？）
   - 主 app 侧 import 怎么改？
   - iSH 的 submodule（`deps/ish`）怎么处理？

3. **预估收益多大？** 能省多少编译时间？有没有什么坑（比如 C 代码跟 Swift bridging header 的兼容性、sandbox entitlement 的位置等）？

4. **有没有除了 iSH 之外的其他编译大户？** 如果顺手还能拆别的就一起评估。

## 背景

- 仓库 13.9 万行 Swift + iSH submodule
- 编译环境 MacBook Air（CPU/散热有限）
- iSH 在 `deps/ish` 子模块，Phase 2 已合 master（`dc61425d`，700 测绿）
- iSH 相关的 app 侧代码在 `MemoryPalace/` 内（SandboxService 等）
- 已有的 SPM 本地包先例：`MemoryPalace/Vendor/ThinkingOrbsKit/`（思考球，纯 Swift，已跑通）

## 粟粟的话

"主要ish很慢…我想试试ish模块化spm包化"
