#if os(iOS)
import SwiftUI
import SwiftData
import UIKit

// MARK: - [Bunny] 一起听的配套
// 1. BunnyMusicStore：Song 的独立 SwiftData 容器（Application Support/Bunny/music.store），不改上游 fullSchema / 全量备份指纹。
// 2. 大肥兔里的 HapticService / LivelineReporter 在上游不存在：给最小实现。

enum BunnyMusicStore {
    static let container: ModelContainer = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bunny", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration("BunnyMusic", url: dir.appendingPathComponent("music.store"))
        do { return try ModelContainer(for: Song.self, configurations: config) }
        catch { fatalError("BunnyMusicStore: \(error)") }
    }()
}

final class HapticService {
    static let shared = HapticService()
    func longPress() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

/// 大肥兔「Caelum 知道她在干嘛」的活动线：POST /api/liveline（新兔改走 Authorization 头）
enum LivelineReporter {
    enum Kind: String { case music, reading, app }
    static let enabledKey = "liveline.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static func report(_ kind: Kind, _ text: String) {
        guard isEnabled, BunnyGateway.isConfigured else { return }
        Task { _ = try? await BunnyGateway.post("/api/liveline", json: ["kind": kind.rawValue, "text": text]) }
    }
}

/// 桌面「音乐」App 的入口：给音乐面板挂上兔兔自己的容器
struct BunnyMusicAppView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    var body: some View {
        MusicPanelView(profileId: profileManager?.currentProfile.id ?? "").modelContainer(BunnyMusicStore.container)
    }
}
#endif
