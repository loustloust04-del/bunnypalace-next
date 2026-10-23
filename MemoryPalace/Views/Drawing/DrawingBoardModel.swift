import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PencilKit

/// 画稿文件 `{assetId}.mpdraw`（贴纸目录里，不进 SwiftData）：有它 = 能「继续画」
struct DrawingDocument: Codable {
    var version = 1
    var canvasWidth: CGFloat
    var canvasHeight: CGFloat
    var paper: PaperKind
    var noiseSeed: UInt64
    var strokes: [PaintStroke]
    /// iOS 线稿层（PKDrawing.dataRepresentation）；mac 画的稿为 nil
    var pencilKit: Data?

    var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }

    func encoded() -> Data? {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return try? e.encode(self)
    }

    static func decode(_ data: Data) -> DrawingDocument? {
        try? PropertyListDecoder().decode(DrawingDocument.self, from: data)
    }
}

/// 画板里的一支笔：前三支自写颜料层，PencilKit 那几支只在 iOS
enum BoardTool: String, CaseIterable, Codable, Identifiable {
    case watercolor, pen, nib, pencil, marker, crayon, monoline, eraser, lasso
    var id: String { rawValue }

    var title: String {
        switch self {
        case .watercolor: "水彩"
        case .pen: "尖头钢笔"
        case .nib: "平头钢笔"
        case .pencil: "铅笔"
        case .marker: "马克笔"
        case .crayon: "蜡笔"
        case .monoline: "单线笔"
        case .eraser: "橡皮"
        case .lasso: "套索"
        }
    }

    var symbol: String {
        switch self {
        case .watercolor: "paintbrush.fill"
        case .pen: "pencil.tip"
        case .nib: "pencil.and.scribble"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .crayon: "pencil.tip.crop.circle"
        case .monoline: "scribble"
        case .eraser: "eraser.fill"
        case .lasso: "lasso"
        }
    }

    var paintTool: PaintTool? {
        switch self {
        case .watercolor: .watercolor
        case .pen: .pen
        case .nib: .nib
        case .eraser: .eraser
        default: nil
        }
    }

    /// 走 PencilKit 线稿层
    var isPencilKit: Bool { paintTool == nil }

    static var available: [BoardTool] {
        #if os(iOS)
        allCases
        #else
        [.watercolor, .pen, .nib, .eraser]
        #endif
    }

    /// 托盘里恒在、不进「选笔」设置的
    var isFixed: Bool { self == .eraser || self == .lasso }

    /// 三档粗细（托盘右下三颗点）
    static let sizes: [CGFloat] = [12, 22, 36]

    /// 竖线分组：0 自写颜料笔 / 1 PencilKit 笔 / 2 橡皮套索
    var group: Int {
        switch self {
        case .watercolor, .pen, .nib: 0
        case .pencil, .marker, .crayon, .monoline: 1
        case .eraser, .lasso: 2
        }
    }
}

/// 画布视图要实现的显示接口（iOS UIView / mac NSView）
@MainActor protocol PaintCanvasDisplay: AnyObject {
    func showPaint(_ image: CGImage?)
    func showLive(_ path: CGPath?, color: CGColor, fill: Bool, lineWidth: CGFloat)
    /// 水彩抬笔「晕开」：成品淡入、湿迹淡出，完了回调
    func reveal(_ stroke: RenderedStroke, completion: @escaping () -> Void)
}

/// 两层画布的状态：颜料层（自写笔刷，位图 + 每笔缓存）+ iOS 线稿层（PKCanvasView）
@MainActor @Observable
final class DrawingBoardModel {
    var tool: BoardTool = .watercolor {
        didSet {
            #if os(iOS)
            if tool == .eraser { eraseBase = pencilView?.drawing ?? lastDrawing }
            #endif
            syncPencilKitTool()
        }
    }
    var waterColor: String
    var inkColor: String
    var size: CGFloat = 22 { didSet { syncPencilKitTool() } }
    /// 尺子（PencilKit 自带，只有铅笔类贴着它走）
    var rulerOn = false {
        didSet {
            #if os(iOS)
            pencilView?.isRulerActive = rulerOn
            #endif
        }
    }
    var water: CGFloat = 0.6
    var angle: CGFloat = 35
    var paper: PaperKind { didSet { paperImage = BrushEngine.paperImage(paper, field: field) } }
    private(set) var paperImage: CGImage?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var isEmpty = true
    /// 重开画稿时逐笔重算中
    private(set) var isRestoring = false

    #if os(macOS)
    /// iPhone 画的线稿层：mac 没有 PencilKit 画布，只读显示，导出 / 保存原样带上（不能在 mac 上擦改）
    @ObservationIgnored private var keptPencil: PKDrawing?
    private(set) var keptPencilImage: CGImage?
    #endif

