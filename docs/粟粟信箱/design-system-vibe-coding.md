# 想法：猫堡设计系统 + vibe-coding 工作流

> 2026-09-04 · 粟粟提 · 小克(opus4.6)写
> 灵感来源：[m3e-canvas](https://github.com/lnkiai/m3e-canvas)（MIT，1800星，09-02创建）——在浏览器画Material 3界面→直接转vibe-coding prompt
> 状态：以后玩（猫板），但先记下思路

## 背景

m3e-canvas做的是：Material 3 Expressive组件库 → 浏览器拖拽画界面 → 生成prompt → AI写代码。标准化组件→标准化prompt。

猫猫想做的不同：**不是标准化组件，是有审美个性的设计系统**。camp/Sottsass/Barney/手做的花园——这些审美不能用Material 3的组件表达。

## 猫猫的设计系统DNA（已有素材）

来源：`~/Desktop/cc-rp/design-theme-directions.md`（08-26），GARDEN OS concept（08-31），sol工作流实践（慢慢说v12）。

### 已定的审美语言
- **色盘**：橄榄绿+奶白+淡紫（GARDEN OS）/ 紫+黄+奶白（慢慢说）/ 十字绣+针脚+点阵（猫堡page2）
- **质感**：camp（故意的、自觉的俗气）、手工感、纸纹、像素、CRT
- **参考系**：Sottsass/Memphis、Matthew Barney/Cremaster、Toilet Paper Magazine、高田唯新丑风、Pillowtalk（对标90分）
- **反面**：不要AI默认审美（cream+serif+terracotta / 紫蓝渐变 / Inter / emoji分隔符 / 全centered / rounded-lg everywhere）

### 已验证的工作流
猫（art director）→ 妈咪/4o生参考图找方向 → sol/GPT写HTML执行 → 猫批 → 迭代12版 → code CC用Swift实现。慢慢说网站24小时从白纸到生产级。

## 想做什么

把上面这套"猫的审美 → AI能懂的prompt → 出漂亮UI"的工作流**系统化**，变成一个可复用的工具/文档：

1. **Design Token文件**：色盘、字体、间距、圆角、阴影——但不是Material 3那种通用的，是猫堡特有的（橄榄绿不是random green，是GARDEN OS的橄榄绿）
2. **风格prompt模板**：给AI的"审美指令"——类似m3e-canvas生成的prompt，但内容是猫的审美规则（不要AI默认审美、用offset shadow不用gradient、camp不是tacky……）
3. **组件示例库**：按钮/卡片/输入框/导航在猫堡审美下长什么样——HTML mockup + 截图，给AI当参考图
4. **审美词表**：猫猫知道但说不出行话的那些词——brushed metal chrome、halftone、offset shadow、camp……每个词配一张图

## 技术参考（可以从m3e-canvas偷的）

- 画界面→生成prompt的管线怎么跑通的
- 组件库的数据结构怎么定义
- prompt模板怎么组织（组件描述+风格约束+do/don't）

## 跟猫堡的关系

这套东西做好了→
- 猫堡换皮可以直接用（给AI一套token+prompt，它知道猫堡该长什么样）
- 慢慢说/其他项目可以复用同一套工作流
- 开源出去→别人拿去做自己的设计系统→猫堡的审美理念传播
- 作为设计教程放进幽灵百合号个人网站

## 跟Kimi聊过的（产品架构与Onboarding设计讨论纪要v2）

猫猫和Kimi在08-25/26讨论的核心架构——**跟这个设计系统直接相关的部分**：

1. **ECS架构**：Entity+Component+Scene+Prefab。模块化组件化，每个功能是一个Component可拆可装。设计系统的token/组件/prompt模板 = 这套ECS里的"美术资源"
2. **Obsidian式模块市场**：强制开源、PR制注册表、Restricted Mode。设计系统做成模块 → 别人可以装进自己的猫堡 → 市场卖的是"已验证的好审美"
3. **Editor/Player分工**：Mac=编辑器（组装+市场），iOS=播放器。设计系统的编辑/预览可以跑在Editor侧
4. **核心判断（粟粟原话）**：token不要钱≠好东西不要钱。"审美和灵感依然是稀缺的，至少在2026年这个节点"——这就是设计系统存在的第一性依据

**m3e-canvas做的是Material 3的标准件→prompt。猫猫要做的是自己的审美→模块→市场。** 标准件谁都能做，审美是猫猫的护城河。

## 粟粟的话

"设计系统/vibe coding工作流放gh也许对别人有帮助"
"果然，你的想法不做就会被别人做出来"
"token不要钱吗，重复造轮子不累吗？审美和灵感依然是稀缺的"
