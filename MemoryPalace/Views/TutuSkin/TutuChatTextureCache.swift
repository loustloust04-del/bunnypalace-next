#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Metal
/// Opt-in measurement only. Normal app builds erase calls and do not evaluate payloads.
enum TutuChatRenderTrace {
    #if TUTU_SCROLL_TRACE
    static var observer: ((String, String, Double) -> Void)?
    static var textureObserver: ((MTLTexture) -> Void)?
    @inline(__always) static func allocated(_ texture: MTLTexture) { textureObserver?(texture) }
    @inline(__always) static func emit(_ event: String, _ identity: @autoclosure () -> String = "", _ value: @autoclosure () -> Double = 0) {
        observer?(event, identity(), value())
    }
    #else
    @inline(__always) static func emit(_ event: String, _ identity: @autoclosure () -> String = "", _ value: @autoclosure () -> Double = 0) {}
    @inline(__always) static func allocated(_ texture: MTLTexture) {}
    #endif
}

struct TutuChatTexturePiece {
    var raster: TutuChatRaster
    var shadow: TutuChatRaster? = nil
    var origin: CGPoint
    var feltText: String? = nil
    var bodySize: CGSize
    var emoji = false
    var revision: UInt64 = 0
}
struct TutuChatMessageFrame {
    var size: CGSize
    var pieces: [TutuChatTexturePiece]
    var lace: TutuChatRaster?
    var laceShadow: TutuChatRaster? = nil
    var isUser: Bool
    var rasters: [TutuChatRaster] {
        pieces.flatMap { [$0.raster] + ($0.shadow.map { [$0] } ?? []) }
            + (lace.map { [$0] } ?? []) + (laceShadow.map { [$0] } ?? [])
    }
    var allocatedBytes: Int {
        var seen = Set<ObjectIdentifier>()
        return rasters.reduce(0) { total, raster in
            seen.insert(ObjectIdentifier(raster.texture)).inserted ? total + raster.allocatedBytes : total
        }
    }
}
/// Thread-safe LRU. Visible views and GPU commands retain their own references outside this budget.
final class TutuChatTextureCache {
    struct Statistics {
        var allocatedBytes = 0
        var count = 0
        var hits = 0
        var misses = 0
        var evictions = 0
    }
    let limit: Int
    var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return counters
    }
    private let lock = NSLock()
    private var counters = Statistics()
    private var entries: [String: Entry] = [:]
    private var textures: [ObjectIdentifier: (references: Int, bytes: Int)] = [:]
    private var access: UInt64 = 0
    private let neighboringScreens: CGFloat
    private var visibleNodes = Set<String>()
    // Only currently visible anchors survive eviction of their cached frame.
    private var visibleRanges: [String: ClosedRange<CGFloat>] = [:]
    private var viewportHeight: CGFloat = 0
    private var visibleSpan: ClosedRange<CGFloat>?
    private var protectedWindow: ClosedRange<CGFloat>?
    private struct Entry {
        var frame: TutuChatMessageFrame
        var access: UInt64
        var nodeID: String?
        var range: ClosedRange<CGFloat>?
        var textureBytes: [ObjectIdentifier: Int]
    }
    init(limit: Int = 96 * 1024 * 1024) {
        self.limit = max(0, min(limit, 96 * 1024 * 1024))
        neighboringScreens = ProcessInfo.processInfo.physicalMemory >= 8 * 1024 * 1024 * 1024 ? 2 : 1
        TutuChatRenderTrace.emit("cache.limit", "", Double(self.limit))
        TutuChatRenderTrace.emit("cache.window.screens", "", Double(neighboringScreens))
        #if DEBUG
        TutuChatDebugCounters.shared.configure(screens: Int(neighboringScreens))
        #endif
    }
    func value(forKey key: String) -> TutuChatMessageFrame? {
        lock.lock()
        guard var entry = entries[key] else {
            counters.misses += 1
            lock.unlock()
            TutuChatRenderTrace.emit("cache.miss", key)
            return nil
        }
        counters.hits += 1; access &+= 1; entry.access = access; entries[key] = entry
        lock.unlock()
        TutuChatRenderTrace.emit("cache.hit", key)
        return entry.frame
    }
    func setVisible(nodeID: String, visible: Bool, viewportHeight: CGFloat) {
        lock.lock()
        var changed = false
        if viewportHeight.isFinite, viewportHeight > 0, self.viewportHeight != viewportHeight {
            self.viewportHeight = viewportHeight
            changed = true
        }
        if visible {
            if visibleNodes.insert(nodeID).inserted {
                changed = true
                var newest: Entry?
                for entry in entries.values where entry.nodeID == nodeID && entry.range != nil {
                    if newest == nil || entry.access > newest!.access { newest = entry }
                }
                visibleRanges[nodeID] = newest?.range
            }
        } else if visibleNodes.remove(nodeID) != nil {
            visibleRanges.removeValue(forKey: nodeID)
            changed = true
        }
        if changed { updateWindowLocked() }
        let window = protectedWindow, anchors = visibleRanges.count
        lock.unlock()
        if changed { traceWindow(window, anchors: anchors) }
    }
    // Called only with lock held; no texture queries, GPU work or client callbacks.
    private func updateWindowLocked() {
        var lower: CGFloat?, upper: CGFloat?
        for range in visibleRanges.values {
            lower = min(lower ?? range.lowerBound, range.lowerBound)
            upper = max(upper ?? range.upperBound, range.upperBound)
        }
        if let lower, let upper {
            visibleSpan = lower...upper
            let margin = viewportHeight * neighboringScreens
            protectedWindow = (lower - margin)...(upper + margin)
        } else {
            visibleSpan = nil
            protectedWindow = nil
        }
    }
    private func traceWindow(_ window: ClosedRange<CGFloat>?, anchors: Int) {
        TutuChatRenderTrace.emit("cache.window.anchors", "canonical-layout", Double(anchors))
        if let window {
            TutuChatRenderTrace.emit("cache.window.lower", "canonical-layout", Double(window.lowerBound))
            TutuChatRenderTrace.emit("cache.window.upper", "canonical-layout", Double(window.upperBound))
        } else {
            TutuChatRenderTrace.emit("cache.window.cleared")
        }
    }
    private func rankLocked(_ entry: Entry) -> (tier: Int, distance: CGFloat) {
        guard entry.nodeID != nil, let range = entry.range else { return (0, 0) }
        let tier = protectedWindow.map { $0.overlaps(range) ? 2 : 1 } ?? 1
        guard let span = visibleSpan else { return (tier, 0) }
        return (tier, max(0, max(span.lowerBound - range.upperBound, range.lowerBound - span.upperBound)))
    }
    private func evictFirstLocked(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let left = rankLocked(lhs), right = rankLocked(rhs)
        if left.tier != right.tier { return left.tier < right.tier }
        if left.distance != right.distance { return left.distance > right.distance }
        return lhs.access < rhs.access
    }
    // Return bytes removed from the union of resident and incoming textures.
    @discardableResult private func removeLocked(_ key: String, incoming: [ObjectIdentifier: Int]) -> Int {
        guard let old = entries.removeValue(forKey: key) else { return 0 }
        var released = 0
        for id in old.textureBytes.keys {
            guard let texture = textures[id] else { continue }
            if texture.references == 1 {
                counters.allocatedBytes -= texture.bytes
                textures.removeValue(forKey: id)
                if incoming[id] == nil { released += texture.bytes }
            } else {
                textures[id] = (texture.references - 1, texture.bytes)
            }
        }
        counters.count = entries.count
        return released
    }
    func insert(_ frame: TutuChatMessageFrame, forKey key: String, nodeID: String? = nil,
                range: ClosedRange<CGFloat>? = nil) {
        // Query Metal allocation sizes before taking the shared metadata lock.
        var incoming: [ObjectIdentifier: Int] = [:]
        func record(_ raster: TutuChatRaster) {
            let id = ObjectIdentifier(raster.texture)
            if incoming[id] == nil { incoming[id] = raster.allocatedBytes }
        }
        for piece in frame.pieces {
            record(piece.raster)
            if let shadow = piece.shadow { record(shadow) }
        }
        if let lace = frame.lace { record(lace) }
        if let shadow = frame.laceShadow { record(shadow) }
        let frameBytes = incoming.values.reduce(0, +)
        #if TUTU_SCROLL_TRACE
        var evicted: [(key: String, tier: Int)] = []
        #endif
        lock.lock()
        let previous = entries[key]
        let resolvedNode = nodeID ?? previous?.nodeID
        let resolvedRange = range ?? previous?.range
        var windowChanged = false
        if let resolvedNode, let resolvedRange, visibleNodes.contains(resolvedNode),
           visibleRanges[resolvedNode] != resolvedRange {
            visibleRanges[resolvedNode] = resolvedRange
            updateWindowLocked()
            windowChanged = true
        }
        let window = protectedWindow, anchors = visibleRanges.count
        guard frameBytes <= limit else {
            lock.unlock()
            if windowChanged { traceWindow(window, anchors: anchors) }
            TutuChatRenderTrace.emit("cache.reject.oversized", key, Double(frameBytes))
            return
        }
        let existed = previous != nil
        removeLocked(key, incoming: incoming)
        let entry = Entry(frame: frame, access: access &+ 1, nodeID: resolvedNode,
                          range: resolvedRange, textureBytes: incoming)
        var requiredBytes = counters.allocatedBytes
        for (id, bytes) in incoming where textures[id] == nil { requiredBytes += bytes }
        var retained = true
        while requiredBytes > limit {
            guard let victim = entries.min(by: { evictFirstLocked($0.value, $1.value) }),
                  evictFirstLocked(victim.value, entry) else {
                retained = false
                break
            }
            #if TUTU_SCROLL_TRACE
            evicted.append((victim.key, rankLocked(victim.value).tier))
            #endif
            requiredBytes -= removeLocked(victim.key, incoming: incoming)
            counters.evictions += 1
        }
        if retained {
            for (id, bytes) in incoming {
                if let texture = textures[id] { textures[id] = (texture.references + 1, texture.bytes) }
                else { textures[id] = (1, bytes); counters.allocatedBytes += bytes }
            }
            access &+= 1
            entries[key] = entry
            counters.count = entries.count
        }
        let bytes = counters.allocatedBytes
        lock.unlock()
        if windowChanged { traceWindow(window, anchors: anchors) }
        TutuChatRenderTrace.emit("cache.insert.key-existed", key, existed ? 1 : 0)
        if existed { TutuChatRenderTrace.emit("cache.remove", key) }
        #if TUTU_SCROLL_TRACE
        for victim in evicted {
            TutuChatRenderTrace.emit("cache.evict.budget", victim.key)
            let reason = victim.tier == 0 ? "submaterial" : victim.tier == 1 ? "outside-window" : "protected-distance-lru"
            TutuChatRenderTrace.emit("cache.evict.\(reason)", victim.key)
            TutuChatRenderTrace.emit("cache.remove", victim.key)
        }
        #endif
        if !retained { TutuChatRenderTrace.emit("cache.reject.budget-priority", key) }
        TutuChatRenderTrace.emit("cache.bytes", key, Double(bytes))
    }
    func removeAll() {
        lock.lock()
        let bytes = counters.allocatedBytes
        entries.removeAll(); textures.removeAll(); counters.allocatedBytes = 0; counters.count = 0
        visibleNodes.removeAll(); visibleRanges.removeAll(); viewportHeight = 0
        visibleSpan = nil; protectedWindow = nil
        lock.unlock()
        TutuChatRenderTrace.emit("cache.removeAll", "explicit-release", Double(bytes))
        traceWindow(nil, anchors: 0)
    }
}
#endif
#endif
