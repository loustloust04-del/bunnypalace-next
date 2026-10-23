import SwiftUI

/// 开盒转场的几何记录：文件夹 / 纸 / 图格在 `space` 坐标系里的 frame，和每层页面滚到的位置。
/// 普通 class、不被观察：滚动时每帧写，不触发任何刷新；只有飞行层和点开 / 返回的那一下来读。
@MainActor
final class FileLibraryFlightFrames {
    static let space = "fileLibraryFlight"

    private(set) var rects: [String: CGRect] = [:]
    /// 现在真的在屏上（onAppear 了、还没 onDisappear）的锚点
    private(set) var visible: Set<String> = []
    /// 页面 key（"" = 根）→ 内容滚到的 y
    var offsets: [String: CGFloat] = [:]

    /// 在屏上的格子的 frame；离屏 / 没建过的返回 nil
    func live(_ id: String) -> CGRect? {
        visible.contains(id) ? rects[id] : nil
    }

    /// 最后一次记下的 frame（可能已离屏，只拿来当返回转场的原点）
    func last(_ id: String) -> CGRect? {
        rects[id]
    }

    func report(_ id: String, _ rect: CGRect) {
        rects[id] = rect
    }

    func appear(_ id: String) {
        visible.insert(id)
    }

    func disappear(_ id: String) {
        visible.remove(id)
    }

    func reset() {
        rects = [:]
        visible = []
        offsets = [:]
    }
}

/// 文件库的一页（根 / 某个文件夹）：每页自己一个 ScrollView，换页时旧页带着自己的滚动位置退场。
/// 出现时滚到 `initialOffset`（回到上层 = 原来滚到的地方，进新的一层 = 0），滚动中把位置记进 `frames.offsets[key]`。
struct FileLibraryScrollPage<Content: View>: View {
    let key: String
    let frames: FileLibraryFlightFrames
    @ViewBuilder let content: Content

    @State private var position: ScrollPosition

    init(key: String, frames: FileLibraryFlightFrames, initialOffset: CGFloat, @ViewBuilder content: () -> Content) {
        self.key = key
        self.frames = frames
        self.content = content()
        _position = State(initialValue: ScrollPosition(y: initialOffset))
    }

    var body: some View {
        ScrollView { content }
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                frames.offsets[key] = y
            }
    }
}

extension View {
    /// 把这块的 frame 报给开盒转场；`frames` 为 nil 时什么都不挂
    @ViewBuilder
    func fileLibraryFlightAnchor(_ id: String, in frames: FileLibraryFlightFrames?) -> some View {
        if let frames {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .named(FileLibraryFlightFrames.space)) } action: { frames.report(id, $0) }
                .onAppear { frames.appear(id) }
                .onDisappear { frames.disappear(id) }
        } else {
            self
        }
    }
}

/// 一个锚点这次转场里是不是交给飞行层画着（真格子先藏起来）。每个锚点一个小对象：flight 变了只有被藏的那几个格子刷新
@Observable
@MainActor
final class FileLibraryFlightMark {
    var hidden = false
}

/// 开盒 / 返回转场的状态。Panel 的 body 不读这里被观察的属性：飞行层（`flight`）、被藏的格子（`mark`）、
/// 新页的入场和 iOS 顶栏（`intro` / `flight`）各自读，转场开始 / 交接时不用整页重算。
@Observable
@MainActor
final class FileLibraryFlightState {
    /// 开盒换上的这页：其余内容 / 返回键 / 标题先藏着，下一帧亮出来、按时间线错开淡入
    struct Intro {
        let page: String
        let flight: FileLibraryFolderFlight
        var hidden = true
        /// 亮出来那一刻在时间线上的 ms：各格子的淡入 delay 从这里算，算一次就固定
        var at: Double = 0

        func delay(until ms: Double) -> Double {
            max(0, (ms - at) / 1000)
        }

