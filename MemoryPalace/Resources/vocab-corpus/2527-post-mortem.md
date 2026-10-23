# post-mortem

---

## 1. 一句话本质

**post-mortem 是停下来翻尸体的动作——事情已经死了，你不是去救它，而是划开来看它到底怎么死的。**

不是悼念，不是归咎，是一种冷静到近乎冒犯的求知欲：死都死了，至少让我搞明白。

---

## 2. 词源考古

### 词根词缀拆解

```
post-mortem
│       │
│       └── mortem ← 拉丁语 mors（死亡）的宾格形式
│           印欧语根 *mer-/*mor-（死亡）
│           → 同根词：mortal, mortality, murder, mortuary, mortgage
│
└── post ← 拉丁语介词/前缀，"在……之后"
    → 同根词：postpone, posterior, postscript, posthumous
```

合起来就是字面意思：**"在死亡之后"**。这是一个完整的拉丁语介词短语被直接搬进了英语——连语法结构都没改，`post` + 宾格名词。

### 一个彩蛋：mortgage 为什么也在这

mortgage = mort（死）+ gage（抵押）。"死的抵押"——要么你还清贷款，抵押"死了"（作废）；要么你还不起，你的产权"死了"（被收走）。无论哪种结局，这个契约最终都会"死"。和 post-mortem 共享同一个对死亡的冷静凝视。

### 历史流变

**17世纪以前**：纯拉丁语短语，出现在医学和法律文书中。拉丁语在欧洲学术界是通用语言，医生和法官写报告时自然用 *post mortem*（死后）。

**17-18世纪**：英语正式吸收这个短语。最初的完整形态是 **post-mortem examination**（死后检查），即尸检/验尸。这个时期的解剖学在欧洲蓬勃发展，尸检从宗教禁忌逐渐变成法律和医学的标准程序。词语跟着实践一起进入日常英语。

**19世纪**：*post-mortem examination* 被缩短为 **a post-mortem**（名词化）。这是英语的惯性——太长的专业术语最终都会被截短。同期，这个词开始出现隐喻用法：不只是对尸体的检查，而是对"已经结束的事"的检查。

**20世纪中叶→今天**：隐喻义彻底起飞。军事领域最先大量使用——战后复盘叫 post-mortem。然后蔓延到商业（项目失败后的复盘）、体育（赛后分析）、政治（选举后的反思）。

**21世纪科技文化**：这个词在硅谷被制度化了。Google 的 SRE（网站可靠性工程）体系推广了 **blameless post-mortem**（无责复盘）的概念——系统挂了不是找人骂，而是找系统性原因。这个用法如今已经是科技行业的标准术语。有些公司觉得"死亡"隐喻太阴暗，改叫 **retrospective** 或 **incident review**，但 post-mortem 的统治地位没有动摇。

### 文化地层：一个有趣的张力

这个词的内核有一种冷酷的诚实：**它预设了"死亡"是前提**。你不会对一个还活着的项目做 post-mortem。用这个词，就是在宣告——这件事已经结束了，已经失败了，或者至少这个阶段已经死了。这种直面死亡的态度，和英语文化中"正面刚"的问题解决风格一脉相承。

而中文语境里，我们倾向于说"复盘""反思""总结"——都是更中性的词，没有"死亡"的意象。这本身就是一个有意义的文化差异。

---

## 3. 故事 / 画面

一张不锈钢手术台。上面躺着的不是人——是一个项目的时间线，被铺平了，像一具展开的标本。

法医（你）站在旁边，手术灯把一切照得惨白。你拿着手术刀，沿着时间线一刀一刀划开：

这里——第三周——需求变了但没人说。切口干净，伤口不深，但感染从这里开始。

这里——第六周——测试被跳过了。你用镊子挑出一段烂掉的代码，举起来对着灯看。嗯，这就是败血症的源头。

这里——上线当天——流量是预估的十倍。直接原因。但你知道，这不是真正的死因。真正的死因在第三周就埋下了。

