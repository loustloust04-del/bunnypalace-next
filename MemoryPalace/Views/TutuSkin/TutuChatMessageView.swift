import MemoryCore
#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import Metal
import QuartzCore
import Observation
import UIKit


extension TutuChatMessageSnapshot {
    static func make(node: MessageNode, scripts: [RegexScript], userName: String, assistantName: String,
                     streamingText: String? = nil) -> Self {
        let user = node.role == "user"
        let segments = ChatDisplaySnapshot.segments(of: node)
        let raw: String
        if let streamingText { raw = streamingText }
        else if user, let segments, !segments.isEmpty {
            raw = segments.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined(separator: "\n\n")
        } else if streamingText == nil, let segments, segments.allSatisfy({ if case .text = $0 { return true }; if case .audioRef = $0 { return true }; return false }) {
            let body = segments.compactMap { if case .text(let value) = $0 { return value }; return nil }.joined(separator: "\n\n")
            raw = body.isEmpty ? ChatSystemMessage.split(node.content, legacy: node.usesLegacyErrorMarker).body : ChatSystemMessage.split(body, legacy: node.usesLegacyErrorMarker).body
        } else { raw = user ? node.content : ChatSystemMessage.split(node.content, legacy: node.usesLegacyErrorMarker).body }
        let text = MessageDisplayText.make(raw, role: node.role, scripts: scripts,
                                           userName: userName, charName: assistantName,
                                           legacyErrorMarker: node.usesLegacyErrorMarker).body
        let complex = segments?.contains { segment in
            switch segment {
            case .text, .image, .imageRef, .attachment, .audioRef: return false
            case .thinking: return !(segments?.isAttachedThinkingReply ?? false)
            default: return true
            }
        } ?? false
        let attachmentOnly = text.isEmpty && (segments?.contains { segment in
            switch segment {
            case .image, .imageRef, .attachment, .file, .fileData, .fileDataRef: return true
            default: return false
            }
        } ?? false)
        return Self(id: node.id, text: text, isUser: user,
                    isRich: complex || attachmentOnly || (user && (segments?.userVoiceNote ?? false))
                        || node.contentType == "heartvoice" || node.content.hasPrefix("💭 心声\n\n")
                        || TutuChatContent.isMarkdown(text),
                    hasRecall: !user && DisclosureKind.recall.mode != .hidden && !node.recallHits.isEmpty,
                    recallLabel: "想起来了 \(node.recallHits.count) 件事" + (RecallPreview.text(node.recallHits).map { " · \($0)" } ?? ""))
    }
}

private struct TutuChatPathKey: EnvironmentKey { static let defaultValue: [TutuChatMessageSnapshot] = [] }
extension EnvironmentValues {
    var tutuChatPath: [TutuChatMessageSnapshot] {
        get { self[TutuChatPathKey.self] }
        set { self[TutuChatPathKey.self] = newValue }
    }
}

/// M3b consumes real response identity and a monotonic, node-stable first-card time.
@MainActor @Observable final class TutuChatTimeline {
    static let shared = TutuChatTimeline()
    private(set) var firstCardCreatedAt: [String: CFTimeInterval] = [:]
    private(set) var nativeHeights: [String: CGFloat] = [:]
    func cardCreated(nodeID: String) {
        if firstCardCreatedAt[nodeID] == nil { firstCardCreatedAt[nodeID] = CACurrentMediaTime() }
    }
    func measured(nodeID: String, height: CGFloat) {
        if nativeHeights[nodeID] != height { nativeHeights[nodeID] = height }
    }
    func release() {
        firstCardCreatedAt.removeAll()
        nativeHeights.removeAll()
    }
}





private final class TutuChatRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    func advance() -> Int { lock.lock(); defer { lock.unlock() }; generation += 1; return generation }
    func accepts(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == value }
}