        /// 第几张纸落到这个锚点（不是目标 = nil）
        func landing(_ anchor: String) -> Int? {
            flight.papers.firstIndex { $0.target.anchor == anchor }
        }
    }

    /// 正在进行的开盒 / 返回转场（期间整页不吃点按）
    private(set) var flight: FileLibraryFolderFlight?
    /// 最近一次开盒换上的页；转场完了也留着（已经亮出来，不藏任何东西），下次开盒换掉
    private(set) var intro: Intro?
    /// 下一次换页的进出场方式：换页那一刻由 `FileLibraryPageTransition` 读，所以跟换页放在同一次更新里设就行
    @ObservationIgnored var pageMotion: FileLibraryPageMotion = .plain
    @ObservationIgnored private var marks: [String: FileLibraryFlightMark] = [:]
    /// 时间线 0 点。不是点下那一刻：点下后藏袋子 + 换页那一下卡多久都不算进动画里。
    /// 飞行层第一帧的 date 是在那次提交里拍的（新页还没排完版），所以第一帧画起点、第二帧到来时才定 0 点（= 第二帧往前推一帧），`settled` 之前时间线停在起点
    @ObservationIgnored private var origin: (id: UUID, date: Date, settled: Bool)?

    func mark(_ anchor: String) -> FileLibraryFlightMark {
        if let mark = marks[anchor] { return mark }
        let mark = FileLibraryFlightMark()
        marks[anchor] = mark
        return mark
    }

    func begin(_ next: FileLibraryFolderFlight) {
        flight = next
        for anchor in next.hidden { mark(anchor).hidden = true }
    }

    func introduce(_ page: String) {
        guard let flight else { return }
        intro = Intro(page: page, flight: flight)
    }

    /// 时间线走到哪了（ms）；0 点还没定时停在起点
    func elapsed(at date: Date = Date()) -> Double {
        guard let flight else { return 0 }
        guard let origin, origin.id == flight.id, origin.settled else { return flight.lead }
        return flight.lead + date.timeIntervalSince(origin.date) * 1000
    }

    /// 飞行层每帧调：第一帧记下，第二帧定 0 点（第二帧离第一帧最多走 1/120 秒）
    func tick(_ date: Date) -> Double {
        guard let flight else { return 0 }
        if let origin, origin.id == flight.id {
            if !origin.settled {
                self.origin = (flight.id, date.addingTimeInterval(-min(date.timeIntervalSince(origin.date), 1.0 / 120)), true)
            }
        } else {
            origin = (flight.id, date, false)
        }
        return elapsed(at: date)
    }

    func reveal() {
        guard let flight, intro?.flight.id == flight.id else { return }
        intro?.at = elapsed()
        intro?.hidden = false
    }

    func setMissing(_ missing: Set<Int>) {
        flight?.missing = missing
    }

    func end() {
        guard let flight else { return }
        for anchor in flight.hidden { marks[anchor]?.hidden = false }
        self.flight = nil
        pageMotion = .plain
    }

    func reset() {
        flight = nil
        intro = nil
        pageMotion = .plain
        for mark in marks.values { mark.hidden = false }
    }

