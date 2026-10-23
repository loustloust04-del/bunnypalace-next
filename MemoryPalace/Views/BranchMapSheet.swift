import SwiftUI
import SwiftData

/// 分支地图 v6 — Tidy Tree + 保拓扑展开 + 可点开折叠 + user/assistant 区分。
/// 详见 docs/plan-branch-map-v6-tidytree.md。
///
/// v6.1 修订（粟粟反馈 #1#2）：
/// 1. ↕N 标签可点 → toggle 该折叠段展开成 N 个独立 dot；再点缩回
/// 2. 每个 dot 代表一个 user/assistant 气泡（system/tool/empty 节点透传不画）；
///    旁边标 HH:mm 时间；user 圆点（实心）/ assistant 圆环（空心）做形状区分
struct BranchMapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var viewModel: ConversationViewModel

    let onNavigateToNode: (String) -> Void

    @State private var expandedChainHeads: Set<String> = []  // head id 在里面 → 整 chain 展开成 N 个独立 dot
    @State private var lastTappedNodeId: String? = nil       // 顶部 sticky 预览卡显示用
    /// 打开时那条主线：地图开着期间排版只认它。③b 起点选会把 viewModel 的主线换成点的那条，
    /// 不冻结的话被点的支线当场跳到中间（#016 粟粟 10-03「突变！」）；关了再开才换成新主线。
    /// 放引用盒子里：打开时写进去不触发重渲（首帧本来就按同一份主线排，写 @State 会让整页再算一遍，打开巨卡）
    @State private var frozenBox = FrozenBox()

    private final class FrozenBox {
        var spine: FrozenSpine?
    }

    private struct FrozenSpine {
        let rootId: String
        let mainPathIds: Set<String>
        let knownIds: Set<String>
    }

    /// 冻结主线 + 打开后接在它末端的新节点（地图开着时回复落地），换了对话就用当前主线
    private func layoutSpine(for snapshot: ConversationViewModel.BranchMapSnapshot) -> Set<String> {
        guard let frozen = frozenBox.spine, frozen.rootId == snapshot.rootId else { return snapshot.mainPathIds }
        var ids = frozen.mainPathIds
        let childrenMap = snapshot.childrenMap
        guard var tip = ids.first(where: { !(childrenMap[$0] ?? []).contains(where: ids.contains) }) else { return ids }
        while let next = childrenMap[tip]?.first(where: { !frozen.knownIds.contains($0) }), ids.insert(next).inserted {
            tip = next
        }
        return ids
    }

    private func freezeIfNeeded(_ snapshot: ConversationViewModel.BranchMapSnapshot) {
        guard frozenBox.spine?.rootId != snapshot.rootId else { return }
        frozenBox.spine = FrozenSpine(rootId: snapshot.rootId, mainPathIds: snapshot.mainPathIds, knownIds: Set(snapshot.nodeMap.keys))
    }
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("userName") private var floorUserName = "你"
    /// 卡库 ③-4：有效身份名，只换显示副本
    private var userName: String { viewModel.personaDisplayName(profile: profileManager?.currentProfile) ?? floorUserName }
    @AppStorage("assistantName") private var assistantName = "助手"

    /// 实时从 viewModel.currentPath 派生 — 切了 currentPath 后 @Observable 触发 body 重渲染，黄高亮自动跟随
    private var currentPathIds: Set<String> {
        Set(viewModel.currentPath.map { $0.id })
    }

    /// 顶部预览卡显示的节点 id：用户最后 tap 的 / 没 tap 则 fallback 到 currentPath 末端
    private var previewNodeId: String? {
        lastTappedNodeId ?? viewModel.currentPath.last?.id
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("分支地图")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
                #else
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
                #endif
        }
        .presentationDetents([.medium, .large])
        .macEscapeToDismiss { dismiss() }   // S1-5
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.branchMapSnapshot() {
            let spine = layoutSpine(for: snapshot)
            let pathIds = currentPathIds
            VStack(spacing: 0) {
                previewCardBar(snapshot: snapshot)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                GeometryReader { geo in
                    let layout = computeLayout(snapshot: snapshot, mainPathIds: spine, geometryWidth: geo.size.width)
                    ScrollView([.vertical]) {
                        ZStack(alignment: .topLeading) {
                            Canvas { ctx, _ in
                                drawConnections(ctx: ctx, layout: layout, mainPathIds: spine)
                            }
                            .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)

                            ForEach(layout.visibleNodes) { vn in
                                nodeView(vn, pathIds: pathIds, mainPathIds: spine)
                            }
                        }
                        .frame(
                            width: max(layout.canvasSize.width, geo.size.width),
                            height: max(layout.canvasSize.height + 40, geo.size.height),
                            alignment: .topLeading
                        )
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .onAppear { freezeIfNeeded(snapshot) }
            .onChange(of: snapshot.rootId) { freezeIfNeeded(snapshot) }
        } else {
            Text("没有对话数据")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 顶部 sticky 预览卡

    @ViewBuilder
    private func previewCardBar(snapshot: ConversationViewModel.BranchMapSnapshot) -> some View {
        let id = previewNodeId
        let node = id.flatMap { snapshot.nodeMap[$0] }

        VStack(alignment: .leading, spacing: 6) {
            if let n = node {
                HStack(spacing: 6) {
                    Text(n.role == "user" ? userName : assistantName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(n.role == "user" ? Theme.branchIndicator : Theme.textSecondary)
                    if let t = n.createTime {
                        Text(t.formatted(.dateTime.month().day().hour().minute()))
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                    Button {
                        viewModel.togglePin(n)
                    } label: {
                        Image(systemName: n.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 13))
                            .foregroundColor(n.isPinned ? Theme.favorite : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                let preview = String(EffectiveCharacterContext(charName: assistantName, userName: userName)
                    .expand(ContentCleaner.clean(n.content, cacheKey: n.id)).prefix(140))
                    .replacingOccurrences(of: "\n", with: " ")
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("点击下方节点 → 这里显示该气泡预览")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 76, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.mainBg)
        )
    }

    // MARK: - Node view

    @ViewBuilder
    private func nodeView(_ vn: VisibleNode, pathIds: Set<String>, mainPathIds: Set<String>) -> some View {
        let onPath = isOnVisualPath(vn, pathIds: pathIds)
        let onMain = isOnMainline(vn, mainPathIds: mainPathIds)
        let dotColor: Color = onPath ? Theme.branchIndicator : Color.gray.opacity(0.55)
        // v11: mainline dot 大一圈（11 vs 9 for displayable, 10 vs 8 for collapsed）
        let displayableSize: CGFloat = onMain ? 11 : 9
        let collapsedSize: CGFloat = onMain ? 10 : 8

        ZStack {
            // 36pt 透明 hit area
            Circle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 36, height: 36)

            // Dot：folded ↕ / pinned star / user 实心圆 / assistant 空心环
            if vn.isCollapsed {
                Circle()
                    .fill(dotColor)
                    .frame(width: collapsedSize, height: collapsedSize)
            } else if vn.isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: onMain ? 12 : 10))
                    .foregroundColor(dotColor)
            } else if vn.role == "user" {
                Circle()
                    .fill(dotColor)
                    .frame(width: displayableSize, height: displayableSize)
            } else {
                // assistant：空心环
                Circle()
                    .stroke(dotColor, lineWidth: onMain ? 2.2 : 1.8)
                    .frame(width: displayableSize, height: displayableSize)
            }

            // 时间戳：只给主线，短格式；右边挤就画到左边（日期看顶部预览卡）
            if let ts = vn.timestamp, !vn.isCollapsed, vn.showTime {
                Text(ts.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textMuted.opacity(0.75))
                    .fixedSize()
                    .offset(x: labelOffset(vn, 26), y: 10)
            }
        }
        .position(x: vn.x, y: vn.y)
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    // 单击 = 设顶部预览卡 + 快切 currentPath（同步 rebuildPath，不重 buildTree）
                    lastTappedNodeId = vn.lastNodeId
                    viewModel.navigateToNodeFast(nodeId: vn.lastNodeId)
                }
        )

        // 折叠段的 ↕N 标签：点 → 整 chain 全展开
        if vn.isCollapsed {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    _ = expandedChainHeads.insert(vn.id)
                }
            }) {
                // 两侧都挤（隔一条车道就有点）→ 缩成小号，塞进半个空隙不碰邻点；命中区仍 44×30
                let compact = vn.labelRoom < 72
                Text("↕\(vn.foldedCount)")
                    .font(.system(size: compact ? 10.5 : 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, compact ? 5 : 10)
                    .padding(.vertical, compact ? 3 : 6)
                    .background(Capsule().fill(Theme.mainBg.opacity(0.95)))
                    .overlay(Capsule().stroke(Color.gray.opacity(0.4), lineWidth: 0.6))
                    .frame(minWidth: 44, minHeight: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .position(x: vn.x + labelOffset(vn, 36), y: vn.y)
        }

        // chain head 展开后的 ⇕ 缩回标签：点 → 整 chain 全缩回
        if vn.isExpandedChainHead {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    _ = expandedChainHeads.remove(vn.id)
                }
            }) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.mainBg.opacity(0.95)))
                    .overlay(Capsule().stroke(Color.gray.opacity(0.4), lineWidth: 0.6))
                    .frame(minWidth: 38, minHeight: 30)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .position(x: vn.x + labelOffset(vn, 32), y: vn.y)
        }
    }

    /// 标签离点的距离：理想值，但不超过那一侧空隙的一半（不越过相邻车道的中线）
    private func labelOffset(_ vn: VisibleNode, _ ideal: CGFloat) -> CGFloat {
        let d = min(ideal, max(14, vn.labelRoom / 2))
        return vn.labelLeft ? -d : d
    }

    private func isOnVisualPath(_ vn: VisibleNode, pathIds: Set<String>) -> Bool {
        // v9: collapsed 段必须整段在 path 上才算 on path（避免视觉误导：
        // chain 头在 path 但尾不在时，整段黄色会让用户以为尾巴也在）
        return vn.collapsedNodeIds.allSatisfy { pathIds.contains($0) }
    }

    /// v11: 该节点是否在 conversation 永久 mainPath 上（用 snapshot.mainPathIds，跟 currentPath 解耦）
    private func isOnMainline(_ vn: VisibleNode, mainPathIds: Set<String>) -> Bool {
        return vn.collapsedNodeIds.allSatisfy { mainPathIds.contains($0) }
    }

    // MARK: - Connections

    private func drawConnections(ctx: GraphicsContext, layout: TreeLayout, mainPathIds: Set<String>) {
        let activeColor = Theme.branchIndicator          // currentPath 薄荷（配色规矩：不用黄）
        let mainlineColor = Color.gray.opacity(0.55)     // mainline 深灰
        let branchColor = Color.gray.opacity(0.28)       // branch 淡灰
        let pathIds = currentPathIds
        let byId = Dictionary(layout.visibleNodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for edge in layout.edges {
            var path = Path()
            path.move(to: CGPoint(x: edge.fromX, y: edge.fromY))
            let dy = edge.toY - edge.fromY
            let c1 = CGPoint(x: edge.fromX, y: edge.fromY + dy * 0.55)
            let c2 = CGPoint(x: edge.toX, y: edge.toY - dy * 0.55)
            path.addCurve(to: CGPoint(x: edge.toX, y: edge.toY), control1: c1, control2: c2)

            // v11: 三层视觉 — currentPath active 黄 2.5pt / mainline 深灰 2pt / branch 淡灰 1pt
            let isActive = isEdgeOnPath(edge: edge, pathIds: pathIds, byId: byId)
            let isMainline = isEdgeOnPath(edge: edge, pathIds: mainPathIds, byId: byId)
            let strokeColor: Color
            let strokeWidth: CGFloat
            if isActive {
                strokeColor = activeColor
                strokeWidth = 2.5
            } else if isMainline {
                strokeColor = mainlineColor
                strokeWidth = 2.0
            } else {
                strokeColor = branchColor
                strokeWidth = 1.0
            }
            ctx.stroke(path, with: .color(strokeColor),
                       style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        }
    }

    /// v9: edge 两端各自的"整段在 pathIds" 才算 on path（用 allSatisfy）
    /// v11: 复用此函数判断 mainline edge（传 mainPathIds 即可）
    private func isEdgeOnPath(edge: TreeEdge, pathIds: Set<String>, byId: [String: VisibleNode]) -> Bool {
        guard let from = byId[edge.fromNodeId], let to = byId[edge.toNodeId] else {
            return pathIds.contains(edge.fromNodeId) && pathIds.contains(edge.toNodeId)
        }
        let fromOn = from.collapsedNodeIds.allSatisfy { pathIds.contains($0) }
        let toOn = to.collapsedNodeIds.allSatisfy { pathIds.contains($0) }
        return fromOn && toOn
    }

}

// MARK: - TidyNode + Layout

private final class TidyNode {
    let id: String                  // collapsed → chain head id；普通 → 节点自己 id
    let lastNodeId: String          // collapsed → chain 末尾 id；普通 = id
    let originalNode: MessageNode?
    let isCollapsed: Bool
    let foldedCount: Int
    let isPinned: Bool
    let role: String                // "user" / "assistant" / "" (collapsed/unknown)
    let timestamp: Date?
    let collapsedNodeIds: [String]
    let isExpandedChainHead: Bool   // 我是某 expanded chain 的第一个节点（要画 ⇕ 缩回 icon）
    var children: [TidyNode] = []

    var x: Double = 0
    var y: Double = 0
    var subtreeWidth: Double = 0  // v8 banded layout：measure 阶段算出来

    init(id: String, lastNodeId: String, originalNode: MessageNode?, isCollapsed: Bool, foldedCount: Int, isPinned: Bool, role: String, timestamp: Date?, collapsedNodeIds: [String], isExpandedChainHead: Bool = false) {
        self.id = id
        self.lastNodeId = lastNodeId
        self.originalNode = originalNode
        self.isCollapsed = isCollapsed
        self.foldedCount = foldedCount
        self.isPinned = isPinned
        self.role = role
        self.timestamp = timestamp
        self.collapsedNodeIds = collapsedNodeIds
        self.isExpandedChainHead = isExpandedChainHead
    }
}

private struct VisibleNode: Identifiable {
    let id: String
    let lastNodeId: String
    let x: CGFloat
    let y: CGFloat
    let isCollapsed: Bool
    let foldedCount: Int
    let isPinned: Bool
    let role: String
    let timestamp: Date?
    let collapsedNodeIds: [String]
    let previewNode: MessageNode?
    let isExpandedChainHead: Bool
    /// 时间戳、↕N、⇕ 放哪边：这一行左右两侧离最近的点 / 画布边谁更空放谁那边
    var labelLeft = false
    /// 那一侧的空隙（pt）；标签往外挪不超过它的一半，挤不下就贴着点
    var labelRoom: CGFloat = 90
    /// 时间戳只给主线上的点（分支点点开看顶部卡片），免得满屏小字叠在一起
    var showTime = false
}

private struct TreeEdge {
    let fromNodeId: String
    let toNodeId: String
    let fromX: CGFloat
    let fromY: CGFloat
    let toX: CGFloat
    let toY: CGFloat
}

private struct TreeLayout {
    let visibleNodes: [VisibleNode]
    let edges: [TreeEdge]
    let canvasSize: CGSize
}

// MARK: - 树构造 + 折叠 + 排版

extension BranchMapSheet {
    fileprivate func computeLayout(snapshot: ConversationViewModel.BranchMapSnapshot, mainPathIds: Set<String>, geometryWidth: CGFloat) -> TreeLayout {
        let nodeMap = snapshot.nodeMap
        let childrenMap = snapshot.childrenMap
        // v9: 折叠跟 currentPath 解耦 — 不再用 snapshot.currentPathIds 决定折叠。
        // currentPath 只控高亮颜色（isOnVisualPath / isEdgeOnPath 实时读 viewModel.currentPath）。

        // 一次排版里 isFoldable / isBranchHead 会对同一个点反复问，每问一次都读 SwiftData 属性（Air 上一遍 body 1.5s+），按 id 记住
        var displayableMemo: [String: Bool] = [:]
        var visibleChildrenMemo: [String: [String]] = [:]

        func isDisplayable(_ id: String) -> Bool {
            if let hit = displayableMemo[id] { return hit }
            guard let n = nodeMap[id] else { return false }
            let result = (n.role == "user" || n.role == "assistant") && !n.content.isEmpty && !n.isTrashed
            displayableMemo[id] = result
            return result
        }

        /// 跳过 system/tool/empty 节点，返回该 id 下"最近 displayable 后代"列表
        func visibleChildren(_ id: String) -> [String] {
            if let hit = visibleChildrenMemo[id] { return hit }
            var out: [String] = []
            func walk(_ id: String) {
                for k in (childrenMap[id] ?? []) {
                    if isDisplayable(k) { out.append(k) } else { walk(k) }
                }
            }
            walk(id)
            visibleChildrenMemo[id] = out
            return out
        }

        /// 找 displayable 节点的"最近 displayable parent"
        func displayableParent(_ id: String) -> String? {
            var current = nodeMap[id]?.parentId
            while let pid = current {
                if isDisplayable(pid) { return pid }
                current = nodeMap[pid]?.parentId
            }
            return nil
        }

        /// 在 displayable 视角下：该 id 是不是其 displayable parent 的 visibleChildren.first
        func isBranchHead(_ id: String) -> Bool {
            guard let pid = displayableParent(id) else { return false }
            return visibleChildren(pid).first != id
        }

        func isFoldable(_ id: String) -> Bool {
            // v9: 任意 single-child + 非 pinned + 非 branchHead chain 都可折叠
            // （之前限定 currentPath 导致切分支时整树重折叠 → 节点乱跳）
            guard let n = nodeMap[id] else { return false }
            let vKids = visibleChildren(id)
            if vKids.count != 1 { return false }
            if n.isPinned { return false }
            if isBranchHead(id) { return false }
            return true
        }

        // 找顶层 displayable 起点
        let topDisplayables: [String] = {
            if isDisplayable(snapshot.rootId) { return [snapshot.rootId] }
            return visibleChildren(snapshot.rootId)
        }()

        guard let firstId = topDisplayables.first else {
            return TreeLayout(visibleNodes: [], edges: [], canvasSize: .zero)
        }

        // 算 forceUnfolded：每个 expandedChainHeads 里的 head 沿 chain 走到底，所有节点都加入
        // 这样 build 时整 chain 都不会再被折叠
        var forceUnfolded: Set<String> = []
        for headId in expandedChainHeads {
            guard isFoldable(headId) else { continue }
            var chain: [String] = [headId]
            var lastKids = visibleChildren(headId)
            while lastKids.count == 1, isFoldable(lastKids[0]) {
                let nextId = lastKids[0]
                chain.append(nextId)
                lastKids = visibleChildren(nextId)
            }
            for cid in chain { forceUnfolded.insert(cid) }
        }

        // build 递归
        func build(_ id: String) -> TidyNode? {
            guard let node = nodeMap[id] else { return nil }

            // 折叠链：自己 foldable 且不在 forceUnfolded 里
            if isFoldable(id), !forceUnfolded.contains(id) {
                var chain: [String] = [id]
                var lastId = id
                var lastKids = visibleChildren(id)
                while lastKids.count == 1, isFoldable(lastKids[0]), !forceUnfolded.contains(lastKids[0]) {
                    let nextId = lastKids[0]
                    chain.append(nextId)
                    lastId = nextId
                    lastKids = visibleChildren(nextId)
                }
                // v9.1: chain 至少 2 个节点才 collapse；孤立 foldable 节点（chain=1）当普通 dot 画
                if chain.count >= 2 {
                    let lastNode = nodeMap[lastId]
                    let collapsed = TidyNode(
                        id: chain.first!,
                        lastNodeId: lastId,
                        originalNode: lastNode,
                        isCollapsed: true,
                        foldedCount: chain.count,
                        isPinned: false,
                        role: "",
                        timestamp: lastNode?.createTime,
                        collapsedNodeIds: chain
                    )
                    for ck in lastKids {
                        if let child = build(ck) {
                            collapsed.children.append(child)
                        }
                    }
                    return collapsed
                }
                // chain.count == 1: fall through 到普通节点构造
            }

            // 普通节点（force unfolded chain 的 head 节点标记 isExpandedChainHead 以画 ⇕ 缩回 icon）
            let tn = TidyNode(
                id: id,
                lastNodeId: id,
                originalNode: node,
                isCollapsed: false,
                foldedCount: 0,
                isPinned: node.isPinned,
                role: node.role,
                timestamp: node.createTime,
                collapsedNodeIds: [id],
                isExpandedChainHead: expandedChainHeads.contains(id)
            )
            for k in visibleChildren(id) {
                if let child = build(k) {
                    tn.children.append(child)
                }
            }
            return tn
        }

        guard let tree = build(firstId) else {
            return TreeLayout(visibleNodes: [], edges: [], canvasSize: .zero)
        }

        // v10 git graph lane assignment：mainPath child 同父 lane，off-path 各 alloc lane（左右交替）
        let leftPad: Double = 24
        let rightPad: Double = 24
        let availableW = max(120, Double(geometryWidth) - leftPad - rightPad)
        // 先按 lane 编号排（x = lane），再按两侧最宽的那边把间距压到屏宽内：主线仍居中，
        // 分支再多也不出屏（v10 起丢了 v8 的屏宽约束，节点被边缘裁掉）
        layoutGitGraph(
            root: tree,
            mainPathIds: mainPathIds,
            centerX: 0,
            laneSpacing: 1,
            vSpacing: 60
        )
        var maxAbsLane: Double = 0
        forEachNode(tree) { maxAbsLane = max(maxAbsLane, abs($0.x)) }
        let laneSpacing = maxAbsLane > 0 ? min(44, (availableW / 2 - 8) / maxAbsLane) : 44
        forEachNode(tree) { $0.x = availableW / 2 + $0.x * laneSpacing }

        let topPad: Double = 24
        var nodes: [VisibleNode] = []
        var edges: [TreeEdge] = []
        var maxX: Double = 0
        var maxY: Double = 0
        collectVisible(tree, leftPad: leftPad, topPad: topPad, nodes: &nodes, edges: &edges, maxX: &maxX, maxY: &maxY)

        let canvasW = max(maxX + leftPad, Double(geometryWidth))
        let canvasH = maxY + topPad + 24
        nodes = placeLabels(nodes, canvasWidth: canvasW, mainPathIds: mainPathIds)
        return TreeLayout(visibleNodes: nodes, edges: edges, canvasSize: CGSize(width: canvasW, height: canvasH))
    }

    fileprivate func forEachNode(_ n: TidyNode, _ body: (TidyNode) -> Void) {
        body(n)
        for c in n.children { forEachNode(c, body) }
    }

    /// 标签放哪边：同一行（同 y）左右两侧离最近的点 / 画布边，谁更空放谁那边（默认右边，够 90pt 就不动）
    fileprivate func placeLabels(_ nodes: [VisibleNode], canvasWidth: Double, mainPathIds: Set<String>) -> [VisibleNode] {
        let rows = Dictionary(grouping: nodes, by: { Int($0.y.rounded()) })
        return nodes.map { vn in
            var out = vn
            let sameRow = rows[Int(vn.y.rounded())] ?? []
            let rightGap = sameRow.filter { $0.id != vn.id && $0.x > vn.x }.map { $0.x - vn.x }.min()
                ?? CGFloat(canvasWidth) - vn.x
            let leftGap = sameRow.filter { $0.id != vn.id && $0.x < vn.x }.map { vn.x - $0.x }.min() ?? vn.x
            out.labelLeft = rightGap < 90 && leftGap > rightGap
            out.labelRoom = out.labelLeft ? leftGap : rightGap
            out.showTime = vn.collapsedNodeIds.allSatisfy { mainPathIds.contains($0) }
            return out
        }
    }

    /// v12：车道按行占用（粟粟 09-28 真实数据：186 个岔口的对话，车道沿主线一路往外排到出屏）。
    /// v11 的回收要等岔口所有孩子排完，而主线那个孩子包含后面整段对话 → 每条分支的车道一直占到对话结束、永不回收。
    /// 现在每条车道记「占到第几行」：分支只在自己那几行占着，过了就让给下面的岔口；同岔口的兄弟行区间重叠，
    /// 自然分到不同车道。侧别照 v11：子分支跟父同侧、不跨主线；主线上的岔口哪边近放哪边，一样近就左右交替。
    fileprivate func layoutGitGraph(
        root: TidyNode,
        mainPathIds: Set<String>,
        centerX: Double,
        laneSpacing: Double,
        vSpacing: Double
    ) {
        enum Side { case left, right }
        var busyUntil: [Int: Int] = [:]   // lane → 占用到的最后一行（含）；lane 0 = 主线，不参与分配
        var heights: [ObjectIdentifier: Int] = [:]
        var nextTieSide: Side = .left

        func height(_ n: TidyNode) -> Int {
            if let h = heights[ObjectIdentifier(n)] { return h }
            let h = 1 + (n.children.map(height).max() ?? 0)
            heights[ObjectIdentifier(n)] = h
            return h
        }

        /// 这一侧第一条在 from 行之前已空出来的车道（1 起）
        func firstFree(_ side: Side, from: Int) -> Int {
            var k = 1
            while (busyUntil[side == .left ? -k : k] ?? -1) >= from { k += 1 }
            return k
        }

        func alloc(preferred: Side?, from: Int, to: Int) -> Int {
            let side: Side
            if let preferred {
                side = preferred
            } else {
                let l = firstFree(.left, from: from), r = firstFree(.right, from: from)
                if l == r { side = nextTieSide; nextTieSide = nextTieSide == .left ? .right : .left }
                else { side = l < r ? .left : .right }
            }
            let k = firstFree(side, from: from)
            let lane = side == .left ? -k : k
            busyUntil[lane] = to
            return lane
        }

        func isOnMainPath(_ n: TidyNode) -> Bool { mainPathIds.contains(n.id) }

        func dfs(_ n: TidyNode, lane: Int, depth: Int) {
            n.x = centerX + Double(lane) * laneSpacing
            n.y = Double(depth) * vSpacing
            // lineChild：主线上沿主线走；分支里沿 children[0] 连续
            let lineChild = isOnMainPath(n) ? n.children.first(where: isOnMainPath) : n.children.first
            let preferred: Side? = lane < 0 ? .left : (lane > 0 ? .right : nil)
            for c in n.children {
                let cLane = c === lineChild
                    ? lane
                    : alloc(preferred: preferred, from: depth + 1, to: depth + height(c))
                dfs(c, lane: cLane, depth: depth + 1)
            }
        }

        dfs(root, lane: 0, depth: 0)
    }


    fileprivate func collectVisible(_ node: TidyNode, leftPad: Double, topPad: Double, nodes: inout [VisibleNode], edges: inout [TreeEdge], maxX: inout Double, maxY: inout Double) {
        let absX = node.x + leftPad
        let absY = node.y + topPad
        nodes.append(VisibleNode(
            id: node.id,
            lastNodeId: node.lastNodeId,
            x: CGFloat(absX),
            y: CGFloat(absY),
            isCollapsed: node.isCollapsed,
            foldedCount: node.foldedCount,
            isPinned: node.isPinned,
            role: node.role,
            timestamp: node.timestamp,
            collapsedNodeIds: node.collapsedNodeIds,
            previewNode: node.originalNode,
            isExpandedChainHead: node.isExpandedChainHead
        ))
        if absX > maxX { maxX = absX }
        if absY > maxY { maxY = absY }
        for child in node.children {
            let childAbsX = child.x + leftPad
            let childAbsY = child.y + topPad
            edges.append(TreeEdge(
                fromNodeId: node.id,
                toNodeId: child.id,
                fromX: CGFloat(absX),
                fromY: CGFloat(absY),
                toX: CGFloat(childAbsX),
                toY: CGFloat(childAbsY)
            ))
            collectVisible(child, leftPad: leftPad, topPad: topPad, nodes: &nodes, edges: &edges, maxX: &maxX, maxY: &maxY)
        }
    }
}