/// All resource decoding, Core Text layout/masks and GPU waits are confined to this worker.
final class TutuChatRenderService: @unchecked Sendable {
    static let shared = TutuChatRenderService()
    private let worker = DispatchQueue(label: "TutuChat.render", qos: .userInitiated)
    private let lifecycle = TutuChatRequestGate()
    private var resources: Resources?
    private let cache = TutuChatTextureCache()
    private var streams: [String: Stream] = [:]
    private let layouts = TutuChatLayoutCache()
    private let queueLock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var streamReleases: Set<String> = []
    private var nextSequence: UInt64 = 0
    private var draining = false
    private var accepting = true
    @MainActor private var visibleRows: [String: CGFloat] = [:]
    private final class Pending {
        let request: TutuChatRequest
        let gate: TutuChatRequestGate
        let generation: Int
        let epoch: Int
        let sequence: UInt64
        var visible: Bool
        let completion: (Result<TutuChatMessageFrame, Error>, Bool) -> Void
        init(request: TutuChatRequest, gate: TutuChatRequestGate, generation: Int,
             epoch: Int, sequence: UInt64, visible: Bool,
             completion: @escaping (Result<TutuChatMessageFrame, Error>, Bool) -> Void) {
            self.request = request; self.gate = gate; self.generation = generation
            self.epoch = epoch; self.sequence = sequence; self.visible = visible
            self.completion = completion
        }
    }
    private struct Stream {
        var identity: String
        var cards: [Int: TutuCardStream]
        var revisions: [Int: UInt64] = [:]
    }
    private final class Resources {
        let gpu: TutuChatGPU
        let cards: TutuCardRenderer
        let felt: TutuFeltRenderer
        let lace: TutuLaceRenderer
        let background: TutuChatBackgroundRenderer
        let shadows: TutuChatShadowRenderer
        init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary(),
                  let root = Bundle.main.resourceURL?.appendingPathComponent("TutuSkin/chat") else { throw TutuChatError.allocation }
            try TutuChatTypography.registerFonts(resourceURL: root)
            gpu = try TutuChatGPU(device: device, library: library, resourceURL: root)
            cards = try TutuCardRenderer(gpu: gpu); felt = try TutuFeltRenderer(gpu: gpu)
            lace = try TutuLaceRenderer(gpu: gpu); background = try TutuChatBackgroundRenderer(gpu: gpu)
            shadows = try TutuChatShadowRenderer(gpu: gpu)
        }
    }
    private func prepared() throws -> Resources {
        if let resources { return resources }
        let value = try Resources(); resources = value
        #if DEBUG
        TutuChatDebugCounters.shared.configure(maxTextureSize: value.gpu.maxTextureSize2D)
        #endif
        return value
    }
    @MainActor func release() {
        visibleRows.removeAll()
        #if DEBUG
        TutuChatDebugCounters.shared.clearRows()
        #endif
        queueLock.lock()
        let epoch = lifecycle.advance()
        accepting = false
        let cancelled = Array(pending.values)
        pending.removeAll()
        queueLock.unlock()
        for job in cancelled { finishPending(job, event: "request.cancel.release") }
        TutuChatTimeline.shared.release()
        TutuChatRenderTrace.emit("service.release", "lifecycle:cache+layouts+streams+resources")
        worker.async {
            self.cache.removeAll()
            self.layouts.removeAll()
            self.streams.removeAll(); self.resources = nil
            self.restoreVisibility(epoch: epoch)
            self.queueLock.lock()
            if self.lifecycle.accepts(epoch) { self.accepting = true }
            let schedule = self.accepting && !self.draining
                && (!self.pending.isEmpty || !self.streamReleases.isEmpty)
            if schedule { self.draining = true }
            self.queueLock.unlock()
            TutuChatRenderTrace.emit("service.released", "worker:cache+layouts+streams+resources")
            if schedule { self.drain() }
        }
    }
    func releaseStream(nodeID: String) {
        queueLock.lock()
        streamReleases.insert(nodeID)
        let schedule = accepting && !draining
        if schedule { draining = true }
        queueLock.unlock()
        if schedule { worker.async { self.drain() } }
    }
    func trimCache() {
        let epoch = lifecycle.advanceSnapshot()
        worker.async {
            TutuChatRenderTrace.emit("cache.release.reason", "memory-warning/trim")
            self.cache.removeAll(); self.layouts.removeAll()
            self.restoreVisibility(epoch: epoch)
        }
    }
    private func restoreVisibility(epoch: Int) {
        DispatchQueue.main.async {
            guard self.lifecycle.accepts(epoch) else { return }
            for (nodeID, viewportHeight) in self.visibleRows {
                self.cache.setVisible(nodeID: nodeID, visible: true, viewportHeight: viewportHeight)
            }
        }
    }
    fileprivate func cached(_ request: TutuChatRequest) -> TutuChatMessageFrame? {
        let key = request.cacheKey
        TutuChatRenderTrace.emit("request.identity", request.message.id + "|" + (key ?? "streaming"))
        TutuChatRenderTrace.emit("request.cache.lookup", request.message.id)
        guard let key else { return nil }
        queueLock.lock()
        let available = accepting
        queueLock.unlock()
        return available ? cache.value(forKey: key) : nil
    }
    @MainActor func visibility(nodeID: String, visible: Bool, viewportHeight: CGFloat) {
        queueLock.lock()
        for job in pending.values where job.request.message.id == nodeID { job.visible = visible }
        queueLock.unlock()
        if visible { visibleRows[nodeID] = viewportHeight }
        else { visibleRows.removeValue(forKey: nodeID) }
        cache.setVisible(nodeID: nodeID, visible: visible, viewportHeight: viewportHeight)
    }
    fileprivate func cancel(gate: TutuChatRequestGate) {
        queueLock.lock()
        let job = pending.removeValue(forKey: ObjectIdentifier(gate))
        queueLock.unlock()
        if let job { finishPending(job, event: "request.cancel") }
    }
    private func finishPending(_ job: Pending, event: String) {
        TutuChatRenderTrace.emit(event, job.request.message.id)
        #if DEBUG
        TutuChatDebugCounters.shared.record(event == "request.coalesced" ? .coalesced : .cancelled)
        #endif
        TutuChatRenderTrace.emit("request.worker.end", job.request.message.id)
    }
    private func drain() {
        while true {
            queueLock.lock()
            guard accepting else {
                draining = false
                queueLock.unlock()
                return
            }
            if let nodeID = streamReleases.popFirst() {
                queueLock.unlock()
                TutuChatRenderTrace.emit("stream.release", nodeID)
                streams.removeValue(forKey: nodeID)
                continue
            }
            var next: Pending?
            for job in pending.values {
                if let current = next {
                    if (job.visible && !current.visible)
                        || (job.visible == current.visible && job.sequence < current.sequence) { next = job }
                } else { next = job }
            }
            guard let next else {
                draining = false
                queueLock.unlock()
                return
            }
            pending.removeValue(forKey: ObjectIdentifier(next.gate))
            queueLock.unlock()
            execute(next)
        }
    }
    private func hit(_ key: String) -> TutuChatMessageFrame? { cache.value(forKey: key) }
    private func insert(_ frame: TutuChatMessageFrame, key: String) { cache.insert(frame, forKey: key) }
    private func cachedRaster(_ key: String, make: () throws -> TutuChatRaster) rethrows -> TutuChatRaster {
        if let raster = hit(key)?.pieces.first?.raster { return raster }
        let raster = try make()
        insert(TutuChatMessageFrame(size: raster.rect.size,
            pieces: [TutuChatTexturePiece(raster: raster, origin: .zero, bodySize: raster.rect.size)], lace: nil, isUser: false), key: key)
        return raster
    }
    private func paintedRaster(_ raster: TutuChatRaster, at origin: CGPoint = .zero) -> TutuChatRaster {
        let painted = TutuChatConversationLayout.canvasPaintRect(raster.rect.offsetBy(dx: origin.x, dy: origin.y))
        return TutuChatRaster(texture: raster.texture, rect: painted.offsetBy(dx: -origin.x, dy: -origin.y))
    }
    private func plan(_ request: TutuChatRequest) -> TutuChatItemLayout {
        var path = request.path
        if let i = path.firstIndex(where: { $0.id == request.message.id }) { path[i] = request.message }
        else { path.append(request.message) }
        var items: [TutuChatLayoutItem] = []
        var target = 0, turnIndex = 0, streamingTurn: Int?
        for message in path {
            if message.hasDate { items.append(.date(message.dateLabel)) }
            if message.hasRecall { items.append(.recall(message.recallLabel)) }
            if message.id == request.message.id { target = items.count; if request.streaming { streamingTurn = turnIndex } }
            if message.isRich { items.append(.native(isUser: message.isUser, height: message.nativeHeight)) }
            else if message.isUser { items.append(.me(TutuChatContent.feltParts(message.text))) }
            else { items.append(.him(TutuChatContent.cards(message.text))) }
            if !message.isUser { turnIndex += 1 }
            if message.id == request.message.id { break }
        }
        return TutuChatConversationLayout.layout(items: items, listWidth: 268, streamingTurn: streamingTurn, cache: layouts)[target]
    }
    fileprivate func render(_ request: TutuChatRequest, gate: TutuChatRequestGate, generation: Int,
                            visible: Bool = false,
                            completion: @escaping (Result<TutuChatMessageFrame, Error>, Bool) -> Void) {
        let epoch = lifecycle.advanceSnapshot()
        TutuChatRenderTrace.emit("request.enqueue", request.message.id)
        #if DEBUG
        TutuChatDebugCounters.shared.record(.enqueued)
        #endif
        queueLock.lock()
        guard lifecycle.accepts(epoch) else {
            queueLock.unlock()
            TutuChatRenderTrace.emit("request.cancel.release", request.message.id)
            TutuChatRenderTrace.emit("request.worker.end", request.message.id)
            #if DEBUG
            TutuChatDebugCounters.shared.record(.cancelled)
            #endif
            return
        }
        nextSequence &+= 1
        let job = Pending(request: request, gate: gate, generation: generation, epoch: epoch,
                          sequence: nextSequence, visible: visible, completion: completion)
        let replaced = pending.updateValue(job, forKey: ObjectIdentifier(gate))
        let schedule = accepting && !draining
        if schedule { draining = true }
        queueLock.unlock()
        if let replaced { finishPending(replaced, event: "request.coalesced") }
        if schedule { worker.async { self.drain() } }
    }
    private func execute(_ job: Pending) {
        let request = job.request, gate = job.gate, generation = job.generation
        let epoch = job.epoch, completion = job.completion
        TutuChatRenderTrace.emit("request.worker.begin", request.message.id)
        #if DEBUG
        var handedOff = false
        #endif
        defer {
            TutuChatRenderTrace.emit("request.worker.end", request.message.id)
            #if DEBUG
            TutuChatDebugCounters.shared.record(.workerCompleted)
            if !handedOff { TutuChatDebugCounters.shared.record(.cancelled) }
            #endif
        }
        TutuChatRenderTrace.emit("request.start.row-valid", request.message.id, gate.accepts(generation) ? 1 : 0)
        guard gate.accepts(generation), lifecycle.accepts(epoch) else { return }
        do {
            let key = request.cacheKey
            TutuChatRenderTrace.emit("request.identity", request.message.id + "|" + (key ?? "streaming"))
            TutuChatRenderTrace.emit("request.cache.lookup", request.message.id)
            if let key, let frame = self.hit(key) {
                #if DEBUG
                handedOff = true
                #endif
                DispatchQueue.main.async {
                    guard gate.accepts(generation), self.lifecycle.accepts(epoch) else {
                        #if DEBUG
                        TutuChatDebugCounters.shared.record(.cancelled)
                        #endif
                        return
                    }
                    completion(.success(frame), false)
                }
                return
            }
            let resources = try self.prepared()
            TutuChatRenderTrace.emit("resources.ready", request.message.id)
            guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
            TutuChatRenderTrace.emit("layout.begin", request.message.id)
            let plan = self.plan(request)
            TutuChatRenderTrace.emit("layout.origin", request.message.id, Double(plan.origin.y))
            TutuChatRenderTrace.emit("layout.height", request.message.id, Double(plan.size.height))
            TutuChatRenderTrace.emit("layout.end", request.message.id)
            guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
            let preparedLace = try resources.gpu.preflight(item: plan, scale: request.scale)
            var pieces: [TutuChatTexturePiece] = []
            let materialIdentity = "\(request.message.id)|\(request.width)|\(request.scale)|\(request.mode)"
            if request.message.isUser {
                for felt in plan.felts {
                    guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
                    let shapeKey = "felt|\(materialIdentity)|\(felt.index)|\(felt.size)|\(felt.ears)|\(felt.tail)|\(felt.emoji)"
                    let raw = try self.cachedRaster(shapeKey) {
                        TutuChatRenderTrace.emit("felt.begin", request.message.id)
                        defer { TutuChatRenderTrace.emit("felt.end", request.message.id) }
                        return try resources.felt.render(size: felt.size, ears: felt.ears, tail: felt.tail,
                                                  emoji: felt.emoji, index: felt.index, scale: request.scale)
                    }
                    let raster = self.paintedRaster(raw, at: felt.origin)
                    let shadow = try self.cachedRaster("shadow|\(shapeKey)|\(raster.rect)") {
                        TutuChatRenderTrace.emit("shadow.begin", request.message.id)
                        defer { TutuChatRenderTrace.emit("shadow.end", request.message.id) }
                        return try resources.shadows.render(raster: raster, material: .felt, scale: request.scale)
                    }
                    pieces.append(TutuChatTexturePiece(raster: raster, shadow: shadow, origin: felt.origin,
                        feltText: request.message.isRich ? nil : felt.lines.joined(separator: "\n"), bodySize: felt.size, emoji: felt.emoji))
                }
            } else {
                guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
                let streamIdentity = "\(plan.cards.first?.index ?? 0)|\(request.scale)|\(request.width)|\(request.mode)"
                var session = self.streams[request.message.id]
                if session?.identity != streamIdentity { session = nil }
                var active = session ?? Stream(identity: streamIdentity, cards: [:])
                if request.streaming, active.cards.isEmpty, let first = plan.cards.first {
                    let stream = try resources.cards.stream(index: first.index, scale: request.scale)
                    active.cards[0] = stream
                    self.streams[request.message.id] = active
                    let empty = TutuChatTypography.card(action: "", say: "")
                    let raster = self.paintedRaster(try stream.update(layout: empty))
                    active.revisions[0] = 1
                    self.streams[request.message.id] = active
                    let shadow = try self.cachedRaster("shadow|card|\(materialIdentity)|\(first.index)|\(empty.size)|\(raster.rect)") {
                        try resources.shadows.render(raster: raster, material: .card, scale: request.scale)
                    }
                    let firstFrame = TutuChatMessageFrame(size: empty.size,
                        pieces: [TutuChatTexturePiece(raster: raster, shadow: shadow, origin: .zero, bodySize: empty.size, revision: 1)], lace: nil, isUser: false)
                    // The model may accept this first card across same-shape stream generations.
                    #if DEBUG
                    TutuChatDebugCounters.shared.record(.frameReady)
                    #endif
                    DispatchQueue.main.async {
                        guard self.lifecycle.accepts(epoch) else {
                            #if DEBUG
                            TutuChatDebugCounters.shared.record(.cancelled)
                            #endif
                            return
                        }
                        completion(.success(firstFrame), true)
                    }
                }
                for (offset, card) in plan.cards.enumerated() {
                    guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
                    TutuChatRenderTrace.emit("card.begin", "\(request.message.id)|\(offset)")
                    defer { TutuChatRenderTrace.emit("card.end", "\(request.message.id)|\(offset)") }
                    TutuChatRenderTrace.emit("card.row-valid", request.message.id, gate.accepts(generation) ? 1 : 0)
                    let raw: TutuChatRaster
                    if request.streaming || active.cards[offset] != nil {
                        let stream: TutuCardStream
                        if let existing = active.cards[offset] { stream = existing }
                        else { stream = try resources.cards.stream(index: card.index, scale: request.scale); active.cards[offset] = stream }
                        if request.streaming { self.streams[request.message.id] = active }
                        let fullRenderCount = stream.fullRenderCount
                        raw = try stream.update(layout: card.layout)
                        if stream.lastDirtyRect != nil || stream.fullRenderCount != fullRenderCount { active.revisions[offset, default: 0] &+= 1 }
                        if request.streaming { self.streams[request.message.id] = active }
                    } else { raw = try resources.cards.render(layout: card.layout, index: card.index, scale: request.scale) }
                    let raster = self.paintedRaster(raw, at: card.origin)
                    let shadow = try self.cachedRaster("shadow|card|\(materialIdentity)|\(card.index)|\(card.layout.size)|\(raster.rect)") {
                        TutuChatRenderTrace.emit("shadow.begin", request.message.id)
                        defer { TutuChatRenderTrace.emit("shadow.end", request.message.id) }
                        return try resources.shadows.render(raster: raster, material: .card, scale: request.scale)
                    }
                    pieces.append(TutuChatTexturePiece(raster: raster, shadow: shadow, origin: card.origin,
                                                      bodySize: card.layout.size, revision: active.revisions[offset, default: 0]))
                }
                if !request.streaming { self.streams.removeValue(forKey: request.message.id) }
            }
            guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
            let rects = plan.cards.map { CGRect(origin: $0.origin, size: $0.layout.size) }
            let laceKey = "lace|\(materialIdentity)|\(plan.turnIndex)|\(rects)"
            var rawLace = self.hit(laceKey)?.pieces.first?.raster
            if !request.message.isUser, rawLace == nil, let rendered = try resources.lace.render(cards: rects, index: plan.turnIndex, scale: request.scale, prepared: preparedLace) {
                rawLace = self.cachedRaster(laceKey) { rendered }
            }
            let lace = rawLace.map { self.paintedRaster($0) }
            let laceShadow = try lace.map { raster in
                try self.cachedRaster("shadow|\(laceKey)|\(raster.rect)") { try resources.shadows.render(raster: raster, material: .lace, scale: request.scale) }
            }
            let frame = TutuChatMessageFrame(size: plan.size, pieces: pieces, lace: lace, laceShadow: laceShadow, isUser: request.message.isUser)
            TutuChatRenderTrace.emit("frame.ready", request.message.id, Double(frame.allocatedBytes))
            #if DEBUG
            TutuChatDebugCounters.shared.record(.frameReady)
            #endif
            #if TUTU_SCROLL_TRACE
            for (index, piece) in frame.pieces.enumerated() {
                TutuChatRenderTrace.emit("frame.piece.bytes", "\(request.message.id)|\(index)", Double(piece.raster.allocatedBytes + (piece.shadow?.allocatedBytes ?? 0)))
            }
            #endif
            TutuChatRenderTrace.emit("request.finish.row-valid", request.message.id, gate.accepts(generation) ? 1 : 0)
            guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
            if let key {
                self.cache.insert(frame, forKey: key, nodeID: request.message.id,
                                  range: plan.origin.y...(plan.origin.y + plan.size.height))
            }
            #if DEBUG
            handedOff = true
            #endif
            DispatchQueue.main.async {
                guard gate.accepts(generation), self.lifecycle.accepts(epoch) else {
                    #if DEBUG
                    TutuChatDebugCounters.shared.record(.cancelled)
                    #endif
                    return
                }
                completion(.success(frame), false)
            }
        } catch {
            self.streams.removeValue(forKey: request.message.id)
            #if DEBUG
            handedOff = true
            if case TutuChatError.textureSize = error { TutuChatDebugCounters.shared.record(.sizeError) }
            else { TutuChatDebugCounters.shared.record(.otherError) }
            #endif
            DispatchQueue.main.async {
                guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
                completion(.failure(error), false)
            }
        }
    }
    fileprivate func background(mode: String, scale: CGFloat, size: CGSize, gate: TutuChatRequestGate, generation: Int,
                    completion: @escaping (Result<TutuChatRaster, Error>) -> Void) {
        let epoch = lifecycle.advanceSnapshot()
        TutuChatRenderTrace.emit("background.enqueue", mode)
        worker.async {
            TutuChatRenderTrace.emit("background.worker.begin", mode)
            defer { TutuChatRenderTrace.emit("background.worker.end", mode) }
            guard gate.accepts(generation), self.lifecycle.accepts(epoch) else { return }
            do {
                let key = "background|\(mode)|\(scale)|\(size.width)|\(size.height)"
                let raster: TutuChatRaster
                if let cached = self.hit(key)?.pieces.first?.raster { raster = cached }
                else {
                    raster = try self.prepared().background.render(mode: mode, scale: scale, size: size)
                    self.insert(TutuChatMessageFrame(size: raster.rect.size,
                        pieces: [TutuChatTexturePiece(raster: raster, origin: .zero, bodySize: raster.rect.size)], lace: nil, isUser: false), key: key)
                }
                DispatchQueue.main.async { if gate.accepts(generation), self.lifecycle.accepts(epoch) { completion(.success(raster)) } }
            } catch {
                DispatchQueue.main.async { if gate.accepts(generation), self.lifecycle.accepts(epoch) { completion(.failure(error)) } }
            }
        }
    }
}

