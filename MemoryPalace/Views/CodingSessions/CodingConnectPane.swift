#if os(macOS)
import AppKit
import SwiftUI

/// 接入（W-N N6-d，Wake Settings → Connect）：包里带的 `mp-code` 让 Claude Code / Codex / Cursor 这些编程 agent 只读地查这台 Mac 上的
/// 编程会话。只放状态与动作——路径、每家一个复制按钮（原地变「已复制」1.6 s）、放进 PATH 的一条命令；复制出去的文本与 `mp-code setup` 同源（`CodingCLI`）
struct CodingConnectPane: View {
    let onDone: () -> Void
    @State private var copiedID: String?

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let hint: String
        let button: String
        let text: String
    }

    /// 包里那份（`mp-code setup` 报的同一个文件）
    static var binaryURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(CodingCLI.binaryName)")
    }

    /// 三家片段 + PATH 命令：文本全部取自 CodingCLI，提示与按钮文案是界面中文。已经装在 `…/bin` 里就不给 PATH 那行
    static func items(binary: String) -> [Item] {
        let hints = ["Claude Code": "在终端里运行一次", "Codex": "加进 ~/.codex/config.toml", "Cursor": "合并进 ~/.cursor/mcp.json"]
        var out = CodingCLI.setupSnippets(binary: binary).map { snippet in
            Item(id: snippet.client, title: snippet.client, hint: hints[snippet.client] ?? snippet.hint,
                 button: snippet.client == "Claude Code" ? "复制命令" : "复制配置", text: snippet.text)
        }
        if let command = CodingCLI.pathCommand(binary: binary) {
            out.append(Item(id: "path", title: "放进 PATH", hint: "在终端里运行一次（要输管理员密码），之后任何终端都能直接敲 mp-code",
                            button: "复制命令", text: command))
        }
        return out
    }

    var body: some View {
        let binary = Self.binaryURL.path
        let installed = FileManager.default.isExecutableFile(atPath: binary)
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    card { pathRow(binary: binary, installed: installed) }
                    if installed {
                        card {
                            ForEach(Array(Self.items(binary: binary).enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().opacity(0.5) }
                                itemRow(item)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("接入")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("让 Claude Code、Codex、Cursor 这些编程 agent 通过 mp-code 查这台 Mac 上的编程会话。只读，改不了任何会话。")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 12)
            Button("完成", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.textMuted.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.textMuted.opacity(0.18), lineWidth: 0.5))
    }

    private func pathRow(binary: String, installed: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(CodingCLI.binaryName)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                Text(installed ? binary : "包里没有找到 mp-code")
                    .font(.system(size: Theme.F.caption, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if installed {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Self.binaryURL])
                } label: {
                    Image(systemName: "folder")
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")
                copyButton(id: "binary", title: "复制路径", text: binary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func itemRow(_ item: Item) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                Text(item.hint)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            copyButton(id: item.id, title: item.button, text: item.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func copyButton(id: String, title: String, text: String) -> some View {
        let copied = copiedID == id
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedID = id
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if copiedID == id { copiedID = nil }
            }
        } label: {
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: Theme.F.caption, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(text)
    }
}
#endif