    /// 某个入场角色现在该藏着吗、亮出来时怎么动
    func look(page: String, role: FileLibraryIntroStyle.Role) -> FileLibraryIntroStyle.Look {
        let out = FileLibraryFlightCurve.animation
        let intro = intro?.page == page ? intro : nil
        switch role {
        case .rest(let order):
            return rest(intro, order: order)
        case .cell(let anchor, let order):
            guard let intro, let k = intro.landing(anchor) else { return rest(intro, order: order) }
            guard intro.flight.papers[k].target.isSub else { return FileLibraryIntroStyle.Look() }
            return FileLibraryIntroStyle.Look(hidden: intro.hidden, offset: CGSize(width: 0, height: 10), animation: out(0.22).delay(intro.delay(until: intro.flight.launch(k))))
        case .caption(let anchor):
            guard let intro, let k = intro.landing(anchor) else { return FileLibraryIntroStyle.Look() }
            let at = intro.flight.launch(k) + FileLibraryFolderFlight.flyMs * 0.55
            return FileLibraryIntroStyle.Look(hidden: intro.hidden, animation: out(0.22).delay(intro.delay(until: at)))
        case .nav(let visible, let at, let duration, let from):
            let shown = visible && intro?.hidden != true
            let animation: Animation?
            switch flight?.direction {
            case nil: animation = .easeInOut(duration: 0.22)
            case .open: animation = shown ? out(duration).delay(intro?.delay(until: at) ?? 0) : nil
            case .close: animation = out(0.16)
            }
            return FileLibraryIntroStyle.Look(hidden: !shown, offset: from, animation: animation)
        }
    }

    private func rest(_ intro: Intro?, order: Int) -> FileLibraryIntroStyle.Look {
        guard let intro else { return FileLibraryIntroStyle.Look() }
        let at = intro.flight.restStart + FileLibraryFolderFlight.restStaggerMs * Double(min(order, 12))
        return FileLibraryIntroStyle.Look(hidden: intro.hidden, offset: CGSize(width: 0, height: 12), animation: FileLibraryFlightCurve.animation(0.3).delay(intro.delay(until: at)))
    }
}

/// 开盒转场里新页的内容：先藏着（透明 + 偏一点），亮出来时按自己在时间线上的时刻淡入归位
struct FileLibraryIntroStyle: ViewModifier {
    enum Role {
        /// 不参与飞行的内容：第 n 个，每个晚 30ms 淡入上浮 12pt（前 12 个之后同 12）
        case rest(Int)
        /// 网格格子：纸落进来的子文件夹跟那张纸一起淡入上浮 10pt；纸落上来的文件卡 / 图格不动（纸由飞行层画、落定交接）；其余同 rest
        case cell(String, order: Int)
        /// 纸落上来的那张文件卡的标题 / 时间：纸快落定再淡入
        case caption(String)
        /// iOS 顶栏的返回键 / 标题：只在文件夹页显示；开盒 = 旧的立刻藏、照时间线晚一点滑入（藏着时偏 `from`），返回 = 160ms 淡出，其它换页 = 交叉淡入
        case nav(visible: Bool, at: Double, duration: Double, from: CGSize)
    }

    struct Look {
        var hidden = false
        var offset: CGSize = .zero
        var animation: Animation? = nil
    }

    let state: FileLibraryFlightState?
    let page: String
    let role: Role

    func body(content: Content) -> some View {
        let look = state?.look(page: page, role: role) ?? Look()
        content
            .opacity(look.hidden ? 0 : 1)
            .offset(look.hidden ? look.offset : .zero)
            .animation(look.animation, value: look.hidden)
    }
}

/// 交给飞行层画着的格子先藏起来（只读这个格子自己的 mark）
struct FileLibraryFlightHide: ViewModifier {
    let mark: FileLibraryFlightMark?

    func body(content: Content) -> some View {
        content.opacity(mark?.hidden == true ? 0 : 1)
    }
}

enum FileLibraryPageMotion {
    case plain
    case open(UnitPoint)
    case close(UnitPoint)

    struct Step {
        var opacity: Double = 0
        var scale: CGFloat = 1
        var anchor: UnitPoint = .center
        /// nil = 跟着换页那次的动画走
        var animation: Animation? = nil
    }

