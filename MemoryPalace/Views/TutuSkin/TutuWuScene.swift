#if PERSONAL_APPS
#if os(iOS)
import Foundation
import QuartzCore
import CoreGraphics
import Metal
#if os(iOS)
import UIKit
#endif

/// An event-driven frozen paper theatre. No timer and no idle GPU work: the host runs a
/// CADisplayLink only while scrolling, coasting or bouncing, and pauses it at rest.
/// The host coalesces scrolling requests; preparation and drawable submission run off-main.
final class TutuWuScene {
    let viewportLayer = CAMetalLayer()
    let stripLayer = CALayer()
    let overlayLayer = CAMetalLayer()
    let pieces: [TutuWuPiece]
    var onError: ((Error) -> Void)?
    var onDiagnostics: ((TutuWuDiagnostics) -> Void)?
    var onFrameCompleted: ((Double, UInt64) -> Void)? {
        didSet { if let renderer = activeRenderer { configureCompletionObserver(renderer) } }
    }
    var onFramePresented: ((Double, UInt64) -> Void)? {
        didSet { if let renderer = activeRenderer { configurePresentationObserver(renderer) } }
    }
    var captureNextFrame: ((MTLTexture, MTLTexture, MTLCommandBuffer) -> Void)?
    private(set) var diagnostics = TutuWuDiagnostics()
    var isReady: Bool { diagnostics.ready }
    var completedFrameCount: Int { diagnostics.completed }
    private let directory: URL
    private let manifest: TutuWuManifest
    private let suppliedLibrary: MTLLibrary?
    private let displayScale: CGFloat
    private let worker = DispatchQueue(label: "TutuWu.prepare-submit", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let submissionLock = NSLock()
    private var pendingSubmission: (() -> Void)?
    private var submissionScheduled = false
    private var requestedEpoch: UInt64 = 0
    private var acceptedEpoch: UInt64 = 0
    private var acceptedOffset: CGFloat?
    private var queuedEpoch: UInt64 = 0
    private var queuedOffset: CGFloat?
    private var pendingCapture: ((MTLTexture, MTLTexture, MTLCommandBuffer) -> Void)?
    // Accessed only on worker. A released generation never hands its resources back to main.
    private var workerRenderer: TutuWuRenderer?
    private var workerAssets: TutuWuAssets?
    private var workerViewport: CGSize?
    private var workerLighting: TutuWuRenderer.Lighting?
    private var workerCache: (wallpaper: String, cache: TutuWuRenderer.Cache)?
    private var workerRequest: (viewport: CGSize, wallpaper: String, generation: UInt64)?
    private var workerPreparing = false
    private var activeRenderer: TutuWuRenderer?
    private var cache: TutuWuRenderer.Cache?
    private let shade = CALayer(), table = CALayer()
    private var pieceLayers: [CALayer] = []
    private let tableRaster: CGRect
    private let pieceRasters: [CGRect]
    private var previousViewport: CGSize?
    private var previousOffset: CGFloat?
    private var previousWallpaper: String?
    private var generation: UInt64 = 0
    private(set) var renderCount = 0
    private var memoryWarningObserver: NSObjectProtocol?
    var metalFrameCount: Int { diagnostics.submitted }
    var loadedImageCount: Int { cache?.images.count ?? 0 }
    var loadedImageBytes: Int { cache?.imageBytes ?? 0 }
    var resourcesLoaded: Bool { cache != nil }

    init(resourceDirectory: URL, library: MTLLibrary? = nil, displayScale: CGFloat = 3) throws {
        let loadedAssets = try TutuWuAssets(directory: resourceDirectory)
        directory = resourceDirectory; manifest = loadedAssets.manifest; suppliedLibrary = library
        self.displayScale = displayScale
        pieces = loadedAssets.manifest.pieces.map { p in
            TutuWuPiece(key: p.key, label: p.label, frame: CGRect(x: p.frame.left, y: p.frame.top, width: p.frame.w, height: p.frame.h), visible: p.visible, z: p.frame.z)
        }
        func raster(_ name: String) -> CGRect {
            guard let box = loadedAssets.manifest.outputs.first(where: { $0.file == name + ".png" })?.rasterFrame else {
                return CGRect(x: 0, y: 0, width: 1560, height: 844)
            }
            return CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        }
        tableRaster = raster("table")
        pieceRasters = loadedAssets.manifest.pieces.map { raster("piece-" + $0.key) }
        stripLayer.addSublayer(shade); stripLayer.addSublayer(table)
        for piece in pieces {
            let layer = CALayer(); layer.name = piece.key
            layer.zPosition = CGFloat(piece.z); layer.isHidden = !piece.visible
            stripLayer.addSublayer(layer); pieceLayers.append(layer)
        }
        #if os(iOS)
        memoryWarningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseResources()
        }
        #endif
    }

    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
    }

    func render(viewport: CGSize, offset: CGFloat, wallpaper: String) throws {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0, offset.isFinite else { throw TutuWuError.viewport }
        guard manifest.papers[wallpaper] != nil else { throw TutuWuError.resource(wallpaper) }
        if previousViewport == viewport && previousOffset == offset && previousWallpaper == wallpaper { return }
        let needsCache = previousViewport != viewport || previousWallpaper != wallpaper
        previousViewport = viewport; previousOffset = offset; previousWallpaper = wallpaper
        renderCount += 1
        if needsCache {
            generation &+= 1
            let requestedGeneration = generation
            submissionLock.lock()
            requestedEpoch = requestedGeneration; pendingSubmission = nil; pendingCapture = nil
            submissionLock.unlock()
            activeRenderer?.beginGeneration(requestedGeneration)
            diagnostics.generation = requestedGeneration; diagnostics.ready = false
            onDiagnostics?(diagnostics)
            worker.async { [weak self] in
                self?.prepareCache(viewport: viewport, wallpaper: wallpaper, generation: requestedGeneration)
            }
        } else if diagnostics.ready { submitLatest() }
    }

    private func prepareCache(viewport: CGSize, wallpaper: String, generation: UInt64) {
        guard isRequested(generation) else { return }
        workerRequest = (viewport, wallpaper, generation)
        prepareLatest()
    }

    private func prepareLatest() {
        guard !workerPreparing else { return }
        guard let request = workerRequest, isRequested(request.generation) else {
            if workerRenderer?.cacheCount == 0 { workerRenderer = nil }
            return
        }
        let (viewport, wallpaper, generation) = request
        do {
            let renderer: TutuWuRenderer
            if let existing = workerRenderer { renderer = existing } else {
                renderer = try TutuWuRenderer(library: suppliedLibrary)
                workerRenderer = renderer; installCallbacks(renderer)
                renderer.onCacheReleased = { [weak self] in
                    self?.worker.async { [weak self] in self?.prepareLatest() }
                }
            }
            // Old GPU submissions may still retain the replaced allocation. Do not create a third.
            guard renderer.cacheCount < 2 else { return }
            submissionLock.lock()
            guard requestedEpoch == generation else { submissionLock.unlock(); return }
            renderer.beginGeneration(generation); submissionLock.unlock()
            if let cached = workerCache, cached.wallpaper == wallpaper, cached.cache.viewport == viewport {
                workerPreparing = true
                activate(cached.cache, renderer: renderer, wallpaper: wallpaper, generation: generation)
                return
            }
            if workerViewport != viewport { workerViewport = viewport; workerLighting = nil }
            let assets: TutuWuAssets
            if let existing = workerAssets { assets = existing } else {
                assets = try TutuWuAssets(directory: directory)
                _ = try assets.image("shade"); _ = try assets.image("table")
                for piece in pieces where piece.visible { _ = try assets.image("piece-" + piece.key) }
                workerAssets = assets
            }
            guard isRequested(generation) else { return }
            if workerLighting == nil { workerLighting = try Self.light(assets: assets, viewport: viewport, renderer: renderer) }
            guard isRequested(generation), let lighting = workerLighting else { return }
            workerPreparing = true
            try renderer.prepare(assets: assets, wallpaper: wallpaper, viewport: viewport, generation: generation, lighting: lighting) { [weak self] result in
                self?.worker.async { [weak self] in
                    guard let self else { return }
                    guard self.isRequested(generation) else {
                        self.workerPreparing = false
                        self.worker.async { [weak self] in self?.prepareLatest() }
                        return
                    }
                    switch result {
                    case .failure(let error):
                        self.workerPreparing = false
                        self.report(error, generation: generation)
                    case .success(let prepared):
                        self.workerCache = (wallpaper, prepared)
                        self.activate(prepared, renderer: renderer, wallpaper: wallpaper, generation: generation)
                    }
                }
            }
        } catch {
            workerPreparing = false
            report(error, generation: generation)
        }
    }

    private func report(_ error: Error, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onError?(error)
        }
    }

    private func activate(_ prepared: TutuWuRenderer.Cache, renderer: TutuWuRenderer, wallpaper: String, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.worker.async { [weak self] in
                    guard let self else { return }
                    if self.workerRequest?.generation == generation { self.workerRequest = nil }
                    self.workerPreparing = false
                    self.prepareLatest()
                }
            }
            guard self.generation == generation else { return }
            let active = prepared.activated(generation: generation)
            self.cache = active; self.activeRenderer = renderer
            self.configurePresentationObserver(renderer)
            self.configureCompletionObserver(renderer)
            renderer.configure(self.viewportLayer, self.overlayLayer, viewport: active.viewport, displayScale: self.displayScale)
            self.install(active); self.diagnostics.ready = true
            renderer.markReady(generation, wallpaper: wallpaper, viewport: active.viewport)
            self.submitLatest()
        }
    }

    private func installCallbacks(_ renderer: TutuWuRenderer) {
        renderer.onDiagnostics = { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.generation == snapshot.generation else { return }
                if snapshot.readyGeneration == self.diagnostics.readyGeneration && snapshot.completed < self.diagnostics.completed { return }
                let completed = snapshot.completed > self.diagnostics.completed
                var snapshot = snapshot
                snapshot.peakCacheCount = max(snapshot.peakCacheCount, self.diagnostics.peakCacheCount)
                self.diagnostics = snapshot; self.onDiagnostics?(snapshot)
                guard completed else { return }
                self.submissionLock.lock()
                let dirty = self.acceptedEpoch != snapshot.generation || self.acceptedOffset != self.previousOffset
                self.submissionLock.unlock()
                if dirty { self.submitLatest() }
            }
        }
        renderer.onError = { [weak self] error, generation in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.onError?(error)
            }
        }
    }

    private func configurePresentationObserver(_ renderer: TutuWuRenderer) {
        guard onFramePresented != nil else { renderer.setPresentationObserver(nil); return }
        renderer.setPresentationObserver { [weak self] time, generation in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.onFramePresented?(time, generation)
            }
        }
    }

    private func configureCompletionObserver(_ renderer: TutuWuRenderer) {
        guard onFrameCompleted != nil else { renderer.setCompletionObserver(nil); return }
        renderer.setCompletionObserver { [weak self] seconds, generation in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.onFrameCompleted?(seconds, generation)
            }
        }
    }

    private func isRequested(_ epoch: UInt64) -> Bool {
        submissionLock.lock(); defer { submissionLock.unlock() }
        return requestedEpoch == epoch
    }

    private func install(_ cache: TutuWuRenderer.Cache) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        viewportLayer.isHidden = false; overlayLayer.isHidden = false
        let viewport = cache.viewport, scale = cache.viewport.height / 844
        let bounds = CGRect(x: 0, y: 0, width: 1560 * scale, height: viewport.height)
        stripLayer.frame = bounds
        viewportLayer.frame = CGRect(origin: .zero, size: viewport)
        overlayLayer.frame = CGRect(origin: .zero, size: viewport)
        shade.frame = bounds
        table.frame = tableRaster.applying(CGAffineTransform(scaleX: scale, y: scale))
        shade.contents = cache.images["shade"]; table.contents = cache.images["table"]
        for (index, piece) in pieces.enumerated() {
            pieceLayers[index].frame = pieceRasters[index].applying(CGAffineTransform(scaleX: scale, y: scale))
            if piece.visible { pieceLayers[index].contents = cache.images["piece-" + piece.key] }
        }
        CATransaction.commit()
    }

    private func submitLatest() {
        guard let cache, cache.generation == generation, let renderer = activeRenderer, let offset = previousOffset else { return }
        let capture = captureNextFrame; captureNextFrame = nil
        let wall = viewportLayer, light = overlayLayer
        submissionLock.lock()
        if let capture { pendingCapture = capture }
        guard queuedEpoch != cache.generation || queuedOffset != offset else { submissionLock.unlock(); return }
        queuedEpoch = cache.generation; queuedOffset = offset
        pendingSubmission = { [weak self] in
            guard let self, self.isRequested(cache.generation) else { return }
            self.submissionLock.lock()
            if let capture = self.pendingCapture {
                renderer.captureNextFrame = capture; self.pendingCapture = nil
                renderer.captureGeneration = cache.generation
            }
            self.submissionLock.unlock()
            let accepted = renderer.render(cache: cache, offset: offset, wall: wall, light: light)
            self.submissionLock.lock()
            if accepted {
                self.acceptedEpoch = cache.generation; self.acceptedOffset = offset
            }
            if self.queuedEpoch == cache.generation && self.queuedOffset == offset { self.queuedOffset = nil }
            self.submissionLock.unlock()
        }
        guard !submissionScheduled else { submissionLock.unlock(); return }
        submissionScheduled = true; submissionLock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            while true {
                self.submissionLock.lock()
                guard let submission = self.pendingSubmission else {
                    self.submissionScheduled = false; self.submissionLock.unlock(); return
                }
                self.pendingSubmission = nil; self.submissionLock.unlock()
                autoreleasepool { submission() }
            }
        }
    }

    func releaseResources() {
        generation &+= 1; activeRenderer?.beginGeneration(generation)
        submissionLock.lock()
        requestedEpoch = generation; pendingSubmission = nil; pendingCapture = nil; acceptedOffset = nil; queuedOffset = nil
        submissionLock.unlock()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [shade, table] + pieceLayers { layer.contents = nil }
        viewportLayer.isHidden = true; overlayLayer.isHidden = true
        viewportLayer.device = nil; overlayLayer.device = nil
        CATransaction.commit()
        cache = nil; activeRenderer = nil; captureNextFrame = nil
        diagnostics.generation = generation; diagnostics.ready = false; diagnostics.cacheCount = 0
        diagnostics.cacheBytes = 0
        diagnostics.readyGeneration = nil; diagnostics.readyWallpaper = nil; diagnostics.readyViewport = nil
        previousViewport = nil; previousOffset = nil; previousWallpaper = nil
        worker.async { [weak self] in
            guard let self else { return }
            self.workerRequest = nil; self.workerCache = nil
            self.workerLighting = nil; self.workerAssets = nil; self.workerViewport = nil
            if !self.workerPreparing && self.workerRenderer?.cacheCount == 0 { self.workerRenderer = nil }
        }
        onDiagnostics?(diagnostics)
    }

    // light.js drawLight: the screen-fixed lamp cutout cannot be a strip screenshot.
    // Recompose the original stop colors, candle pool, frozen motes and original flame canvases.
    // Rasterize only once per cache size. Separate operation textures retain the original
    // destination-out / plus-lighter / source-over order instead of flattening the flame stack.
    private static func light(assets: TutuWuAssets, viewport: CGSize, renderer: TutuWuRenderer) throws -> TutuWuRenderer.Lighting {
        func context(_ size: CGSize) throws -> CGContext {
            let width = max(1, Int((size.width * 2).rounded())), height = max(1, Int((size.height * 2).rounded()))
            guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TutuWuError.resource("light context") }
            c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 2, y: -2)
            return c
        }
        var c = try context(viewport)
        let s = viewport.height / 844
        let worldSize = CGSize(width: 1560 * s, height: viewport.height)
        let candle = assets.manifest.candle
        let x = CGFloat(candle.x) * s, y = CGFloat(candle.y) * s
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
        func radial(_ x: CGFloat, _ y: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ stops: [CGFloat], _ colors: [CGColor], _ rect: CGRect) {
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: stops)!
            c.saveGState(); c.clip(to: rect)
            c.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: r0, endCenter: CGPoint(x: x, y: y), endRadius: r1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()
        }
        func image() throws -> CGImage {
            guard let image = c.makeImage() else { throw TutuWuError.resource("light image") }; return image
        }
        c.setFillColor(color(5, 3, 4, 0.74)); c.fill(CGRect(origin: .zero, size: viewport))
        c.setBlendMode(.destinationOut)
        c.saveGState()
        c.translateBy(x: viewport.width / 2, y: CGFloat(140 + 25 * sin(1.0)) * s)
        c.scaleBy(x: 1, y: 0.8)
        radial(0, 0, 0, 640 * s, [0, 0.5, 1], [color(0,0,0,0.36),color(0,0,0,0.17),color(0,0,0,0)], CGRect(x: -700*s, y: -700*s, width: 1400*s, height: 1400*s))
        c.restoreGState()
        let lamp = try renderer.lightTexture(image(), crop: false).0
        c = try context(worldSize)
        radial(x, y, 0, 780*s, [0,0.17,0.4,0.7,1], [color(0,0,0,1),color(0,0,0,0.95),color(0,0,0,0.64),color(0,0,0,0.22),color(0,0,0,0)], CGRect(x:x-800*s,y:y-800*s,width:1600*s,height:1600*s))
        var textures = [MTLTexture](), regions = [SIMD4<Float>]()
        func append(mask: Bool = false) throws {
            let (texture, region) = try renderer.lightTexture(image(), mask: mask)
            textures.append(texture); regions.append(region)
        }
        try append(mask: true)
        c = try context(worldSize); c.setBlendMode(.plusLighter)
        radial(x,y,4,360*s,[0,0.4,1],[color(255,170,92,0.12),color(210,120,60,0.045),color(120,60,30,0)],CGRect(x:x-380*s,y:y-380*s,width:760*s,height:760*s))
        for mote in assets.manifest.motes {
            let lit = max(0, 1 - hypot(mote.x-candle.x, mote.y-candle.y) / 320)
            if lit < 0.04 { continue }
            c.setFillColor(color(255,220,174,CGFloat(lit)*0.75))
            c.fill(CGRect(x:CGFloat(mote.x)*s,y:CGFloat(mote.y)*s,width:CGFloat(mote.s)*s,height:CGFloat(mote.s)*s))
        }
        try append()
        for (i, flame) in candle.flames.enumerated() {
            let fx = CGFloat(flame[0])*s, fy = CGFloat(flame[1])*s, k = 1.25*s*CGFloat(candle.k)
            c = try context(worldSize); c.setBlendMode(.plusLighter)
            radial(fx,fy-10*k,1,50*k,[0,0.4,1],[color(255,220,150,0.55),color(255,160,70,0.16),color(255,120,40,0)],CGRect(x:fx-60*k,y:fy-70*k,width:120*k,height:120*k))
            try append()
            c = try context(worldSize); c.setBlendMode(.normal)
            let flameImage = try assets.image("flame-\(i % 3)")
            let rect = CGRect(x:fx-12*k,y:fy-36*k,width:24*k,height:40*k)
            c.saveGState(); c.translateBy(x: rect.minX, y: rect.maxY); c.scaleBy(x: 1, y: -1)
            c.draw(flameImage, in: CGRect(origin: .zero, size: rect.size)); c.restoreGState()
            try append()
        }
        if textures.count > 8 {
            assertionFailure("TutuWu light layers exceed the shader's 8-slot light array")
            textures = Array(textures.prefix(8)); regions = Array(regions.prefix(8))
        }
        return TutuWuRenderer.Lighting(lights: textures, regions: regions, lamp: lamp)
    }
}
#endif
#endif
