#if PERSONAL_APPS
#if os(iOS)
import SwiftUI
import Observation

/// Display-only memoization. MessageNode has no general content revision (cardEditedAt
/// only covers web-card edits), and ChatDisplaySnapshot only caches decoded segments.
/// Observation supplies our content revision without hashing/comparing the full body.
@MainActor
final class TutuChatSnapshotCache {
    struct Configuration: Equatable {
        var scripts: [RegexScript]
        var userName: String
        var assistantName: String
        var recallMode: String
    }

    @MainActor struct Context {
        let cache: TutuChatSnapshotCache
        let configuration: Configuration
        let version: UInt64

        func snapshot(for node: MessageNode, pacer: StreamPacer? = nil) -> TutuChatMessageSnapshot {
            cache.snapshot(for: node, context: self, pacer: pacer)
        }
    }

    /// onChange runs synchronously before the model mutation, not in a queued Task:
    /// even a body evaluated before the next actor turn cannot hit the old revision.
    private final class Revision: @unchecked Sendable {
        private let lock = NSLock()
        private var current: UInt64
        init(_ version: UInt64) { current = version }
        func invalidate() { lock.lock(); current &+= 1; lock.unlock() }
        var version: UInt64 { lock.lock(); defer { lock.unlock() }; return current }
    }

    private struct Key: Hashable {
        var nodeID: String
        var streaming: Bool
    }
    private struct Entry {
        var nodeIdentity: ObjectIdentifier
        var pacerIdentity: ObjectIdentifier?
        var contentVersion: UInt64
        var configurationVersion: UInt64
        var revision: Revision
        var snapshot: TutuChatMessageSnapshot
    }

    private var configuration: Configuration?
    private var configurationVersion: UInt64 = 0
    private var contentVersion: UInt64 = 0
    private var scope = ""
    private var entries: [Key: Entry] = [:]
    private(set) var constructionCount = 0

    func context(scripts: [RegexScript], userName: String, assistantName: String,
                 scope: String) -> Context {
        if self.scope != scope {
            entries.removeAll(keepingCapacity: true)
            self.scope = scope
        }
        let next = Configuration(scripts: scripts, userName: userName,
                                 assistantName: assistantName,
                                 recallMode: DisclosureKind.recall.mode.rawValue)
        if configuration != next {
            configuration = next
            configurationVersion &+= 1
        }
        return Context(cache: self, configuration: next, version: configurationVersion)
    }

    private func snapshot(for node: MessageNode, context: Context,
                          pacer: StreamPacer?) -> TutuChatMessageSnapshot {
        // Read the tracked getters on warm hits too: each SwiftUI evaluation must
        // retain its model dependencies. No scan, hash, clean, JSON decode or regex.
        Self.readDependencies(node, pacer: pacer)
        let key = Key(nodeID: node.id, streaming: pacer != nil)
        let identity = ObjectIdentifier(node)
        let pacerIdentity = pacer.map(ObjectIdentifier.init)
        if let entry = entries[key], entry.nodeIdentity == identity,
           entry.pacerIdentity == pacerIdentity,
           entry.configurationVersion == context.version,
           entry.revision.version == entry.contentVersion {
            return entry.snapshot
        }
        contentVersion &+= 1
        let revision = Revision(contentVersion)
        let snapshot = withObservationTracking {
            Self.readDependencies(node, pacer: pacer)
            return TutuChatMessageSnapshot.make(
                node: node, scripts: context.configuration.scripts,
                userName: context.configuration.userName,
                assistantName: context.configuration.assistantName,
                streamingText: pacer?.shown)
        } onChange: {
            revision.invalidate()
        }
        constructionCount += 1
        entries[key] = Entry(nodeIdentity: identity, pacerIdentity: pacerIdentity,
                             contentVersion: contentVersion,
                             configurationVersion: context.version,
                             revision: revision, snapshot: snapshot)
        return snapshot
    }

    private static func readDependencies(_ node: MessageNode, pacer: StreamPacer?) {
        _ = node.role
        _ = node.content
        _ = node.contentType
        _ = node.segmentsData
        _ = node.recallHitsData
        _ = pacer?.shown
    }
}

private struct TutuChatSnapshotContextKey: EnvironmentKey {
    static let defaultValue: TutuChatSnapshotCache.Context? = nil
}

extension EnvironmentValues {
    var tutuChatSnapshotContext: TutuChatSnapshotCache.Context? {
        get { self[TutuChatSnapshotContextKey.self] }
        set { self[TutuChatSnapshotContextKey.self] = newValue }
    }
}
#endif
#endif