    let canvasSize: CGSize
    let noiseSeed: UInt64
    let settings: BrushSettings

    @ObservationIgnored let field: NoiseField
    @ObservationIgnored weak var display: PaintCanvasDisplay?
    @ObservationIgnored private var ops: [(stroke: PaintStroke, rendered: RenderedStroke?)] = []
    @ObservationIgnored private var redoOps: [(stroke: PaintStroke, rendered: RenderedStroke?)] = []
    @ObservationIgnored private var ctx: CGContext?
    @ObservationIgnored private var current: PaintStroke?
    @ObservationIgnored private var renderChain: Task<Void, Never>?
    @ObservationIgnored private var undoStack: [Entry] = []
    @ObservationIgnored private var redoStack: [Entry] = []

    private enum Entry {
        case paint
        #if os(iOS)
        case pencil(PKDrawing)
        /// 橡皮一笔两层一起擦：颜料层一个操作 + 线稿层擦之前的样子
        case erase(PKDrawing)
        #endif
    }

    #if os(iOS)
    @ObservationIgnored weak var pencilView: PKCanvasView?
    @ObservationIgnored var lastDrawing = PKDrawing()
    @ObservationIgnored private var applyingPencilUndo = false
    /// 橡皮一笔之前线稿层的样子：PencilKit 的位图橡皮落笔就开擦、改动回调和手势结束谁先谁后不定，
    /// 所以不在落笔时抓，而是平时一直跟着（非橡皮改动 / 切到橡皮 / 上一笔橡皮落定后）
    @ObservationIgnored private var eraseBase = PKDrawing()
    #endif

    init(canvasSize: CGSize, document: DrawingDocument? = nil, settings: BrushSettings = .load()) {
        let size = document?.canvasSize ?? canvasSize
        let seed = document?.noiseSeed ?? UInt64.random(in: 1...UInt64.max)
        let kind = document?.paper ?? settings.paper
        let f = NoiseField(canvas: size, seed: seed)
        self.settings = settings
        self.canvasSize = size
        noiseSeed = seed
        paper = kind
        field = f
        paperImage = BrushEngine.paperImage(kind, field: f)
        waterColor = settings.waterColors.first ?? "#3a6fb0"
        inkColor = settings.inkColors.first ?? "#22314a"
        tool = settings.tools.first ?? .watercolor
        let w = Int(size.width * BrushEngine.scale), h = Int(size.height * BrushEngine.scale)
        ctx = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: max(1, w) * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.translateBy(x: 0, y: CGFloat(h))
        ctx?.scaleBy(x: BrushEngine.scale, y: -BrushEngine.scale)
        if let pk = document?.pencilKit, let d = try? PKDrawing(data: pk), !d.strokes.isEmpty {
            #if os(iOS)
            lastDrawing = d
            #else
            keptPencil = d
            keptPencilImage = d.image(from: CGRect(origin: .zero, size: size), scale: BrushEngine.scale)
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            #endif
        }
        if let strokes = document?.strokes, !strokes.isEmpty { restore(strokes) }
        refreshFlags()
    }

    var activeColor: String {
        get { tool == .watercolor ? waterColor : inkColor }
        set { if tool == .watercolor { waterColor = newValue } else { inkColor = newValue } }
    }

    var palette: [String] { tool == .watercolor ? settings.waterColors : settings.inkColors }

    // MARK: 输入（颜料层）

    func begin(_ p: BrushPoint) {
        guard let t = tool.paintTool else { return }
        current = PaintStroke(tool: t, color: activeColor, size: t == .eraser ? size * 1.2 : size,
                              water: water, angle: angle, seed: UInt64.random(in: 1...UInt64.max), points: [p])
        updateLive()
    }

    func move(_ pts: [BrushPoint]) {
        guard current != nil else { return }
        if current?.tool == .eraser, let last = current?.points.last {
            erase(from: last, through: pts)
        }
        current?.points.append(contentsOf: pts)
        updateLive()
    }