    /// 开 = 旧页以被点的文件夹为原点缩 0.95 淡出、新页直接在（里面的东西自己错开淡入）；返回 = 反过来；其它 = 交叉淡入
    func step(inserting: Bool) -> Step {
        switch (self, inserting) {
        case (.plain, _):
            return Step()
        case (.open, true):
            return Step(opacity: 1)
        case (.open(let anchor), false):
            return Step(scale: 0.95, anchor: anchor, animation: FileLibraryFlightCurve.animation(0.28).delay(0.04))
        case (.close(let anchor), true):
            return Step(scale: 0.95, anchor: anchor, animation: FileLibraryFlightCurve.animation(0.28).delay(0.06))
        case (.close, false):
            return Step(animation: .easeOut(duration: 0.14))
        }
    }
}

/// 换页的进出场。方式在换页那一刻才从 `state.pageMotion` 读（`.transition` 的值本来要上一帧就挂到旧页上），设方式和换页才能放进同一次更新
struct FileLibraryPageTransition: Transition {
    let state: FileLibraryFlightState
    let inserting: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let step = state.pageMotion.step(inserting: inserting)
        let active = !phase.isIdentity
        return content
            .opacity(active ? step.opacity : 1)
            .scaleEffect(active ? step.scale : 1, anchor: step.anchor)
            .transaction(value: active) { transaction in
                if let animation = step.animation { transaction.animation = animation }
            }
    }
}

/// 转场期间整页不吃点按，飞行层盖在上面
struct FileLibraryFlightOverlay: ViewModifier {
    let state: FileLibraryFlightState
    let frames: FileLibraryFlightFrames

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(state.flight == nil)
            .overlay {
                if let flight = state.flight {
                    FileLibraryFolderFlightLayer(flight: flight, frames: frames, clock: state)
                }
            }
    }
}

/// 一次开盒 / 返回转场。时间线照小样 `design-file-library-folder-open.html`（毫秒，1×）。
struct FileLibraryFolderFlight {
    enum Direction {
        case open, close
    }

    /// 纸落到（返回时：从）哪儿：文件卡的纸 / 图格 / 子文件夹的袋子；值 = 锚点 id
    enum Target {
        case card(String)
        case cell(String)
        case sub(String)

        var anchor: String {
            switch self {
            case .card(let id), .cell(let id), .sub(let id): id
            }
        }

        var isSub: Bool {
            if case .sub = self { return true }
            return false
        }
    }

    struct Paper {
        /// 在文件夹卡里是第几张（扇形位置）
        let slot: Int
        let sheet: FileLibraryFolderSheet
        let face: FileLibraryPaper.Face
        let badge: String
        let target: Target
    }

    static let openingMs: Double = 180
    static let flyMs: Double = 520
    static let staggerMs: Double = 40
    static let restStaggerMs: Double = 30
    static let returnMs: Double = 300
    static let returnStaggerMs: Double = 25

    let id = UUID()
    let direction: Direction
    let folder: String
    let name: String
    let look: FileLibraryFolderLook
    let papers: [Paper]
    /// 时间线从几 ms 起（mac 指针在上面、已经张开 = 跳过按下 → 张开那段）
    let lead: Double
    /// 点下时按下了多少：iOS 按住 = 1；mac 指针在上面、已经张开 = 0
    let pressed: CGFloat
    /// 袋子的位置：开 = 点下那刻；返回 = 上次记下的（父页出来前先用它）
    let shell: CGRect
    /// 返回：每张纸起飞处在换页前拍的快照（下标 = papers 的下标）
    var sources: [Int: CGRect] = [:]
    /// 开：起飞时目标不在屏上的纸，原地淡掉
    var missing: Set<Int> = []

    /// 真格子里要藏起来的锚点（交给飞行层画的那些）
    var hidden: Set<String> {
        var ids: Set<String> = ["shell:\(folder)"]
        for (index, paper) in papers.enumerated() where !paper.target.isSub {
            if direction == .open || sources[index] != nil { ids.insert(paper.target.anchor) }
        }
        return ids
    }

    func launch(_ index: Int) -> Double {
        switch direction {
        case .open: Self.openingMs + Self.staggerMs * Double(index)
        case .close: Self.returnStaggerMs * Double(papers.count - 1 - index)
        }
    }