private extension TutuChatRequestGate {
    func advanceSnapshot() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
}

@MainActor private final class TutuChatMessageModel: ObservableObject {
    @Published var frame: TutuChatMessageFrame?
    @Published private(set) var lastSize: CGSize?
    @Published var error: String?
    private var currentRequest: TutuChatRequest?
    private var frameRequest: TutuChatRequest?
    private var isVisible = false
    private var viewportHeight: CGFloat = 0
    private let gate = TutuChatRequestGate()
    func visibility(nodeID: String, visible: Bool, viewportHeight: CGFloat) {
        isVisible = visible; self.viewportHeight = viewportHeight
        TutuChatRenderTrace.emit("row.visibility", nodeID, visible ? 1 : 0)
        #if DEBUG
        TutuChatDebugCounters.shared.row(nodeID: nodeID, visible: visible, hasFrame: frame != nil)
        #endif
        TutuChatRenderService.shared.visibility(nodeID: nodeID, visible: visible, viewportHeight: viewportHeight)
    }
    func viewportChanged(nodeID: String, height: CGFloat) {
        visibility(nodeID: nodeID, visible: isVisible, viewportHeight: height)
    }
    func load(_ request: TutuChatRequest, resuming: Bool = false) {
        TutuChatRenderTrace.emit("model.load", request.message.id)
        #if DEBUG
        TutuChatDebugCounters.shared.setActive(true)
        #endif
        let now = CACurrentMediaTime()
        if resuming { TutuChatAnimationTimeline.shared.resume(request.message, at: now) }
        TutuChatAnimationTimeline.shared.receive(request.message, at: now)
        error = nil
        if let previous = frameRequest, previous != request {
            let sameStream = (previous.streaming || request.streaming)
                && previous.message.id == request.message.id && previous.message.isRich == request.message.isRich
                && previous.message.isUser == request.message.isUser
                && previous.message.nativeHeight == request.message.nativeHeight
                && previous.width == request.width && previous.scale == request.scale && previous.mode == request.mode
                && previous.path.dropLast() == request.path.dropLast()
            if !sameStream { frame = nil; frameRequest = nil }
        }
        #if DEBUG
        TutuChatDebugCounters.shared.row(nodeID: request.message.id, visible: isVisible, hasFrame: frame != nil)
        #endif
        currentRequest = request
        let generation = gate.advance()
        let completed: (Result<TutuChatMessageFrame, Error>, Bool) -> Void = { [weak self] result, initial in
            TutuChatRenderTrace.emit("model.callback", request.message.id)
            guard let self else { return }
            let sameInitialShape = self.currentRequest.map {
                $0.message.id == request.message.id && $0.message.isRich == request.message.isRich
                    && $0.width == request.width && $0.scale == request.scale && $0.mode == request.mode
                    && $0.path == request.path && $0.streaming
            } ?? false
            guard self.gate.accepts(generation) || (initial && self.frame == nil && sameInitialShape) else { return }
            switch result {
            case .success(let frame):
                self.frame = frame; self.frameRequest = request; self.lastSize = frame.size; self.error = nil
                TutuChatRenderTrace.emit("model.frame", request.message.id, Double(frame.pieces.count))
                if !frame.isUser { TutuChatTimeline.shared.cardCreated(nodeID: request.message.id) }
            case .failure(let error):
                TutuChatRenderTrace.emit("model.error", request.message.id + "|" + error.localizedDescription)
                self.frame = nil; self.frameRequest = nil
                self.error = error.localizedDescription
            }
            #if DEBUG
            TutuChatDebugCounters.shared.row(nodeID: request.message.id, visible: self.isVisible, hasFrame: self.frame != nil)
            #endif
        }
        let service = TutuChatRenderService.shared
        service.visibility(nodeID: request.message.id, visible: isVisible, viewportHeight: viewportHeight)
        if let cached = service.cached(request) {
            service.cancel(gate: gate)
            completed(.success(cached), false)
            return
        }
        service.render(request, gate: gate, generation: generation, visible: isVisible, completion: completed)
    }
    func cancel(nodeID: String) {
        TutuChatRenderTrace.emit("model.cancel", nodeID)
        _ = gate.advance()
        let service = TutuChatRenderService.shared
        service.cancel(gate: gate)
        visibility(nodeID: nodeID, visible: false, viewportHeight: viewportHeight)
        currentRequest = nil; frameRequest = nil; frame = nil
        service.releaseStream(nodeID: nodeID)
    }
}

