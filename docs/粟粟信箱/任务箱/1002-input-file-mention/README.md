# 1002 page1 输入框 @ 文件库文件 + 📎 改最近文件横条

来源：memorypalace-61（page2-apps-2）10-02 SendMessage 转述「粟粟 10-02 已拍板 go」——**不是粟粟在 Dex 窗口亲口说的**，接活 session 开工前跟粟粟确认一句 go。研究 + 小样是 61 在自己 scratchpad 里做的，Dex 原样拷进本目录留底（原路径 /private/tmp/…/45b40606-…/scratchpad/docs/）。原话照录：

> 新需求（粟粟 10-02 已拍板 go，请派一个 page1 工位的 session 做）：page1 日常聊天输入框「@ 补全文件库文件」+「📎 改成最近文件横条」。
>
> 研究 + 小样已做完（未入库，page2-apps-2 这边被工位隔离挡着写不进 page1，没绕）：
> - 研究：research-input-file-mention.md
> - 小样：design-input-file-mention.html
> 接手的 session 请先把这两个文件拷进自己工位的 docs/ 提交，再按三步流程写 plan → 实现（粟粟已 go，plan 不用等批注）。
>
> 粟粟裁定：
> 1. 输入「@+字」在输入框上方浮出文件库候选（最多 5 条，名字开头 > 名字含 > 文件夹名含，同档新的在前；只比名字不比正文）；选中后删掉「@字」，文件进附件条。**不做拼音首字母**。
> 2. **附件条里的文件保持现在的方块样子**，不要改成小样里那种「图标 + 名字 + 大小」的长条胶囊（她原话：之前我们都是方框，所以不要变长条了）。
> 3. 发给 AI 整份当附件发，走现有文件附件路径（AttachmentTextExtractor），发送链不改。
> 4. 📎 不再直接弹系统文件单：面板下方换成横滑「最近文件」（照 PhotoStripPanel 尺寸 / 勾选样式，FileLibraryTile.file(side: 80)，可多选），下面两个入口「文件库」（新做轻量选择 sheet：搜索 + 多选，不复用 page2 的 FileLibraryPanelView）/「手机里的文件」（原系统 fileImporter）；mac 第二入口叫「电脑上的文件」，拖放照旧；mac @ 候选支持 ↑↓ / 回车 / Tab / Esc。
> 注意：iOS 输入框回写去抖（ChatInputTextView.swift:525-535），要照 slashLive 加 @ 提交点；CardFlowView.swift 在 NOW 文件锁里，合前同步 master。完成后照规矩问粟粟合 + Air 验。page1-6 我已放掉，空着可用。—— page2-apps-2
