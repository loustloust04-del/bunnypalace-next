# 编辑器方向 A · 切片 0 复盘

本轮仅加入默认关闭的 DEBUG 观测，不包含撤回 / 闪烁修复。实施与采样说明：[plan-editor-converge-A.md](plan-editor-converge-A.md)。

## 1. 边界情况

- 开关仅在 DEBUG 创建 markdown-editor 的 WKWebView 时读取 `MP_EDITOR_PROBE=1`；环境变量改变后须重启 App、重开编辑器。Release 不包含 Swift 探针 / 注入路径；JS 未获得严格 true 标志时不注册观测。
- beforeinput 在 document capture 阶段记录一次、下一帧再记录一次；前者不代表 CM 最终是否 cancel。多次快速输入可在同一帧结束时观察到相同最终深度，不能按每条 afterFrame 猜独立历史步。
- 原生 KVO / 键盘通知和 JS bridge 是异步链路，原生快照是收到消息时的数据。用 instance、JS sequence、JS / 原生时间区分，不声称同一帧原子采样。
- 没有修改滚动配置、delegate、正文、撤销事务或系统手势。探针失败不会重试 / 回写编辑器；原生 JSON 序列化失败不发该条日志。
- 仅记录事件、数值和选区偏移，不记录正文 / 输入字符 / 文件路径。info 级公开元数据便于 simctl 读取，采样仍应只用脱敏文本。

## 2. 与下一切片的交互风险

- F1 / F2 / U1 尚待车头设备采样：桌面 Chromium 冒烟证明观测和 CM 历史深度能输出，不证明 iOS WebKit 的键盘 / 系统撤回实现正确。
- 键盘接管方案必须结合 WK contentOffset / inset、window.scrollY、visualViewport 及 CM scrollTop 的时序决定；不能仅看最终 offset=0 就增加新的补偿器。
- 系统手势第二档依赖 WKContentView runtime 行为，仍需粟粟拍板；本轮未覆写 undoManager、未关全 App 摇一摇。
- 同文档外部写入可撤、源码切回合成一步是计划中的可见行为变化，未获额外确认前不实现。版本历史数据格式完全未动。

## 3. 技术债务 / 验证限制

- 原生 os_log / KVO 的设备端输出和开关关闭对照，按任务书留给车头安装后实测；没有安装 / 启动模拟器或真机，没有把静态编译当成设备成功。
- 开启探针会增加 bridge / JSON / 日志开销，不用于生产性能结论。默认关闭无原生观测，也不采集 JS 样本；切片 1…N 的滚动对照应记录开启 / 关闭两种状态。
- 没有新增永久测试：本轮不改产品行为；使用真实页面 throwaway 冒烟覆盖开关、输入、撤销 / 重做、合成 historyUndo 采样和实际缩放 / 滚动。未运行单元测试，不能声称测试套件通过。
- 双端 build-for-testing 已完成：macOS MemoryPalaceTests / iOS MemoryPalaceIOS（iPhone 17 Pro，iOS 26.4.1）均观察到 `** TEST BUILD SUCCEEDED **`；没有绕过全机锁，未指定 derivedDataPath。
- 自动化长文本输入发生工具 8 秒超时且继续打字，后续未重试该输入；用已形成的长文完成滚轮 / resize 断言。浏览器页面已关闭，无临时脚本或样本进入仓库。
- JS 源码直接加载，本轮未修改 codemirror.bundle.js，也未新增 Swift 文件；不需要 bundle 重建或 xcodegen generate。