你把发现写进报告。报告的标题不是"谁杀了这个项目"，而是"这个项目的死亡机制"。

**这就是 post-mortem 的精确质感：不是审判，是解剖。不是向后看以分配责任，是向后看以获取情报。**

---

## 4. 多面体：核心义项展开

### 义项一：尸检（医学/法律原义）

> *The post-mortem revealed that the cause of death was a cerebral hemorrhage, not the fall itself.*
> 尸检显示，死因是脑溢血，而不是坠落本身。

与本质的关系：最字面的"死后打开来看"。划开身体，找到真正的死因——表面原因往往不是真正原因。

### 义项二：事后分析 / 复盘（最常见的现代义）

> *We ran a post-mortem on the product launch and identified three systemic failures.*
> 我们对产品上线做了一次复盘，识别出三个系统性失败。

与本质的关系：项目/事件"死了"（结束了、失败了），你用同样的法医心态去解剖它的过程。核心动作不变：**打开、观察、记录因果链**。

### 义项三：形容词用法——"死后的"

> *Post-mortem changes in the tissue made it difficult to determine the exact time of death.*
> 组织的死后变化使得精确判定死亡时间变得困难。

与本质的关系：回到字面——描述"发生在死亡之后"的状态或过程。

### 义项四：赛后/事后的评论分析（偏口语/媒体）

> *The post-mortems on the election results dominated the news cycle for weeks.*
> 对选举结果的事后分析占据了好几周的新闻周期。

与本质的关系：选举"死了"（结束了），各路评论家像法医一样把它翻来覆去地检查。带有一丝"事后诸葛亮"的味道——但 post-mortem 比"事后诸葛亮"更中性，它不一定是马后炮，可能是真诚的结构性反思。

### 底层统一性

所有义项共享一个结构：**X 已经结束/死亡 → 回过头系统地检查 X → 目的是理解因果机制**。这个结构解释了为什么它能从尸检自然地延伸到项目复盘——因为底层动作是完全同构的。

---

## 5. 裂缝标注

### 常见误用场景

**❌ 对正在进行的事用 post-mortem**

> 错：*Let's do a post-mortem on this project.* （项目还在跑）

post-mortem 预设对象已经死了/结束了。如果项目还活着，你应该说 **review**、**check-in**、**audit** 或 **health check**。对活物做 post-mortem，在英语母语者耳中听起来像你已经宣判了它的死刑。

**❌ 把 post-mortem 当"批斗会"用**

post-mortem 的精神是 **diagnostic**（诊断性的），不是 **punitive**（惩罚性的）。科技行业特别强调 **blameless post-mortem**（无责复盘），就是因为太多人把它开成了追责会。如果你的 post-mortem 最后只找到了"某个人犯了错"，那你做的不是 post-mortem，而是 witch hunt（猎巫）。

### 易混近义词辨析

| 词 | 区别 |
|---|---|
| **review** | 更中性。可以对活着的事做 review，不预设死亡/失败。"Let's review the project" = 看看进展如何 |
| **retrospective** | 和 post-mortem 最接近的替代词，但语气更柔和，没有"死亡"意象。Agile 开发用 retro 多过 post-mortem |
| **debrief** | 军事起源。侧重"执行完毕后汇报/还原过程"，不一定有"失败"的含义。你可以 debrief 一次成功的行动 |
| **autopsy** | 几乎只用于字面意义的尸检。隐喻用法存在但远不如 post-mortem 常见 |
| **hindsight** | "事后之见"——描述的是视角（回头看），不是动作（系统性分析）。"In hindsight, we should have..." |

### 中文母语者陷阱

**陷阱一：直译成"死后"导致使用犹豫**

中文母语者知道 mortem = 死，会觉得这个词太"重"，在商务场合不敢用。实际上，在英语里 post-mortem 已经完全去了死亡的沉重感——说 "Let's schedule a post-mortem" 就像说"我们安排个复盘会"一样自然，没有人会觉得你在诅咒什么。

