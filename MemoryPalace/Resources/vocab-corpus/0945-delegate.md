# delegate

## 1. 一句话本质

**delegate 是一种"把自己的一块权力拆下来，粘到另一个人身上，让他替你去干"的动作。** 不是甩锅，不是外包——是你的权力暂时长在了别人身上，他做的决定算你的。

---

## 2. 词源考古

### 词根词缀拆解

```
de-  +  leg(are)  +  -ate
↓         ↓           ↓
离开     派遣/委托     动词/名词后缀
```

**leg-** 这个根极其重要。它来自拉丁语 *legāre*（派遣、委任），而 *legāre* 和 *lēx*（法律）是亲戚——同一片语义土壤里长出来的两棵树。你会在一整个词族里反复碰到它：

- **legate**（教皇使节）——被"派出去的人"
- **legal**（合法的）——跟"法"有关
- **legislate**（立法）——*leg-*（法）+ *-lat-*（带来）= 把法律带到世上
- **legacy**（遗产）——*legāre* 的另一个意思是"遗赠"，你死后把东西"委派"给后人
- **allege**（声称）——*ad-* + *legāre*，原义是"派人去做证"，后来变成"声称"

所以 **leg-** 的底层逻辑是：**一种带有权威性和正式性的"交付"。** 不是随便递个东西，是有法律/权力背书的转移。

**de-** 在这里是"away from"（从……离开），给 *legāre* 加了一个方向感：把人/权力/任务**从自己身上剥离出去，交到别处。**

### 历史流变

| 时间 | 形态 | 含义 |
|------|------|------|
| 古典拉丁语 | *delegāre* | 派遣、委托、指派（法律/行政语境）|
| 中世纪拉丁语 | *delegātus*（过去分词，用作名词）| 被委派的人——教廷派驻地方的代理人 |
| 15世纪 英语 | delegate (n.) | 进入英语，最初指"被正式派去代表某方的人" |
| 17世纪 | delegate (v.) | 动词用法成熟——"将权力/任务委托给他人" |
| 18世纪 | 美国政治术语化 | 制宪会议的"delegates"、各州大会的"delegates"——成为美国政治体制的核心词 |
| 20世纪末 | 计算机科学 | delegate pattern（委托模式）——对象把自己处理不了/不想处理的事交给另一个对象 |

### 文化地层：一个关键分叉

在美国政治哲学里，**delegate** 和 **trustee** 是一对经典对立概念（来自爱德蒙·伯克 1774 年的布里斯托演说）：

- **Delegate model**：你是选民的传声筒，选民怎么想你就怎么投票，你没有自主判断权
- **Trustee model**：选民把信任托付给你，你用自己的判断力替他们做决定

这个区分至今仍在用。美国 D.C. 和各海外领地在国会有 **delegates**（没有投票权的代表），跟有投票权的 **representatives** 是不同的法律身份。

---

## 3. 故事 / 画面

想象一个古罗马总督，疆域太大，他不可能亲自跑遍每个行省。于是他做了一件事：

他把自己的印章摘下来，交给一个信使。"拿着这个。到了那边，你盖的章就是我盖的章。你说的话就是我说的话。你的'是'就是我的'是'。"

信使接过印章，骑马离开。他不是跑腿的——他身上**粘着总督的一部分**。他到了行省，判案、签约、调兵，每一个决定都回溯到那个摘下印章的瞬间。

这就是 delegate 的本质结构：**权力是可以物理转移的。你把它从自己身上拆下来，装到别人身上。那个人在行使权力的瞬间，他就是你。**

这也是为什么 delegate 天然带着一种**紧张感**——你放手了，但后果还是你的。你信不信得过那个接印章的人？

（顺便，这也是为什么 iOS 开发者对 delegate 这个词毫不陌生——UITableView 把"你要几行？每行长什么样？"这些问题**拆下来**，粘到你的 ViewController 上。它不管答案是什么，它只管问。回答的责任，是你的。）

---

## 4. 多面体：核心义项展开

### 义项 A：名词——被派去代表你的那个人

> *Each state sent two delegates to the convention.*
> 每个州派了两名代表参加大会。

跟"一句话本质"的关系：这个人身上粘着派他来的那一方的权力。他不是观光客，他是带着印章来的。

### 义项 B：动词——把权力/任务拆下来交出去

> *She delegated the hiring decisions to her deputy.*
> 她把招聘决策权委托给了副手。

这是最高频的用法。注意：delegate 不等于"分配任务"（assign）。assign 是"你去干这个"，delegate 是"你去**替我**干这个，**用我的权力**干"。差一个字：**替**。

### 义项 C：（计算机）委托对象/委托模式

> *Set the table view's delegate to handle row selection.*
> 把 table view 的 delegate 设成处理行选择的那个对象。

跟本质的关系完全一致：table view 说"我不管用户点了哪一行该发生什么——这件事我**委托**给你。你是我的 delegate，你来决定。"

### 义项 D：动词——（较少见）把债务/法律责任转嫁