struct TutuChatMessageView<NativeContent: View, FallbackContent: View>: View {
    var message: TutuChatMessageSnapshot
    var isStreaming: Bool
    @ViewBuilder var nativeContent: () -> NativeContent
    @ViewBuilder var fallbackContent: () -> FallbackContent
    @Environment(\.tutuChatPath) private var path
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatViewportHeight) private var viewportHeight
    @StateObject private var model = TutuChatMessageModel()
    @State private var appeared = false
    @State private var rowVisible = false
    @State private var nativeHeight: CGFloat = 0
    @StateObject private var clock = TutuChatMessageClock()
    @State private var inputRise: CGFloat = 0
    private var entrance: TutuChatAnimationTimeline.Entry? {
        let value = TutuChatAnimationTimeline.shared.entries[message.id]
        return value?.settled == false ? value : nil
    }
    private var deadline: Double { entrance?.deadline ?? 0 }
    private var feltProgress: Double {
        guard message.isUser, let sentAt = entrance?.sentAt else { return 1 }
        return TutuChatAnimation.outCubic(TutuChatAnimation.span(clock.now, sentAt, sentAt + 0.62))
    }
    private var mode: String { TutuChatStyle.mode }
    private var request: TutuChatRequest {
        var message = message; message.nativeHeight = nativeHeight
        return TutuChatRequest(message: message, path: path, width: 268, scale: scale, mode: mode, streaming: isStreaming)
    }
    var body: some View {
        Group {
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    fallbackContent()
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.frame == nil, !message.isRich {
                Text(message.text)
                    .font(.body).foregroundStyle(TutuSkinPalette.tokens.textPrimary.color)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: model.lastSize?.height, alignment: .topLeading)
            } else {
                skinnedContent
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .background {
            if message.isUser, entrance != nil {
                TutuChatMessagePosition { inputRise = $0 }
            }
        }
        .onChange(of: deadline, initial: true) { _, deadline in clock.run(until: deadline) }
        .onAppear {
            TutuChatRenderTrace.emit("row.appear", message.id)
            appeared = true
            model.visibility(nodeID: message.id, visible: rowVisible, viewportHeight: viewportHeight ?? 0)
            if scenePhase == .active { model.load(request, resuming: true) }
            else { TutuChatAnimationTimeline.shared.settle(nodeID: message.id) }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            rowVisible = visible
            model.visibility(nodeID: message.id, visible: visible, viewportHeight: viewportHeight ?? 0)
        }
        .onChange(of: viewportHeight) { _, height in
            if appeared { model.viewportChanged(nodeID: message.id, height: height ?? 0) }
        }
        .onChange(of: request) { _, value in if appeared && scenePhase == .active { model.load(value) } }
        .onChange(of: scenePhase) { _, value in
            if value == .active, appeared {
                model.visibility(nodeID: message.id, visible: rowVisible, viewportHeight: viewportHeight ?? 0)
                model.load(request, resuming: true)
            }
            else if value == .background {
                model.cancel(nodeID: message.id); clock.stop()
                TutuChatAnimationTimeline.shared.settle(nodeID: message.id)
            }
        }
        .onDisappear {
            TutuChatRenderTrace.emit("row.disappear", message.id)
            appeared = false; rowVisible = false; model.cancel(nodeID: message.id); clock.stop()
            TutuChatAnimationTimeline.shared.settle(nodeID: message.id)
        }
        .accessibilityElement(children: message.isRich || model.error != nil ? .contain : .ignore)
        .accessibilityLabel(message.isRich || model.error != nil ? "" : message.text)
    }
    private var skinnedContent: some View {
        ZStack(alignment: .topLeading) {
            if let frame = model.frame { rendered(frame) }
            if message.isRich {
                let lift = message.isUser ? 0 : entrance?.cards.lift(index: 0, at: clock.now) ?? 0
                nativeContent()
                    .frame(width: message.isUser ? 214 : 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { value in
                        nativeHeight = value; TutuChatTimeline.shared.measured(nodeID: message.id, height: value)
                    }
                    .padding(.horizontal, message.isUser ? 16 : 24)
                    .padding(.vertical, message.isUser ? 10 : 16)
                    .offset(x: (message.isUser ? 14 : 0) + TutuChatAnimation.rounded(-2.5 * lift),
                            y: TutuChatAnimation.rounded(-7 * lift))
                    .foregroundStyle(model.frame == nil ? TutuSkinPalette.tokens.textPrimary.color
                                     : Color(red: 72 / 255, green: 33 / 255, blue: 42 / 255))
                    .opacity(model.frame == nil ? 1 : (message.isUser ? 1 : entrance?.cards.opacity(index: 0, at: clock.now) ?? 1))
            }
        }
        .frame(width: 268, height: model.frame?.size.height ?? model.lastSize?.height ?? max(48, nativeHeight + 32), alignment: .topLeading)
        .scaleEffect(message.isUser ? 0.7 + 0.3 * feltProgress : 1, anchor: .trailing)
        .offset(y: message.isUser ? inputRise * (1 - feltProgress) : 0)
        .opacity(message.isUser ? entrance?.sentAt.map {
            TutuChatAnimation.smooth(TutuChatAnimation.span(clock.now, $0, $0 + 0.18))
        } ?? 1 : 1)
    }
    private func rendered(_ frame: TutuChatMessageFrame) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let shadow = frame.laceShadow { texture(shadow) }
                if let lace = frame.lace { texture(lace) }
            }
            .modifier(TutuChatLaceReveal(percent: entrance?.laceAt.map {
                115 * TutuChatAnimation.inOut(TutuChatAnimation.span(clock.now, $0, $0 + 1.1)) - 15
            }))
            ForEach(frame.pieces.indices, id: \.self) { index in
                let piece = frame.pieces[index]
                let lift = !frame.isUser ? entrance?.cards.lift(index: index, at: clock.now) ?? 0 : 0
                ZStack(alignment: .topLeading) {
                    if lift > 0 {
                        TutuChatFallingShadow(nodeID: message.id, source: piece.raster, fallback: piece.shadow, lift: lift)
                    } else if let shadow = piece.shadow { texture(shadow) }
                    TutuChatTextureView(raster: piece.raster, revision: piece.revision, isVisible: rowVisible)
                        .frame(width: piece.raster.rect.width, height: piece.raster.rect.height)
                        .offset(x: piece.raster.rect.minX, y: piece.raster.rect.minY)
                    if let text = piece.feltText {
                        Text(text).font(.custom("PingFangSC-Regular", size: piece.emoji ? 23 : 15.5))
                            .tracking(TutuChatStyle.isCJK(text) ? 0.62 : 0)
                            .lineSpacing(TutuChatStyle.isCJK(text) ? 6.5 : 4)
                            .foregroundStyle(Color(red: 42 / 255, green: 34 / 255, blue: 31 / 255))
                            .frame(width: piece.bodySize.width - (piece.emoji ? 0 : 32), height: piece.bodySize.height - (piece.emoji ? 0 : 20), alignment: piece.emoji ? .center : .leading)
                            .padding(.horizontal, piece.emoji ? 0 : 16).padding(.vertical, piece.emoji ? 0 : 10)
                    }
                }
                .offset(x: piece.origin.x + TutuChatAnimation.rounded(-2.5 * lift),
                        y: piece.origin.y + TutuChatAnimation.rounded(-7 * lift))
                .opacity(!frame.isUser ? entrance?.cards.opacity(index: index, at: clock.now) ?? 1 : 1)
            }
        }
    }
    private func texture(_ raster: TutuChatRaster) -> some View {
        TutuChatTextureView(raster: raster, isVisible: rowVisible).frame(width: raster.rect.width, height: raster.rect.height)
            .offset(x: raster.rect.minX, y: raster.rect.minY)
    }
}


