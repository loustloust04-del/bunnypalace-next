import Foundation

/// Isolated replays override implicit preference reads; normal sends retain `.standard`.
/// TaskLocal does not cross Task.detached / GCD. RecallTool.execute, RecallFullText.fetch,
/// and CatalogRecallIndexer queues must not add implicit `.standard` preference reads.
public enum MemoryReadEnvironment {}

public extension MemoryReadEnvironment {
    final class Preferences: @unchecked Sendable {
        public let value: UserDefaults
        public init(_ value: UserDefaults) { self.value = value }
    }
    @TaskLocal static var preferences: Preferences?
    static var defaults: UserDefaults { preferences?.value ?? .standard }
}
