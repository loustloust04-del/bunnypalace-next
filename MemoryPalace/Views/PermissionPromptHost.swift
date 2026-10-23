import SwiftUI

/// askOnce 弹卡的挂载点：body 里**显式读** `pendingRequest`，让 Observation 追踪到它——
/// 原来把读放在 `.sheet(item: Binding(get:))` 的 getter 里，macOS 上不触发重渲，卡永远不出、30s 超时判拒（沙箱 Phase 1 真机撞的）。
/// 零尺寸，挂在聊天根 view 的 `.background` 上。
struct PermissionPromptHost: View {
    var body: some View {
        // 显式读 = 订阅；对话里的审批卡在显示的那张不弹 sheet（粟粟 10-03），离开对话后 inline 变 false 再弹
        let pending = PermissionPromptCenter.shared.pendingRequest
        let req = pending?.inline == true ? nil : pending
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: Binding(
                get: { req },
                set: { newValue in
                    // 拖拽/点外面关闭 = 本次拒绝
                    if newValue == nil, let r = PermissionPromptCenter.shared.pendingRequest {
                        PermissionPromptCenter.shared.respond(to: r.id, allowed: false)
                    }
                }
            )) { r in
                PermissionPromptSheet(request: r)
            }
    }
}