    /// 飞行层存在多久（之后交还给真格子、恢复点按）
    var duration: Double {
        switch direction {
        case .open: max(launch(max(papers.count - 1, 0)) + Self.flyMs, 440)
        case .close: max(Self.returnStaggerMs * Double(max(papers.count - 1, 0)) + Self.returnMs, 370)
        }
    }

    /// 文件夹页其余内容开始错开淡入的时刻
    var restStart: Double {
        launch(max(papers.count - 1, 0)) + Self.flyMs * 0.5
    }
}

/// 小样里的三条曲线 + 插值小工具
enum FileLibraryFlightCurve {
    static let spring = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
    static let out = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.22, y: 0.8), endControlPoint: UnitPoint(x: 0.3, y: 1))
    static let easeIn = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.4, y: 0), endControlPoint: UnitPoint(x: 1, y: 1))

    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(max((t - a) / (b - a), 0), 1)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ e: Double) -> CGFloat {
        a + (b - a) * CGFloat(e)
    }

    static func smooth(_ x: Double) -> Double {
        x * x * (3 - 2 * x)
    }

    /// 小样的 ease-out 曲线 (0.22, 0.8, 0.3, 1)
    static func animation(_ duration: Double) -> Animation {
        .timingCurve(0.22, 0.8, 0.3, 1, duration: duration)
    }
}

/// 飞行层：被点的袋子（后片 / 前片分层）+ 最多 3 张纸，每帧按时间线算位置，盖在整个文件库上面、不吃点按。
struct FileLibraryFolderFlightLayer: View {
    let flight: FileLibraryFolderFlight
    let frames: FileLibraryFlightFrames
    let clock: FileLibraryFlightState

    private typealias C = FileLibraryFlightCurve

    private struct Shell {
        var scale: CGFloat
        var dy: CGFloat
        var tilt: Double
        var opacity: Double
        var fan: Double
    }

    private struct Pose {
        var center: CGPoint
        var size: CGSize
        var angle: Double
        var radius: CGFloat
        var shadowY: CGFloat = 1
        var shadowBlur: CGFloat = 5
        var shadowAlpha: Double = 0.12
    }

    private struct PaperState {
        var pose: Pose
        var mix: Double
        var opacity: Double
        var z: Double
    }

    private static let u = FileLibraryFolderCard.u
    private static let height = FileLibraryFolderCard.height * u

