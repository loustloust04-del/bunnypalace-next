import SwiftUI

/// 便利贴原地编辑（docs/plan-page1-note-drawing.md §E，小样 docs/design-page1-笔刷与便利贴.html）：
/// 背景压暗，那张纸放大摆在中间直接打字，纸上方一条浮条切样式 / 颜色 / 字体；点空白处保存收起。
struct NoteEditorView: View {
    let onDone: (_ text: String, _ spec: NoteSpec) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var spec: NoteSpec
    @State private var text: String
    @State private var shown = false
    @FocusState private var focused: Bool

    init(spec: NoteSpec, text: String, onDone: @escaping (_ text: String, _ spec: NoteSpec) -> Void) {
        _spec = State(initialValue: spec)
        _text = State(initialValue: text)
        self.onDone = onDone
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(shown ? 0.28 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { finish() }
                .accessibilityLabel("完成")
                .accessibilityAddTraits(.isButton)
            VStack(spacing: 16) {
                bar
                NoteView(spec: spec, editing: $text, width: 250, focus: $focused)
                    .accessibilityIdentifier("note-editor-paper")
                    .scaleEffect(shown ? 1 : 0.7)
                    .rotationEffect(.degrees(shown ? -1 : -4))
            }
            .padding(.top, 24)
            .padding(.horizontal, 16)
            .opacity(shown ? 1 : 0)
        }
        #if os(macOS)
        .frame(width: 460, height: 560)
        #endif
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { shown = true }
            focused = true
        }
    }

    /// 不带系统转场地打开（iOS fullScreenCover 默认从底下滑上来，和「原地放大」打架）
    static func present(_ set: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, set)
    }

    private func finish() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onDone(t, spec) }
        dismiss()
    }

    // MARK: 浮条

    private var bar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(NoteKind.allCases) { kind in
                        chip(kind.title, on: spec.kind == kind) {
                            let keep = kind.colors.contains(spec.color ?? "") ? spec.color : nil
                            spec = NoteSpec(kind: kind, color: keep, font: spec.font)
                        }
                    }
                }
            }
            if !spec.kind.colors.isEmpty {
                HStack(spacing: 10) {
                    ForEach(spec.kind.colors, id: \.self) { hex in
                        Circle()
                            .fill(Color(brushHex: hex))
                            .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 0.5))
                            .frame(width: 26, height: 26)
                            .padding(2.5)
                            .overlay(Circle().stroke(Theme.textPrimary, lineWidth: spec.color == hex ? 2 : 0))
                            .onTapGesture { spec.color = hex }
                            .accessibilityLabel("颜色 \(hex)")
                            .accessibilityAddTraits(spec.color == hex ? .isSelected : [])
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(NoteFont.allCases) { f in
                        chip(f.title, font: f.font(14), on: spec.font == f) { spec.font = f }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private func chip(_ title: String, font: Font = .system(size: 13), on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(on ? Theme.accent : Theme.textMuted.opacity(0.1)))
                .overlay(Capsule().stroke(on ? Theme.branchIndicator : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension View {
    /// 弹便利贴编辑：iOS 透明全屏盖在对话上（纸原地放大），mac sheet。
    /// 打开时用 `NoteEditorView.present { flag = true }` 关掉系统的上滑转场，只留纸自己的放大
    func noteEditor(isPresented: Binding<Bool>, spec: NoteSpec, text: String,
                    onDone: @escaping (_ text: String, _ spec: NoteSpec) -> Void) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            NoteEditorView(spec: spec, text: text, onDone: onDone)
                .presentationBackground(.clear)
        }
        #else
        sheet(isPresented: isPresented) { NoteEditorView(spec: spec, text: text, onDone: onDone) }
        #endif
    }
}
