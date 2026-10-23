# documentation

## 1. 一句话本质

documentation 是**给未来的人留路标**——你把脑子里知道的东西钉在纸上，好让下一个走到这里的人（包括三个月后的你自己）不用重新摸黑。

它不是"文件"本身，而是**制造可追溯性的那个动作和结果**。一份 document 是一张纸；documentation 是你在荒野上插满路标的整个行为，加上路标本身构成的那张网。

---

## 2. 词源考古

### 词根词缀拆解

```
document·ation
│          │
│          └─ -ation（拉丁后缀 -ātiōnem）
│             = "做……这件事" / "做……的结果"
│             行为名词化：把动词变成"过程+产物"
│
└─ document（← 拉丁语 documentum）
   │
   doc·u·ment·um
   │         │
   │         └─ -mentum（拉丁后缀）
   │            = "用来做……的工具/手段"
   │            如 instrumentum（工具）、monumentum（纪念物）
   │
   └─ doc- ← docēre = "教"
      ← 原始印欧语 *deḱ-（接受、认为合适）
```

关键解码：**docēre 的原始含义不是"往脑子里塞东西"，而是"让人接受/让人觉得对"**。所以 documentum 最初的意思是"用来让人信服的东西"——一个证据，一个教训，一个范例。

### 历史流变

**公元前 1 世纪 · 拉丁语 documentum**
西塞罗用这个词的时候，它的意思还是**"教训、范例、警示"**——偏精神层面。"这件事是个 documentum"≈"这件事给我们上了一课"。

**中世纪拉丁语 · 12-13 世纪**
⚡ **第一次漂移**：从"教训"滑向"证据"。中世纪的法律和教会系统需要大量书面凭证，documentum 开始和"写在羊皮纸上的官方证明"绑定。意思从"让你学到东西的事"变成了"能证明某事为真的纸"。

**15 世纪 · 进入英语**
经由古法语 document 进入中古英语，保留了"官方文书、证明材料"的意思。这时候它还是个比较窄的法律/行政用词。

**17-18 世纪 · 动词化 + -ation**
document 开始被当动词用——"to document" = 用文件证明、记录在案。然后 documentation 自然就长出来了：**做记录这件事本身**。

**20 世纪中叶 · 信息科学革命**
⚡ **第二次漂移**，也是最剧烈的一次。1930 年代，比利时信息学先驱 Paul Otlet 推动了 "documentation" 作为一个学科概念——系统化地收集、组织、检索信息。这个词从"给法庭交证据"跳到了"建立一整套知识管理体系"。

**20 世纪后半叶至今 · 软件时代**
程序员接管了这个词。"Read the documentation" 成了技术圈的口头禅（和甩锅工具）。此时 documentation 的含义已经是**"让别人能用你造的东西的那套说明"**——API docs、README、教程、注释。

### 文化地层

注意这条漂移线的方向：

```
教训/范例 → 法律证据 → 官方记录 → 系统化信息管理 → 技术说明文档
（精神的）   （法律的）  （行政的）    （学术的）        （工程的）
```

每一次跳跃都是同一个内核的不同投影：**把易逝的东西固定下来，让它能被后来者使用**。拉丁时代固定的是教训，中世纪固定的是法律事实，现代固定的是技术知识。容器在变，冲动不变。

---

## 3. 故事 / 画面

一栋老楼被拆了。新来的水管工打开地下室的墙，看到一堆管线像意大利面一样绞在一起。哪根是热水？哪根通向三楼？哪根是十五年前接的、早就废了但没人拆？

他翻遍了整栋楼，找到一本被水泡过的活页夹。第三页有一张手绘管线图，旁边用圆珠笔标着："蓝管=冷水主管，红管=热水回路，**绿管已废弃勿接**——1997.3 老张"。

老张在 1997 年花了五分钟画了这张图。他不知道 2024 年会有人打开这面墙。但这五分钟救了新水管工大半天的排查时间。

这就是 documentation：**不是写给现在的你，是写给未来那个不认识你、但要接手你的活的陌生人。** 老张画的那张图，是 documentation。老张画图这个行为，也是 documentation。两者用同一个词，因为它们是同一件事的两面——动作和产物。

（程序员版本更残酷：你就是那个水管工，而写代码没留注释的"老张"是六个月前的你自己。）

---

## 4. 多面体：核心义项展开

### 义项一：记录/归档的行为过程

> *The documentation of war crimes is essential for future tribunals.*
> 记录战争罪行对未来的审判至关重要。

这是最接近拉丁原始含义的用法——**把发生过的事固定成可追溯的记录**。和"一句话本质"的关系：你在给未来的审判者留路标。

### 义项二：证明性文件（集合概念）

> *You'll need to provide documentation of your residency — utility bills, bank statements, that sort of thing.*
> 你需要提供居住证明材料——水电账单、银行流水之类的。

不可数名词，指"一揽子证明文件"。注意它和 documents 的区别：documents 是一份一份数得清的纸，documentation 是模糊的一堆证据，强调的是**"足以证明"这个功能**，不是纸张的数量。

### 义项三：技术说明文档（软件/工程领域）

> *The library is powerful but the documentation is terrible — good luck figuring out the API.*
> 这个库很强大，但文档烂透了——祝你好运猜 API 怎么用。

当代最高频义项。程序员说"docs"就是这个意思。和本质的关系一脉相承：**让后来者能复现你做过的事**。没有 documentation 的代码库，就像那堵没有管线图的墙——技术债务的物质形态。

### 义项四：纪录片/纪实作品（较少见，偏学术）