enum TutuChatStyle {
    static var active: Bool { SkinState.shared.active }
    static var mode: String {
        let hour = TutuClock.hour(for: SkinState.shared.timeOfDay)
        return hour >= 6 && hour < 17 ? "day" : hour >= 17 && hour < 19.5 ? "dusk" : "night"
    }
    static func isCJK(_ value: String) -> Bool { TutuChatContent.isCJK(value) }
    static func spacing(beforeUser: Bool, afterUser: Bool) -> CGFloat {
        TutuChatConversationLayout.gap(after: beforeUser ? .me : .turn, before: afterUser ? .me : .turn)
    }
}

@MainActor private final class TutuChatBackgroundModel: ObservableObject {
    @Published var raster: TutuChatRaster?
    @Published var error: String?
    private let gate = TutuChatRequestGate()
    func load(mode: String, scale: CGFloat, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let generation = gate.advance()
        if let final = TutuChatIntroPresentation.shared.finalBackground(mode: mode, scale: scale, size: size) {
            raster = final; error = nil; return
        }
        TutuChatRenderService.shared.background(mode: mode, scale: scale, size: size, gate: gate, generation: generation) { [weak self] result in
            switch result {
            case .success(let raster): self?.raster = raster; self?.error = nil
            case .failure(let error): self?.error = error.localizedDescription
            }
        }
    }
    func cancel() { _ = gate.advance(); raster = nil }
}

