//
//  SandboxStatusBanner.swift
//  顶部状态级小提示：沙箱正在解压 / 启动 / 失败时露一条；就绪后有命令在跑时提醒别切走。
//
//  只订阅 SandboxState.phase。首启解压 ~300-600ms，多数时候一闪而过；
//  真正会停留的是失败态（要让粟粟看见到底哪一步崩了，而不是「怎么没反应」）。
//
//  「命令在跑，别切走」不是可有可无的装饰：iOS 后端切后台会被整个挂起，命令**原地冻结**
//  （T4 真机实测，见 ISHShellBackend 头注释），提示条是用户唯一的事前警告。
//
//  订阅陷阱：`RunCommandMonitor` 是 @Observable，**必须在 body 里显式读 `monitor.running`**
//  才建立依赖（Phase 1 askOnce 卡就栽在只从 Binding getter 里读不算订阅）。
//

import SwiftUI

struct SandboxStatusBanner: View {
    @State private var state = SandboxState.shared
    @State private var monitor = RunCommandMonitor.shared

    var body: some View {
        // 显式读这两个属性 = 建立 @Observable 依赖，少读一个就不刷新
        if let content = SandboxBanner.content(phase: state.phase, runningCount: monitor.running.count) {
            HStack(spacing: 8) {
                switch content.icon {
                case .failure:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                case .running:
                    Image(systemName: "terminal")
                        .foregroundStyle(Theme.branchIndicator)
                case .progress:
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.branchIndicator)
                }
                Text(content.text)
                    .font(.system(size: Theme.F.body))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Theme.assistantBubble)
                    .shadow(color: Theme.cardShadow, radius: Theme.cardShadowRadius)
            )
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension View {
    /// 挂在 iOS 根视图上：沙箱非就绪 / 有命令在跑时顶部浮一条提示，不占布局
    func sandboxStatusOverlay() -> some View {
        overlay(alignment: .top) {
            SandboxStatusBanner()
                .animation(.easeInOut(duration: 0.2), value: SandboxState.shared.phase)
                .animation(.easeInOut(duration: 0.2), value: RunCommandMonitor.shared.running.count)
        }
    }
}