> *documentary photography and documentation of indigenous cultures*
> 原住民文化的纪实摄影与文献记录

这个义项活在学术和艺术领域。本质相同：把正在消失的东西抓住，钉在可保存的介质上。

**底层统一性**：不管是战争罪行的记录、居住证明、API 文档还是文化纪实，documentation 干的事都是一样的——**在"知道"和"遗忘"之间插一根钉子**。

---

## 5. 裂缝标注

### 常见误用场景

**❌ 把 documentation 当可数名词用**
> ~~"I wrote three documentations."~~
> ✅ "I wrote three documents." 或 "I wrote documentation for three modules."

documentation 是不可数名词（mass noun）。你可以说 a piece of documentation，但不能说 *a documentation*。这和它指的是"过程+产物整体"有关——你不能数"记录"这个行为本身有几个。

**❌ documentation = instruction manual**
documentation 不等于"使用手册"。使用手册（manual）是 documentation 的一种，但 documentation 也包括内部注释、变更日志、架构决策记录（ADR）等不面向终端用户的内容。

### 易混近义词辨析

**documentation vs. documents**
- *Please submit the required documentation.* → 你需要提供的是"一整套能证明某事的材料"（功能导向）
- *Please submit the required documents.* → 你需要提交的是"具体的几份文件"（物件导向）
- 场景：签证官说 documentation，他在意的是"你能不能证明"；他说 documents，他在意的是"你的护照和银行流水交了没有"

**documentation vs. record(s)**
- record 偏"发生过的事实的留痕"——被动的、忠实的
- documentation 偏"有意识地组织起来让人能用的信息"——主动的、有结构的
- 监控摄像头拍到的是 record；把摄像头的时间线整理成案件报告是 documentation

**documentation vs. specification**
- specification 说的是"应该怎样"（prescriptive）
- documentation 说的是"实际是什么样 / 怎么用"（descriptive）
- 先写 spec，再造东西，再写 documentation。（当然现实中经常是造完了 spec 和 documentation 都没有。）

### 中文母语者陷阱

**"文档"≠ documentation**
中文里"文档"既可以指一份文件（a document），也可以指技术文档（documentation）。但英文里这两个词的语法行为完全不同——document 可数，documentation 不可数。中文母语者最常犯的错就是把 documentation 当 document 的花式写法。

**"写个文档"的翻译岔路**
- "帮我写个文档" → write a document（一份具体的文件）
- "这个项目需要文档" → This project needs documentation（一套说明体系）
- 判断标准：你说的"文档"是一个 **物件** 还是一种 **功能覆盖**？

---

## 6. 搭配与语域

### 高频搭配

| 搭配 | 语境 |
|------|------|
| **comprehensive documentation** | "全面的文档"——最常见的褒义搭配，意味着覆盖了该覆盖的 |
| **technical documentation** | 技术文档，工程/软件领域的标配说法 |
| **supporting documentation** | 辅助证明材料——法律、行政、申请场景高频 |
| **lack of documentation** | "缺乏文档"——程序员的墓志铭 |
| **official documentation** | 官方文档——可以指政府文件，也可以指框架的官方 docs |
| **proper documentation** | "像样的/合规的文档"——暗示当前状态不达标 |
| **documentation process** | 记录流程——强调系统性 |
| **internal documentation** | 内部文档——不对外公开的那部分 |

### 语域标注

documentation 天然住在**中高正式度**的语域里。日常口语中人们会说 papers（证件）、records（记录）、docs（技术文档的缩写）。

- 📄 **法律/行政**：非常正式。"Please provide documentation of…"
- 💻 **技术/软件**：日常用，但通常缩写成 docs。"RTFM" (Read The F***ing Manual) 中的 manual 经常就是 documentation
- 📰 **新闻/学术**：正式场合全称，如 "the documentation of human rights abuses"
- 🗣️ **口语**：不太自然。你不会对朋友说 "I need documentation"，你会说 "I need the papers/receipts/proof"

### 活用示范

> *"The best documentation is the code that doesn't need it."*
> ——程序员圈的老话。反讽在于：说这话的代码库往往最需要文档。

> *"History is written by the victors, but documentation is written by whoever was too paranoid to trust memory."*
> 这种"把 documentation 人格化"的用法，在科技写作和博客里很常见——把它从枯燥的行政概念拉进有态度的语境。

---

## 7. 跨语言映射

**中文"文档"**
前面说过了——中文"文档"是个模糊词，既是 document 又是 documentation。这导致中文母语者在英文里经常把两者混用。更精确的对应：
- document → 文件、公文、档案（具体的一份）
- documentation → 文档体系、说明文档、归档记录（一个系统/过程）

**日语「ドキュメンテーション」**
直接音译借词，主要在 IT 领域使用。日语里更本土的表达是「文書化」（bunsho-ka，文书化）——这个词结构上和 documentation 一模一样：名词 + 化（= -ation），意思也精确对应"把东西变成文书记录的过程"。

**德语 Dokumentation**
德语里这个词的覆盖面比英语更广——它同时也是"纪录片"的意思（英语一般用 documentary）。所以一个德语使用者说 Dokumentation 的时候，你得看上下文判断他是在说文档还是纪录片。

**拉丁语→法语→英语的一路传承**
法语 documentation 和英语几乎完全同义，是 19 世纪信息科学领域的共同遗产——Paul Otlet（比利时人，法语区）在推广"documentation"作为学科概念时，法英两种语言同步接受了这个术语扩展。这是少数真正由学术界驱动、而非民间自然漂移的语义变化。