    func end() {
        guard let s = current else { return }
        current = nil
        if s.tool == .eraser {
            display?.showLive(nil, color: BrushEngine.cgColor("#000000"), fill: false, lineWidth: 0)
            ops.append((s, nil))
            redoOps.removeAll()
            #if os(iOS)
            push(.erase(eraseBase))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.current == nil else { return }
                self.eraseBase = self.pencilView?.drawing ?? self.lastDrawing
            }
            #else
            push(.paint)
            #endif
            return
        }
        let field = field, canvas = canvasSize, paper = paper, previous = renderChain
        renderChain = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                BrushEngine.render(s, field: field, canvas: canvas, paper: paper)
            }.value
            await previous?.value
            guard let self else { return }
            guard let rendered else { self.display?.showLive(nil, color: BrushEngine.cgColor(s.color), fill: true, lineWidth: 0); return }
            if s.tool == .watercolor, let display = self.display {
                await withCheckedContinuation { cont in display.reveal(rendered) { cont.resume() } }
            }
            self.commit(s, rendered)
            if self.current == nil { self.display?.showLive(nil, color: BrushEngine.cgColor(s.color), fill: true, lineWidth: 0) }
        }
    }

    private func updateLive() {
        guard let s = current else { return }
        switch s.tool {
        case .watercolor:
            display?.showLive(BrushEngine.livePath(s), color: BrushEngine.cgColor(s.color, alpha: 0.32), fill: true, lineWidth: 0)
        case .pen, .nib:
            display?.showLive(BrushEngine.livePath(s), color: BrushEngine.cgColor(s.color, alpha: 0.95), fill: true, lineWidth: 0)
        case .eraser:
            display?.showLive(BrushEngine.livePath(s), color: BrushEngine.cgColor("#b8866b", alpha: 0.25), fill: false, lineWidth: s.size)
        }
    }

    private func erase(from last: BrushPoint, through pts: [BrushPoint]) {
        guard let ctx else { return }
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(size * 1.2)
        ctx.move(to: CGPoint(x: last.x, y: last.y))
        pts.forEach { ctx.addLine(to: CGPoint(x: $0.x, y: $0.y)) }
        ctx.strokePath()
        ctx.restoreGState()
        display?.showPaint(ctx.makeImage())
    }

    private func commit(_ s: PaintStroke, _ r: RenderedStroke) {
        ops.append((s, r))
        redoOps.removeAll()
        draw(s, r)
        display?.showPaint(ctx?.makeImage())
        push(.paint)
    }

    private func draw(_ s: PaintStroke, _ r: RenderedStroke?) {
        guard let ctx else { return }
        if s.tool == .eraser {
            guard let first = s.points.first else { return }
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(s.size)
            ctx.move(to: CGPoint(x: first.x, y: first.y))
            s.points.dropFirst().forEach { ctx.addLine(to: CGPoint(x: $0.x, y: $0.y)) }
            if s.points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            ctx.strokePath()
            ctx.restoreGState()
            return
        }
        guard let r else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        // 上下翻过的 ctx 里画图要局部再翻一次，不然图倒着
        ctx.translateBy(x: r.rect.minX, y: r.rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(r.image, in: CGRect(origin: .zero, size: r.rect.size))
        ctx.restoreGState()
    }

    private func recomposite() {
        guard let ctx else { return }
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(origin: .zero, size: canvasSize))
        ctx.restoreGState()
        for op in ops { draw(op.stroke, op.rendered) }
        display?.showPaint(ctx.makeImage())
    }

    private func restore(_ strokes: [PaintStroke]) {
        isRestoring = true
        let field = field, canvas = canvasSize, paper = paper
        renderChain = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                strokes.map { ($0, BrushEngine.render($0, field: field, canvas: canvas, paper: paper)) }
            }.value
            guard let self else { return }
            for (s, r) in rendered {
                self.ops.append((s, r))
                self.draw(s, r)
                self.undoStack.append(.paint)
            }
            self.display?.showPaint(self.ctx?.makeImage())
            self.isRestoring = false
            self.refreshFlags()
        }
    }

    /// 等在算 / 在晕开的笔画都落进颜料层
    func settle() async { await renderChain?.value }

    func attach(_ display: PaintCanvasDisplay) {
        self.display = display
        display.showPaint(ctx?.makeImage())
    }

    // MARK: 撤销 / 重做（两层共用一条）

    private func push(_ e: Entry) {
        undoStack.append(e)
        redoStack.removeAll()
        refreshFlags()
    }

    func undo() {
        guard let e = undoStack.popLast() else { return }
        switch e {
        case .paint:
            if let op = ops.popLast() { redoOps.append(op) }
            recomposite()
            redoStack.append(.paint)
        #if os(iOS)
        case .pencil(let before):
            redoStack.append(.pencil(pencilView?.drawing ?? lastDrawing))
            setPencil(before)
        case .erase(let before):
            if let op = ops.popLast() { redoOps.append(op) }
            recomposite()
            redoStack.append(.erase(pencilView?.drawing ?? lastDrawing))
            setPencil(before)
        #endif
        }
        refreshFlags()
    }

    func redo() {
        guard let e = redoStack.popLast() else { return }
        switch e {
        case .paint:
            if let op = redoOps.popLast() { ops.append(op); draw(op.stroke, op.rendered); display?.showPaint(ctx?.makeImage()) }
            undoStack.append(.paint)
        #if os(iOS)
        case .pencil(let after):
            undoStack.append(.pencil(pencilView?.drawing ?? lastDrawing))
            setPencil(after)
        case .erase(let after):
            if let op = redoOps.popLast() { ops.append(op); draw(op.stroke, op.rendered); display?.showPaint(ctx?.makeImage()) }
            undoStack.append(.erase(pencilView?.drawing ?? lastDrawing))
            setPencil(after)
        #endif
        }
        refreshFlags()
    }

    func clearAll() {
        ops.removeAll(); redoOps.removeAll(); undoStack.removeAll(); redoStack.removeAll()
        recomposite()
        #if os(iOS)
        setPencil(PKDrawing())
        #endif
        refreshFlags()
    }

    private func refreshFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        var empty = !ops.contains { $0.stroke.tool != .eraser }
        #if os(iOS)
        empty = empty && (pencilView?.drawing ?? lastDrawing).strokes.isEmpty
        #else
        empty = empty && keptPencil == nil
        #endif
        isEmpty = empty
    }

    // MARK: 线稿层（PencilKit）

    #if os(iOS)
    private func setPencil(_ d: PKDrawing) {
        applyingPencilUndo = true
        pencilView?.drawing = d
        lastDrawing = d
        eraseBase = d
        applyingPencilUndo = false
    }

    func pencilDidChange(_ d: PKDrawing) {
        defer { lastDrawing = d; refreshFlags() }
        guard !applyingPencilUndo, tool != .eraser, d != lastDrawing else { return }
        push(.pencil(lastDrawing))
        eraseBase = d
    }

    func syncPencilKitTool() {
        guard let v = pencilView else { return }
        let ink = UIColor(cgColor: BrushEngine.cgColor(inkColor))
        switch tool {
        case .pencil: v.tool = PKInkingTool(.pencil, color: ink, width: size * 0.5)
        case .marker: v.tool = PKInkingTool(.marker, color: ink, width: size)
        case .crayon: v.tool = PKInkingTool(.crayon, color: ink, width: size * 0.8)
        case .monoline: v.tool = PKInkingTool(.monoline, color: ink, width: max(1, size * 0.25))
        case .eraser: v.tool = PKEraserTool(.bitmap, width: size * 1.2)
        case .lasso: v.tool = PKLassoTool()
        default: break
        }
        // 自写笔刷时线稿层不接触摸，交给下面的颜料层
        v.isUserInteractionEnabled = tool.isPencilKit || tool == .eraser
    }
    #else
    func syncPencilKitTool() {}
    #endif

    // MARK: 导出

    /// 透明底、按内容裁边（留 8pt）的 PNG + 画稿
    func export() -> (png: Data, document: Data)? {
        var content = ops.compactMap { $0.stroke.tool == .eraser ? nil : $0.rendered?.rect }.reduce(CGRect.null) { $0.union($1) }
        var pkData: Data?
        #if os(iOS)
        let drawing = pencilView?.drawing ?? lastDrawing
        #else
        let drawing = keptPencil ?? PKDrawing()
        #endif
        if !drawing.strokes.isEmpty { content = content.union(drawing.bounds); pkData = drawing.dataRepresentation() }
        guard !content.isNull else { return nil }
        let r = content.insetBy(dx: -8, dy: -8).intersection(CGRect(origin: .zero, size: canvasSize)).integral
        let s = BrushEngine.scale, w = Int(r.width * s), h = Int(r.height * s)
        guard w > 0, h > 0, let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let paint = ctx?.makeImage() else { return nil }
        // CG 原点在左下：画布 pt 的 r 映到位图坐标
        out.draw(paint, in: CGRect(x: -r.minX * s, y: -(canvasSize.height - r.maxY) * s,
                                   width: canvasSize.width * s, height: canvasSize.height * s))
        if !drawing.strokes.isEmpty {
            #if os(iOS)
            let pk = drawing.image(from: r, scale: s).cgImage
            #else
            let pk = drawing.image(from: r, scale: s).cgImage(forProposedRect: nil, context: nil, hints: nil)
            #endif
            if let pk { out.draw(pk, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        guard let img = out.makeImage(), let png = Self.png(img) else { return nil }
        let doc = DrawingDocument(canvasWidth: canvasSize.width, canvasHeight: canvasSize.height, paper: paper, noiseSeed: noiseSeed,
                                  strokes: ops.map(\.stroke), pencilKit: pkData)
        guard let docData = doc.encoded() else { return nil }
        return (png, docData)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
