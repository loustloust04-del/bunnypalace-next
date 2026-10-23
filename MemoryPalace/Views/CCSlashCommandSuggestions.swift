import SwiftUI

/// cc-bridge L3：斜杠命令 autocomplete 候选数据模型 + 浮板 view。
///
/// 输入框 text 开头是 / 时，浮板显示与 prefix 匹配的候选；tap 候选把
/// "命令名 + 占位符" 插入输入框（不立刻发，粟粟要求保留编辑参数的空间）。
/// 候选清单 hardcode v1；标 ⚠️ 的命令是 CC 端会弹自己 TUI 的，
/// MP 远程发出去 CC 会等用户在 tmux 操作，提醒粟粟"需 attach tmux"。

struct CCSlashCommand: Identifiable {
    var id: String { name }
    let name: String           // "/clear"
    let placeholder: String    // " <name>" 或 ""
    let description: String
    /// 真发后 CC 会弹自己的 TUI，需要在 tmux 里完成交互
    let needsTmux: Bool

    static let all: [CCSlashCommand] = [
        .init(name: "/clear",       placeholder: "",                description: "清空 session 上下文",                 needsTmux: false),
        .init(name: "/compact",     placeholder: "",                description: "压缩对话历史",                         needsTmux: false),
        .init(name: "/cost",        placeholder: "",                description: "显示 token 消耗",                      needsTmux: false),
        .init(name: "/model",       placeholder: " <model-name>",   description: "切 model（带参才不需 tmux）",          needsTmux: false),
        .init(name: "/help",        placeholder: "",                description: "显示帮助",                             needsTmux: false),
        .init(name: "/init",        placeholder: "",                description: "生成 CLAUDE.md 骨架",                  needsTmux: false),
        .init(name: "/add-dir",     placeholder: " <path>",         description: "添加可读目录",                         needsTmux: false),
        .init(name: "/mcp",         placeholder: "",                description: "MCP 状态 — 弹菜单需 tmux",             needsTmux: true),
        .init(name: "/resume",      placeholder: "",                description: "切 session — 弹菜单需 tmux",           needsTmux: true),
        .init(name: "/agents",      placeholder: "",                description: "子 agent — 弹菜单需 tmux",             needsTmux: true),
        .init(name: "/memory",      placeholder: "",                description: "编辑 memory — 弹编辑器需 tmux",        needsTmux: true),
        .init(name: "/permissions", placeholder: "",                description: "权限设置 — 弹菜单需 tmux",             needsTmux: true),
        .init(name: "/quit",        placeholder: "",                description: "退出 CC 进程，谨慎",                needsTmux: false),
    ]
}

struct CCSlashCommandSuggestions: View {
    /// 当前输入框内容（用来 prefix filter）
    let prefix: String
    /// tap 候选 → 把 "命令名 + 占位符 + 空格" 插入到输入框
    var onPick: (String) -> Void

    private static let badgeColor = Color(red: 0.22, green: 0.94, blue: 0.49)

    private var candidates: [CCSlashCommand] { Self.candidates(for: prefix) }

    /// 显示哪些候选：case-insensitive prefix 匹配；prefix 为单 / 时全部显示。
    #if PERSONAL_APPS
    /// `susuos` 开头的永远不进推荐（plan-death-scale：暗号不能被推荐出来）
    #endif
    static func candidates(for prefix: String, in all: [CCSlashCommand] = CCSlashCommand.all) -> [CCSlashCommand] {
        let pool = all.filter { !isHidden($0.name) }
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if p == "/" || p.isEmpty { return pool }
        // 用第一段（空格之前）作为 prefix；用户已经在打参数时就不再列了
        let head = p.split(separator: " ").first.map(String.init) ?? p
        return pool.filter { $0.name.lowercased().hasPrefix(head) }
    }

    static func isHidden(_ name: String) -> Bool {
        #if PERSONAL_APPS
        let bare = name.drop { $0 == "/" }
        return bare.lowercased().hasPrefix("susuos")
        #else
        return false
        #endif
    }

    var body: some View {
        let cs = candidates
        if cs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cs.prefix(6))) { cmd in
                    Button(action: { onPick(cmd.name + cmd.placeholder) }) {
                        HStack(spacing: 8) {
                            Text(cmd.name)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(Self.badgeColor)
                            Text(cmd.description)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if cmd.needsTmux || cmd.name == "/quit" {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if cmd.id != cs.prefix(6).last?.id {
                        Divider().opacity(0.15)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Self.badgeColor.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        }
    }
}
