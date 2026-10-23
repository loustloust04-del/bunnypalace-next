#if os(macOS)
import SwiftUI
import AppKit

/// 点标题弹出的编程会话卡（plan-mac-code-mode-gaps §3，学 Otty 标题 popover）：名字直接改 / 摘要 / 工作目录 + 动作 / 时间 / 回聊天。
/// 挂在标题文字本身的 `.popover(arrowEdge: .bottom)` 上——以前是撑满整卡宽的 `Menu`，系统按钮框摆菜单，跑到右边
struct CodingSessionTitleCard: View {
    let meta: CodingSessionMeta
    let backTitle: String
    let onBack: () -> Void

    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    private var library: CodingSessionLibrary { .shared }
    private var original: String { CodingSessionFormat.title(meta, override: nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("会话名", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(commit)
                if library.state.titleOverride(meta.key) != nil {
                    Button {
                        name = original
                        commit()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(MacShellButton(width: 24, height: 24))
                    .help("回到原名「\(original)」")
                }
            }
            .padding(12)

            Text(CodingSessionFormat.summaryLine(meta))
                .font(.system(size: Theme.F.caption))
                .foregroundStyle(ShellStyle.secondaryText)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            divider

            if !meta.projectPath.isEmpty {
                Text("工作目录")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ShellStyle.mutedText)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                Label(meta.projectPath, systemImage: "folder")
                    .font(.system(size: Theme.F.caption, design: .monospaced))
                    .foregroundStyle(ShellStyle.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                row("复制路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meta.projectPath, forType: .string)
                }
                if meta.host.isEmpty {
                    row("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: meta.projectPath)])
                    }
                }
            }
            CodingSessionResumeItems(meta: meta, onError: { error = $0 })
                .menuStyle(.borderlessButton)
                .buttonStyle(CardRowStyle())
                .padding(.horizontal, 6)
            if let error {
                Text(error)
                    .font(.system(size: Theme.F.caption))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }

            divider

            Text("创建 \(CodingSessionFormat.absolute(meta.createdAt)) · 更新 \(CodingSessionFormat.absolute(meta.updatedAt))")
                .font(.system(size: 10))
                .foregroundStyle(ShellStyle.mutedText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            divider

            row(backTitle, symbol: "arrow.uturn.left", action: onBack)
                .padding(.bottom, 6)
        }
        .frame(width: 360)
        .onAppear { name = CodingSessionFormat.title(meta) }
        // 关卡时（点空处 / Esc）没按回车也保存，跟 Otty 一样
        .onDisappear(perform: commit)
    }

    private var divider: some View {
        Rectangle().fill(ShellStyle.hairline).frame(height: ShellStyle.hairlineWidth).padding(.horizontal, 10)
    }

    private func row(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(CardRowStyle())
        .padding(.horizontal, 6)
    }

    /// 改回原名 = 清掉改名（同列表行内改名）
    private func commit() {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = library.state.titleOverride(meta.key) ?? ""
        let next = text == original ? "" : text
        guard next != current, !(next.isEmpty && current.isEmpty) else { return }
        library.rename(meta.key, to: next)
    }
}

/// 卡里一行一行的动作：整行可点、悬停淡底（Otty 那张卡的行感）
private struct CardRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(ShellStyle.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(ShellStyle.controlFill(selected: false, hovered: hovered, pressed: configuration.isPressed),
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
#endif