struct TutuChatBackgroundView: View {
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = TutuChatBackgroundModel()
    @State private var size: CGSize = .zero
    private var mode: String { TutuChatStyle.mode }
    var body: some View {
        GeometryReader { geometry in
            let intro = TutuChatIntroPresentation.shared
            if intro.active, !intro.preparing {
                TutuChatIntroSurface()
            } else if let raster = model.raster ?? intro.finalBackground(mode: mode, scale: scale, size: geometry.size) {
                TutuChatTextureView(raster: raster).frame(width: geometry.size.width, height: geometry.size.height)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .allowsHitTesting(false)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onAppear { model.load(mode: mode, scale: scale, size: size) }
        .onChange(of: size) { _, size in if scenePhase != .background { model.load(mode: mode, scale: scale, size: size) } }
        .onChange(of: mode) { _, mode in if scenePhase != .background { model.load(mode: mode, scale: scale, size: size) } }
        .onChange(of: mode) { _, _ in TutuChatIntroPresentation.shared.modeChanged() }
        .onChange(of: scale) { _, _ in if scenePhase != .background { model.load(mode: mode, scale: scale, size: size) } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            TutuChatRenderService.shared.trimCache()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.load(mode: mode, scale: scale, size: size) }
            else if phase == .background { model.cancel(); TutuChatRenderService.shared.release() }
        }
        .onDisappear {
            model.cancel(); TutuChatRenderService.shared.release()
            TutuChatIntroPresentation.shared.releaseFinalRaster()
        }
    }
}
struct TutuChatTableLight: View {
    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.translateBy(x: size.width * 0.08, y: size.height * 0.06)
            context.scaleBy(x: size.width * 1.30, y: size.height * 0.95)
            let bounds = CGRect(x: -0.08 / 1.30, y: -0.06 / 0.95, width: 1 / 1.30, height: 1 / 0.95)
            context.fill(Path(bounds), with: .radialGradient(Gradient(stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.28),
                .init(color: Color(red: 241 / 255, green: 240 / 255, blue: 238 / 255), location: 0.62),
                .init(color: Color(red: 226 / 255, green: 224 / 255, blue: 221 / 255), location: 1),
            ]), center: .zero, startRadius: 0, endRadius: 1))
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
        .opacity(TutuChatIntroPresentation.shared.phase.shadeOpacity)
    }
}

#endif
#endif
