import Foundation

/// Agora（中庭）总闸：真机 E2E 验收（Phase 1F 手工矩阵）通过前**默认关**。
/// 关 = 侧栏无中庭入口、不自动连接 /agora（hub 侧 executor 不受此闸控制，
/// 但已有派发白名单保护日常 session）。开关在设置-开发调试，改后重启 App 生效。
enum AgoraFeatureGate {
    static let key = "agoraEnabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
}
