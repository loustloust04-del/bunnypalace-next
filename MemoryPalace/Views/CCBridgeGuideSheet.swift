import SwiftUI

#if os(macOS)

/// cc-bridge 连接说明文档阅读器（macOS only，v1.1+）。
///
/// 内容是 `cc-bridge-guide.md` 静态 markdown，bundle 在 .app/Contents/Resources/。
/// onAppear 时动态替换：
/// - `{MCP_SERVER_PATH}` → Bundle.main 里 mcp-server-arm64 的真实路径
/// - `{HUB_PORT}` → CCHubProcess.shared.port（hub 没启动时保留原文 + caption 提醒）
struct CCBridgeGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hub = CCHubProcess.shared
    @State private var markdown: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 自定义顶栏（替代 NavigationStack + toolbar，避开 macOS sheet 关闭闪烁）
            HStack {
                Text("Claude Code 连接说明")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .foregroundColor(Theme.branchIndicator)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.sidebarBg)

            Divider()

            ScrollView {
                // 说明书不属于任何楼层：profileId 空 → 浮条不出「存成问题」（收生词照常）；
                // 正文里的 `$X` 不做 ticker 链接化（R-MD #1）
                ChatMarkdownView(text: markdown, linkifyTickers: false)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.mainBg)
        }
        .frame(width: 720, height: 640)
        .onAppear(perform: loadMarkdown)
        // hub 启动后端口变化时重新替换 {HUB_PORT}
        .onChange(of: hub.port) { _, _ in loadMarkdown() }
    }

    private func loadMarkdown() {
        guard let url = Bundle.main.url(forResource: "cc-bridge-guide", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            markdown = "# 加载失败\n\n找不到 `cc-bridge-guide.md`——可能是 build 配置漏了 resources。"
            return
        }
        var s = raw
        // {MCP_SERVER_PATH} → 真实 bundle 路径（按当前架构选 arm64/x64）
        let mcpPath = CCBridgeGuideSheet.bundledMCPServerPath()
        s = s.replacingOccurrences(of: "{MCP_SERVER_PATH}", with: mcpPath)
        // {HUB_PORT} → 真实端口（hub 没启动时保留字面值方便用户看到占位）
        if let port = hub.port {
            s = s.replacingOccurrences(of: "{HUB_PORT}", with: "\(port)")
        }
        markdown = s
    }

    private static func bundledMCPServerPath() -> String {
        #if arch(arm64)
        let name = "mcp-server-arm64"
        #else
        let name = "mcp-server-x64"
        #endif
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url.path
        }
        return "/Applications/记忆花园.app/Contents/Resources/\(name)"
    }
}

#endif