    var body: some View {
        TimelineView(.animation) { context in
            scene(at: clock.tick(context.date))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var shellRect: CGRect {
        if flight.direction == .close, let live = frames.live("shell:\(flight.folder)") { return live }
        return flight.shell
    }

    private func scene(at t: Double) -> some View {
        let box = shellRect
        let shell = flight.direction == .open ? openShell(t) : closeShell(t)
        let center = CGPoint(x: box.midX, y: box.minY + Self.height / 2 + shell.dy)
        return ZStack {
            FileLibraryFolderCard.back(flight.look)
                .frame(width: box.width, height: Self.height)
                .scaleEffect(shell.scale)
                .opacity(shell.opacity)
                .position(center)
                .zIndex(1)
            ForEach(Array(flight.papers.enumerated()), id: \.element.sheet.id) { index, paper in
                let state = flight.direction == .open
                    ? openPaper(index, paper, t: t, box: box, shell: shell)
                    : closePaper(index, paper, t: t, box: box, shell: shell)
                paperView(index, paper, pose: state.pose, mix: state.mix)
                    .opacity(state.opacity)
                    .zIndex(state.z)
            }
            FileLibraryFolderCard.front(look: flight.look, name: flight.name, tilt: shell.tilt)
                .frame(width: box.width, height: Self.height, alignment: .bottom)
                .scaleEffect(shell.scale)
                .opacity(shell.opacity)
                .position(center)
                .zIndex(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 外壳（小样 shellOpen / shellClose，变体 A）

    private func openShell(_ t: Double) -> Shell {
        let q = flight.pressed
        let e1 = C.out.value(at: C.seg(t, 0, FileLibraryFolderFlight.openingMs))
        var shell = Shell(
            scale: C.lerp(1 - 0.03 * q, 1, e1),
            dy: C.lerp(0, -5, e1) * Self.u,
            tilt: Double(C.lerp(CGFloat(FileLibraryFolderCard.pressTilt) * q, CGFloat(FileLibraryFolderCard.openTilt), e1)),
            opacity: 1,
            fan: e1
        )
        let e = C.out.value(at: C.seg(t, 200, 440))
        shell.scale *= C.lerp(1, 0.9, e)
        shell.dy += C.lerp(0, 9, e) * Self.u
        shell.opacity = 1 - e
        return shell
    }

    private func closeShell(_ t: Double) -> Shell {
        let a = C.out.value(at: C.seg(t, 0, 200))
        var shell = Shell(scale: C.lerp(0.9, 1, a), dy: C.lerp(4, -5, a) * Self.u, tilt: FileLibraryFolderCard.openTilt, opacity: a, fan: 1)
        let c = C.out.value(at: C.seg(t, 220, 360))
        shell.tilt = Double(C.lerp(CGFloat(shell.tilt), 0, c))
        shell.dy = C.lerp(shell.dy, 0, c)
        return shell
    }

    /// 纸在袋子里的样子：`pressed` 合上 → 按下，`fanned` → 扇形；再套外壳的缩放 / 位移
    private func pocketPose(slot: Int, pressed: Double, fanned: Double, box: CGRect, shell: Shell) -> Pose {
        let u = Self.u
        let press = FileLibraryFolderCard.press[slot]
        let fan = FileLibraryFolderCard.fan[slot]
        func mix(_ rest: CGFloat, _ p: CGFloat, _ f: CGFloat) -> CGFloat {
            C.lerp(C.lerp(rest, p, pressed), f, fanned)
        }
        let x = mix(0, press.x, fan.x)
        let y = mix(0, press.y, fan.y)
        let angle = Double(mix(0, CGFloat(press.angle), CGFloat(fan.angle)))
        let scale = C.lerp(FileLibraryFolderCard.closedScale, 1, fanned) * shell.scale
        let size = FileLibraryFolderCard.paperSize
        let h = Self.height
        let cx = box.width / 2 + x * u * shell.scale
        let cy = h / 2 + (FileLibraryFolderCard.paperTop * u + size.height * u / 2 - h / 2 + y * u) * shell.scale + shell.dy
        return Pose(
            center: CGPoint(x: box.minX + cx, y: box.minY + cy),
            size: CGSize(width: size.width * u * scale, height: size.height * u * scale),
            angle: angle,
            radius: 9 * u * scale
        )
    }

    /// 文件卡 / 图格 / 子文件夹里那张纸的样子
    private func targetPose(_ target: FileLibraryFolderFlight.Target, rect: CGRect) -> Pose {
        let u = Self.u
        switch target {
        case .card:
            return Pose(center: CGPoint(x: rect.midX, y: rect.midY), size: rect.size, angle: 0, radius: 12)
        case .cell:
            return Pose(center: CGPoint(x: rect.midX, y: rect.midY), size: rect.size, angle: 0, radius: 0)
        case .sub:
            let size = FileLibraryFolderCard.paperSize
            let s = FileLibraryFolderCard.closedScale
            return Pose(
                center: CGPoint(x: rect.midX, y: rect.minY + FileLibraryFolderCard.paperTop * u + size.height * u / 2),
                size: CGSize(width: size.width * u * s, height: size.height * u * s),
                angle: 0,
                radius: 9 * u * s
            )
        }
    }

    private func lerpPose(_ a: Pose, _ b: Pose, _ e: Double) -> Pose {
        Pose(
            center: CGPoint(x: C.lerp(a.center.x, b.center.x, e), y: C.lerp(a.center.y, b.center.y, e)),
            size: CGSize(width: C.lerp(a.size.width, b.size.width, e), height: C.lerp(a.size.height, b.size.height, e)),
            angle: Double(C.lerp(CGFloat(a.angle), CGFloat(b.angle), e)),
            radius: C.lerp(a.radius, b.radius, e)
        )
    }

    /// 二次贝塞尔：a → 经 b → c
    private func quadPose(_ a: Pose, _ b: Pose, _ c: Pose, _ e: Double) -> Pose {
        let s = CGFloat(e)
        func q(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGFloat {
            (1 - s) * (1 - s) * x + 2 * (1 - s) * s * y + s * s * z
        }
        return Pose(
            center: CGPoint(x: q(a.center.x, b.center.x, c.center.x), y: q(a.center.y, b.center.y, c.center.y)),
            size: CGSize(width: q(a.size.width, b.size.width, c.size.width), height: q(a.size.height, b.size.height, c.size.height)),
            angle: Double(q(CGFloat(a.angle), CGFloat(b.angle), CGFloat(c.angle))),
            radius: q(a.radius, b.radius, c.radius)
        )
    }

    // MARK: - 纸（小样 renderOpen / renderClose）

    private func openPaper(_ index: Int, _ paper: FileLibraryFolderFlight.Paper, t: Double, box: CGRect, shell: Shell) -> PaperState {
        let k = Double(paper.slot)
        let s0 = flight.launch(index)
        let q = Double(flight.pressed)
        let missing = flight.missing.contains(index)
        guard t >= s0, !missing, let target = frames.live(paper.target.anchor) else {
            let pose = pocketPose(slot: paper.slot, pressed: q, fanned: shell.fan, box: box, shell: shell)
            let fade = missing ? 1 - C.out.value(at: C.seg(t, s0, s0 + 200)) : 1
            return PaperState(pose: pose, mix: 0, opacity: fade, z: 2 + k)
        }
        let from = pocketPose(slot: paper.slot, pressed: q, fanned: 1, box: box, shell: openShell(s0))
        let p = C.seg(t, s0, s0 + FileLibraryFolderFlight.flyMs)
        let e = C.spring.value(at: p)
        let arc = CGFloat(sin(Double.pi * e))
        var pose = lerpPose(from, targetPose(paper.target, rect: target), e)
        pose.center.y -= 14 * Self.u * arc
        pose.shadowY = C.lerp(1, 3, e) + 7 * arc
        pose.shadowBlur = C.lerp(5, 10, e) + 14 * arc
        pose.shadowAlpha = Double(C.lerp(0.12, 0.07, e) + 0.06 * arc)
        let sub = paper.target.isSub
        return PaperState(
            pose: pose,
            mix: sub ? 0 : C.smooth(C.seg(e, 0.12, 0.55)),
            opacity: sub ? 1 - C.seg(p, 0.5, 0.9) : 1,
            z: p > 0.03 ? 30 + k : 2 + k
        )
    }

    private func closePaper(_ index: Int, _ paper: FileLibraryFolderFlight.Paper, t: Double, box: CGRect, shell: Shell) -> PaperState {
        let k = Double(paper.slot)
        let rest = pocketPose(slot: paper.slot, pressed: 0, fanned: 0, box: box, shell: shell)
        guard let source = flight.sources[index] else {
            return PaperState(pose: rest, mix: 0, opacity: 0, z: 2 + k)
        }
        let s0 = flight.launch(index)
        let p = C.seg(t, s0, s0 + FileLibraryFolderFlight.returnMs)
        let e = C.easeIn.value(at: p)
        let fan = pocketPose(slot: paper.slot, pressed: 0, fanned: 1, box: box, shell: shell)
        var pose = quadPose(targetPose(paper.target, rect: source), fan, rest, e)
        let arc = CGFloat(sin(Double.pi * e))
        pose.shadowY = C.lerp(3, 1, e) + 5 * arc
        pose.shadowBlur = C.lerp(10, 5, e) + 10 * arc
        pose.shadowAlpha = 0.08 + 0.05 * Double(arc)
        let sub = paper.target.isSub
        let frontTop = box.minY + Self.height / 2
            + (Self.height / 2 - FileLibraryFolderCard.frontHeight * Self.u * CGFloat(cos(shell.tilt * .pi / 180))) * shell.scale + shell.dy
        let inPocket = e > 0.3 && pose.center.y + pose.size.height / 2 > frontTop + 6
        return PaperState(
            pose: pose,
            mix: sub ? 0 : 1 - C.smooth(C.seg(e, 0.1, 0.5)),
            opacity: sub ? C.seg(p, 0, 0.35) : 1,
            z: inPocket ? 2 + k : 30 + k
        )
    }

    // MARK: - 一张飞行纸：小纸脸 / 卡片脸叠着，按宽度等比缩放（不重排），盒子裁切

    private func paperView(_ index: Int, _ paper: FileLibraryFolderFlight.Paper, pose: Pose, mix: Double) -> some View {
        let w = pose.size.width
        let h = pose.size.height
        let sheetWidth = FileLibraryFolderCard.paperSize.width * Self.u
        let shadowScale = min(1, w / sheetWidth)
        return ZStack(alignment: .topLeading) {
            smallFace(paper.sheet, width: w, height: h, sheetWidth: sheetWidth)
                .opacity(1 - mix)
            if !paper.target.isSub {
                cardFace(paper, width: w, height: h, native: cardFaceSize(index, paper))
                    .opacity(mix)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .background(Theme.mainBg)
        .clipShape(RoundedRectangle(cornerRadius: pose.radius, style: .continuous))
        .shadow(
            color: FileLibraryFolderCard.shadowInk.opacity(pose.shadowAlpha),
            radius: pose.shadowBlur / 2 * shadowScale,
            y: pose.shadowY * shadowScale
        )
        .rotationEffect(.degrees(pose.angle))
        .position(pose.center)
    }

    @ViewBuilder
    private func smallFace(_ sheet: FileLibraryFolderSheet, width: CGFloat, height: CGFloat, sheetWidth: CGFloat) -> some View {
        switch sheet.face {
        case .text:
            FileLibraryFolderCard.sheetFace(sheet)
                .frame(width: sheetWidth, height: FileLibraryFolderCard.paperSize.height * Self.u)
                .scaleEffect(width / sheetWidth, anchor: .topLeading)
        case .image:
            FileLibraryFolderCard.sheetFace(sheet)
                .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func cardFace(_ paper: FileLibraryFolderFlight.Paper, width: CGFloat, height: CGFloat, native: CGSize) -> some View {
        if case .cell = paper.target, case .image(let url, let modifiedAt) = paper.face {
            Color.clear
                .overlay { FileThumbnailView(url: url, modifiedAt: modifiedAt) }
                .clipped()
                .frame(width: width, height: height)
        } else {
            FileLibraryPaper(face: paper.face, badge: paper.badge)
                .frame(width: native.width, height: native.height)
                .scaleEffect(width / max(native.width, 1), anchor: .topLeading)
        }
    }

    /// 卡片脸按目标纸的真实大小画（返回时按起飞处的大小）；图格是整格铺满，文件卡（含图片卡）画整张纸带角标
    private func cardFaceSize(_ index: Int, _ paper: FileLibraryFolderFlight.Paper) -> CGSize {
        if flight.direction == .close, let source = flight.sources[index] { return source.size }
        if let rect = frames.live(paper.target.anchor) { return rect.size }
        return CGSize(width: flight.shell.width, height: FileLibraryUI.size(178))
    }
}
