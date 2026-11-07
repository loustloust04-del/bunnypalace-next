# review · mac-perf S7（sol，止血审查收口）

2026-10-16 · 基点`62f30f4bb` · [车头裁决表](plan-mac-perf.md#10-16-s7--止血审查裁决车头批准后直接实施) / [astra报告](prompts/2026-10-16-mac-perf-sol/R-stanch-astra-report.md)。

## 1. 边界情况

- 详情解析任务包含结果落地后的`beforeWaiting / Int.max / commonModes`；只有仍属当前代的observer能清解析任务、从idle起算`max(2s,10×解析耗时)`。旧代observer仍唤醒自己的continuation，但不改新代状态。
- 含详情的增量flush等待该刷新链（含pending）落地/idle，再到beforeWaiting释放增量闸、开始下一窗口。无详情变化仍直接注册列表idle，不新建等待Task。同值/解析失败也有收尾，前置检查失败沿列表释放；NO仍走原路径。
- 选新会话不等待旧同步解析，旧调度被取消且有代号守卫。真实A解析取得快照后切B，及A→B→A新正文，均等旧A真正完成再检查正文/错误/revision。
- 同选择成功与失败都在解析进行中检查loaded/静默指示；失败保旧用的是仍存在、非空但不可读的tmp fixture，错误来自真实Claude解析，不再用删文件触发前置检查失败。
- 大文件/反复手动刷新会延长含详情的列表闸；主线程不阻塞等待解析，但列表与新回复可见更新更晚。仍无最大延迟保证，beforeWaiting也不等于GPU呈现结束。未换父视图/滚动宿主。

## 2. 与下一阶段交互风险

- `mp.stanch.K0-min`仍为唯一相关开关，不改K1-dirty、R-tab、H1/S1/P1；隐藏转dirty、初选loading及既有滚动意图继续由原实现处理。
- plan §4明确`MP_PERF_<刀>`未实现，R1才接并核验有效配置；本批不得靠env做A/B。R1、bench隔离及GUI回归均未启动，不能把本次测试宿主隔离当bench证明。
- 启动manifest读、active Code SQL、真实日常卡顿率仍未解决/验证。推荐收S7后由车头合并，不在合并期间继续提交。

## 3. 技术债与验证

- 修前真实runloop复现1测3断言失败：布局后下一解析仅0.00405s（要求2.25544s），增量闸提前释放。修后整类16测0失败，grep原文`Test Suite 'CodingSessionLibraryTests' passed at 2026-10-16 18:13:39.434.`，且`** TEST SUCCEEDED **`。
- 实际快照闸将三次写入分散到冷却及解析取快照后；解析3次无重叠，末条精确`burst-2`，布局后2.44220s≥2.23744s，最终解析后下一flush观察间隔2.60768s。3s主线程忙段是受控长布局模拟，不是实际UI或生产性能数据。
- A→B迟到后revision=2→2，A→B→A=3→3且保留独有新正文；真实不可读错误保正文、revision=1→1、错误可见。同值仍revision=1→1。
- 合并旧的弱时序测试，整类18→16；只扩展同文件专用真实adapter，没有新测试框架/通用helper库。产品+45/-13共58改动行，测试+110/-88，新增110≤2×58=116；此处产品预算按增删改动计，不宣称测试新增≤产品新增45×2。
- 测试宿主输出临时home/suite及xctestVisible=1；仍有既有其他fixture用例的SQLite vnode unlink警告，未掩盖/顺手修。本轮未重跑NO，原NO路径未改，S6回退记录保留。
- 外部证据1份：`~/MemoryPalace-docs-media/perf-mac/sol/S7-review-verification.txt`，小于1MB，不入git；无原始现场材料或个人数据入库。未操作她的app、真库、偏好、iOS或设备。
