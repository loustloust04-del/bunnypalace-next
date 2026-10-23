import Foundation
import SwiftData

@Model
final class MemoryNote {
    #if os(iOS)
    #Index<MemoryNote>([\.profileId])
    #endif

    var id: UUID = UUID()
    var content: String
    var profileId: String
    var createdAt: Date
    var updatedAt: Date
    var source: String        // "auto" or "manual"
    var isActive: Bool        // whether to inject into system prompt

    init(content: String, profileId: String, source: String = "manual", isActive: Bool = true) {
        self.content = content
        self.profileId = profileId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.source = source
        self.isActive = isActive
    }
}