> *The court delegated the case to a special magistrate.*
> 法院把案件移交给了特别法官。

这个用法更接近拉丁语原始的法律语境。"移交"不是甩手，是正式的权力再分配。

---

## 5. 裂缝标注

### 常见误用

❌ **把 delegate 当 assign 用**

> ~~I delegated him to clean the room.~~

delegate 的宾语是**任务或权力**，不是人。你 delegate **tasks/authority/responsibility** to someone。如果你想说"我指派他去打扫"，用 assign。

✅ *I delegated the cleaning to him.*

❌ **delegate = 推卸责任**

管理学里有个经典误区：以为 delegate 了就不关自己事了。英语里 delegate 隐含的契约是**你还是最终负责人**。印章是你的，盖歪了你兜底。

### 易混近义词

| 词 | 核心区别 |
|---|---|
| **assign** | 分配任务，不涉及权力转移。老板 assign 你写报告——你在执行他的指令，不是代替他做决策 |
| **designate** | 指定、命名。*She was designated as the spokesperson.* 重点是"被选中"，不是"被赋予权力" |
| **relegate** | 贬到次要位置。*re-*（回）+ *legāre*——"打发回去"。跟 delegate 共享词根，但方向完全相反：delegate 是"派出去赋权"，relegate 是"踢回去降级" |
| **representative** | 代表。比 delegate 宽泛，不一定涉及正式的权力委托。你可以 represent 一种观点，但你 delegate 的一定是具体的权力或任务 |

### 中文母语者陷阱

"代表"和 delegate 的覆盖范围不一样。中文说"我代表公司感谢你"——这里的"代表"是 represent，不是 delegate。Delegate 更窄、更正式、更强调**权力的物理转移**。

另一个陷阱：中文"委托"比较接近 delegate，但"委托"在中文里常用于法律语境（委托律师），而 delegate 在英语里的使用范围宽得多——日常管理、编程、政治都在用。

---

## 6. 搭配与语域

### 高频搭配

| 搭配 | 语境 |
|---|---|
| **delegate authority/power** | 最经典的搭配。"委托权力"。管理学、政治学的标配表达 |
| **delegate responsibility** | 委托职责。注意 responsibility 委托了，accountability（问责）没有——你还是要被问的那个人 |
| **delegate tasks** | 委派任务。日常职场最常见的用法 |
| **delegate to someone** | 介词用 to，不用 for/with |
| **learn to delegate** | "学会放手"——管理学鸡汤里的高频句式 |
| **delegate a representative** | 委派一名代表。正式外交/政治用语 |
| **effective delegation**（名词形式） | "有效的授权"。管理培训材料里的关键词 |
| **a delegate from [地名/组织]** | 来自某处的代表。政治/会议语境 |

### 语域

delegate 是个**跨语域能力很强的词**：

- **正式政治/外交**：UN delegates, constitutional delegates ✅
- **职场/管理**：delegate tasks, learn to delegate ✅
- **计算机科学**：delegate pattern, set the delegate ✅
- **日常口语**：偏少。日常生活中更常说 *hand off* 或 *pass it to someone*

它不算特别高雅，也不土——是一个"严肃场合的工作词"。

### 活用示范

> *"The art of delegation is not about getting rid of work—it's about getting rid of the wrong work."*
> "授权的艺术不是甩掉工作——是甩掉不该你干的工作。"

> *"He's terrible at delegating. He'll rewrite your code at 2 AM rather than trust you with it."*
> "他完全不会授权。他宁可凌晨两点重写你的代码，也不愿意信你能写好。"

第二个例句戳到了 delegate 的情感内核：**这个词的反面不是"自己干"，是"不信任"。**

---

## 7. 跨语言映射

**拉丁语 / 罗曼语族**：法语 *déléguer*，西班牙语 *delegar*，意大利语 *delegare*——形态几乎没变，因为本来就是拉丁词直传。

**日语**：「委任する」（いにんする）——跟 delegate 的权力转移含义最接近。「代表」更偏 represent。

**中文**：最近的对应是**"委"字族**——委托、委任、委派。"委"这个字本身就有"把东西交付出去"的意思（《说文》："委，随也"——顺势交付）。但中文的"委"缺少 delegate 里那种**"拆下自己的一块权力"**的画面感。英文 delegate 让你感觉权力是一块可以掰下来递过去的固体，中文的"委"更像水流——顺势流过去，不像是硬掰的。

**编程世界**的补充：Objective-C/Swift 的 delegate pattern 之所以不叫 "agent pattern" 或 "proxy pattern"（虽然都涉及代理），是因为 delegate 精准传达了那个语义——**被委托方不是替身（proxy），不是自主行动者（agent），而是"被拆出去的一块职责"。** 它没有自己的 agenda，它只回答被问到的问题。UITableViewDelegate 不会主动刷新表格——它只在被问到"第 3 行该显示什么"时才开口。这跟古罗马的信使一样：印章是总督的，你只在需要盖章时才掏出来。