**陷阱二：和"复盘"的微妙差异**

中文的"复盘"来自围棋，本义是"重新摆一遍棋局"。它是中性的，成功的棋局也可以复盘。但 post-mortem **倾向于隐含失败或问题**——你不太会对一个大获成功的项目说 "Let's do a post-mortem"（虽然不算语法错误，但感觉怪怪的，像在说"这个成功到底是怎么发生的，让我们来解剖一下"）。

**陷阱三：连字符问题**

post-mortem / postmortem / post mortem 三种写法都存在。英式英语偏好 **post-mortem**（带连字符），美式英语偏好 **postmortem**（连写），拉丁原文是 **post mortem**（分写）。在科技写作中，postmortem（连写，不加连字符）最常见。都对，但保持一致。

---

## 6. 搭配与语域

### 高频搭配

| 搭配 | 语境 |
|---|---|
| **conduct / carry out a post-mortem** | 正式用法。"The team conducted a post-mortem on the outage." |
| **run a post-mortem** | 科技圈口语。比 conduct 随意。 |
| **blameless post-mortem** | 科技行业术语。复盘不追责个人，关注系统性因素。 |
| **post-mortem report / document** | 复盘的产出物。 |
| **post-mortem examination** | 医学/法律全称。现在更多缩写为 post-mortem。 |
| **post-mortem analysis** | 学术/正式分析。 |
| **election post-mortem** | 媒体/政治。选后各方反思。 |
| **post-mortem on [something]** | 最常见的介词搭配。"a post-mortem on the failed merger" |

### 语域标注

- **医学/法律**：正式术语，和 autopsy 平行使用
- **科技/工程**：半正式，已成行业标准用语（Google SRE 手册级别的制度化程度）
- **商业/管理**：正式到半正式，boardroom 和 all-hands 都能用
- **新闻/媒体**：常见于政治评论和体育报道
- **日常口语**：偶尔用，带一点黑色幽默——"Let me do a post-mortem on my failed relationship"（让我来解剖一下我失败的恋爱关系）

### 活用示范

> *"Every incident gets a postmortem. Not because someone screwed up — because the system allowed it to happen. If a junior engineer can bring down production with one bad deploy, that's not a people problem. That's an architecture problem."*
> ——典型的硅谷 SRE 文化宣言。注意这里 post-mortem 的精神：系统视角，不是个人视角。

> *"The post-mortem on Brexit will take a generation to write."*
> ——政治评论。暗示 Brexit 的影响如此深远，以至于"解剖"工作本身就需要几十年才能完成。

---

## 7. 跨语言映射

**中文"复盘"** vs **post-mortem**：
复盘来自围棋，底色是"重走一遍过程以提取教训"。它是中性的，甚至带着一丝优雅——棋手复盘是修炼的一部分。Post-mortem 的底色更冷，更临床——你面对的不是一盘棋，而是一具尸体。复盘可以是愉快的（一盘好棋也值得复盘），post-mortem 几乎总是沉重的。

**日语「検死」（けんし）**：
字面"检查死亡"，几乎完美对应 post-mortem 的医学义。但日语在引入商业/科技义时直接音译了英语：**ポストモーテム**。这说明日语认为本土词汇无法覆盖 post-mortem 在科技语境中的那层含义。

**德语 Obduktion**：
用于医学尸检，来自拉丁语 obductio（覆盖/打开）。德语在科技语境也直接用英语 Postmortem。有趣的是，德语自己的词 **Nachbereitung**（事后处理/复盘）听起来太行政了，缺乏 post-mortem 那种"解剖死因"的锐度。

**拉丁语原始语境**：
在拉丁语里，*post mortem* 就是一个普通的时间状语——"在死后"。它没有任何"分析/检查"的含义。是英语给这两个字赋予了"解剖性审视"的行动含义。语言的进化：一个时间标记变成了一种认知方法论。
