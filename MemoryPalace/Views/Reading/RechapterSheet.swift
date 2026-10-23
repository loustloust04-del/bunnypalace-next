import SwiftUI
import SwiftData

/// 书房长按一本 txt 书 →「重新分章」：先预览按新规则切出来的目录，再决定原地重切还是另存新书（P4-C 限定版）。
struct RechapterSheet: View {
    let entry: BookEntry
    let profileId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var preview: BookRechapter.Preview?
    @State private var error: String?
    @State private var working = false
    @State private var confirmInPlace = false

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    content(preview)
                } else if let error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("按新规则切一遍…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.sidebarBg)
            .navigationTitle("重新分章")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(working)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .task {
            do {
                preview = try await BookRechapter.preview(safeName: entry.id, profileId: profileId, context: modelContext)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func content(_ p: BookRechapter.Preview) -> some View {
        List {
            Section {
                row("怎么切的", p.result.method.title)
                row("章数", "现在 \(p.oldTitles.count) 章 → \(p.result.chapters.count) 章")
                row("最长一章", "\(p.longest) 字")
            } footer: {
                if p.unchanged { Text("按新规则切出来和现在一样，不用重新分。") }
            }
            .listRowBackground(Theme.mainBg)

            Section {
                if p.blocked {
                    Text(blockedText(p))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        run { _ = try await BookRechapter.saveAsNewBook(p, safeName: entry.id, profileId: profileId, context: modelContext) }
                    } label: {
                        Label("另存一本重新分章的新书", systemImage: "plus.square.on.square")
                    }
                    .disabled(working || p.unchanged)
                } else {
                    Button {
                        confirmInPlace = true
                    } label: {
                        Label("按这个目录重新分章", systemImage: "scissors")
                    }
                    .disabled(working || p.unchanged)
                }
            } footer: {
                Text(p.blocked
                     ? "新书名后面加「（重新分章）」，原来这本和它的批注原样留着。"
                     : "会先把现在的章节打包放进文件库的「书房备份」，读到的位置会换算到新目录里。")
            }
            .listRowBackground(Theme.mainBg)

            Section("新目录") {
                ForEach(Array(p.result.chapters.prefix(200).enumerated()), id: \.offset) { i, ch in
                    HStack(spacing: 8) {
                        Text("\(i + 1).")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 34, alignment: .trailing)
                        Text(ch.title)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if ch.auto {
                            Text("自动分段").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        }
                        Text("\(ch.content.count) 字")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                if p.result.chapters.count > 200 {
                    Text("…还有 \(p.result.chapters.count - 200) 章").foregroundStyle(Theme.textMuted)
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("按新目录重新分章？", isPresented: $confirmInPlace, titleVisibility: .visible) {
            Button("重新分章") {
                run { try await BookRechapter.applyInPlace(p, safeName: entry.id, profileId: profileId, context: modelContext) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现在的章节会先打包到「书房备份」。")
        }
        .overlay {
            if working { ProgressView().controlSize(.large) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary)
        }
        .font(.system(size: 14))
    }

    private func blockedText(_ p: BookRechapter.Preview) -> String {
        var parts: [String] = []
        if p.notes > 0 { parts.append("\(p.notes) 条划线 / 批注") }
        if p.bookmarks > 0 { parts.append("\(p.bookmarks) 个书签") }
        if p.vocab > 0 { parts.append("\(p.vocab) 个生词出自这本") }
        return "这本有 " + parts.joined(separator: "、") + "，原地重新分章会让它们对不上。"
    }

    private func run(_ job: @escaping @MainActor () async throws -> Void) {
        working = true
        Task { @MainActor in
            do {
                try await job()
                ToastCenter.shared.show("已重新分章")
                dismiss()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
            working = false
        }
    }
}
