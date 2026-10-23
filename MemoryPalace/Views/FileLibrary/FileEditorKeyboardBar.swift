import SwiftUI
import UniformTypeIdentifiers

/// md 编辑 sheet 的查找 / 替换输入框焦点（顶部查找条和 iPhone 浮动查找条共用）
enum FileEditorFindField: Hashable {
    case find
    case replace
}

/// 「…」→ 分享：把当前编辑中的内容写成同名临时文件再交给系统分享
struct FileEditorShareFile: Transferable {
    let name: String
    let content: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("file-editor-share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(item.name)
            try item.content.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

#if os(iOS)
import UIKit

/// iPhone 键盘浮条（plan-file-editor-sheet §②）。不是 inputAccessoryView：sheet 的
/// `safeAreaInset(edge: .bottom)` 托着它，SwiftUI 键盘避让让它贴在键盘上沿、跟键盘一起起落。
/// 收着 = 左「Aa」+ 右「收键盘」；点 Aa 展开一条可横滑的格式键，最左 × 收回。
struct FileEditorFormatBar: View {
    let style: FileEditorKeyboardBarStyle
    @Binding var expanded: Bool
    /// 源码模式没有格式命令，只留「收键盘」
    var showsFormatKeys = true
    let onCommand: (String) -> Void
    let onDismissKeyboard: () -> Void

    /// 本地镜像：@AppStorage 的写入不吃 withAnimation 事务（10-02 实机「没有收起放出的弹性」），
    /// 动画跟这个走，偏好另外写回
    @State private var isExpanded: Bool
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        style: FileEditorKeyboardBarStyle,
        expanded: Binding<Bool>,
        showsFormatKeys: Bool = true,
        onCommand: @escaping (String) -> Void,
        onDismissKeyboard: @escaping () -> Void
    ) {
        self.style = style
        self._expanded = expanded
        self.showsFormatKeys = showsFormatKeys
        self.onCommand = onCommand
        self.onDismissKeyboard = onDismissKeyboard
        self._isExpanded = State(initialValue: expanded.wrappedValue)
    }

    private enum Glyph {
        case text(String, Font)
        case symbol(String)
    }

    private struct FormatKey: Identifiable {
        let id: String
        let glyph: Glyph
        let label: String
        /// 这颗键前面画一道分隔
        var groupStart = false
    }

    /// 键序照小样：H · 粗 · 斜 · 链接 · 代码 | 列表 · 编号 · 待办 · 引用 | 代码块 · 表格
    private static let keys: [FormatKey] = [
        FormatKey(id: "headingCycle", glyph: .text("H", .system(size: 15, weight: .semibold)), label: "标题"),
        FormatKey(id: "bold", glyph: .text("B", .system(size: 15, weight: .heavy)), label: "粗体"),
        FormatKey(id: "italic", glyph: .text("I", .system(size: 16, weight: .medium, design: .serif).italic()), label: "斜体"),
        FormatKey(id: "link", glyph: .symbol("link"), label: "链接"),
        FormatKey(id: "code", glyph: .symbol("chevron.left.forwardslash.chevron.right"), label: "行内代码"),
        FormatKey(id: "bulletList", glyph: .symbol("list.bullet"), label: "无序列表", groupStart: true),
        FormatKey(id: "orderedList", glyph: .symbol("list.number"), label: "有序列表"),
        FormatKey(id: "taskList", glyph: .symbol("checklist"), label: "待办"),
        FormatKey(id: "quote", glyph: .symbol("quote.opening"), label: "引用"),
        FormatKey(id: "codeBlock", glyph: .symbol("curlybraces"), label: "代码块", groupStart: true),
        FormatKey(id: "table", glyph: .symbol("tablecells"), label: "表格")
    ]

    /// 尺寸跟 app 普通玻璃钮统一（page1 顶栏：44pt 圆、图标 15 semibold、textSecondary）
    private static let barHeight: CGFloat = 44
    private static let keySize: CGFloat = 36
    private static let keycapSize: CGFloat = 34

    /// 临界阻尼不过冲：0.75 时胶囊↔圆的玻璃形变回弹太大（10-03 粟粟「弹的很诡异」）
    private var toggleAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1.0)
    }

    /// 格式条从左边 Aa 的位置长出来 / 缩回去
    private var stripTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .leading).combined(with: .opacity)
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if showsFormatKeys && isExpanded {
                    strip
                        .transition(stripTransition)
                } else {
                    if showsFormatKeys {
                        collapsedKey(id: "format", label: "展开格式键") {
                            Text("Aa").font(.system(size: 15, weight: .semibold))
                        } action: {
                            setExpanded(true)
                        }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                }
                collapsedKey(id: "dismiss", label: "收起键盘") {
                    Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15, weight: .semibold))
                } action: {
                    onDismissKeyboard()
                }
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .animation(toggleAnimation, value: isExpanded)
        .onChange(of: expanded) { _, newValue in
            if newValue != isExpanded { isExpanded = newValue }
        }
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(toggleAnimation) { isExpanded = value }
        expanded = value
    }

    // MARK: 收着时的单颗键（Aa / 收键盘）

    /// 玻璃 = page1 那颗 44pt 圆。不用 Button：`.buttonStyle(.glass)` 的尺寸由 controlSize 定、压不到 44；
    /// glassEffect + `.plain` Button 又吞点击（feedback_ios26_glass_button）——非 Button 视图 + onTapGesture 没这个坑
    @ViewBuilder
    private func collapsedKey<Label: View>(
        id: String,
        label: String,
        @ViewBuilder content: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        let glyph = content().foregroundStyle(Theme.textSecondary)
        switch style {
        case .glass:
            glyph
                .frame(width: Self.barHeight, height: Self.barHeight)
                .contentShape(Circle())
                .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                .glassEffectID(id, in: glassNamespace)
                .onTapGesture(perform: action)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, action)
        case .keycap:
            Button(action: action) {
                glyph
                    .frame(width: Self.barHeight, height: Self.keycapSize)
                    .background(keycapBackground)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    // MARK: 展开的一条

    @ViewBuilder
    private var strip: some View {
        let scroller = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: style == .glass ? 2 : 6) {
                key(glyph: .symbol("xmark"), label: "收起格式键") {
                    setExpanded(false)
                }
                separator
                ForEach(Self.keys) { k in
                    if k.groupStart { separator }
                    key(glyph: k.glyph, label: k.label) { onCommand(k.id) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.trailing, 20)
        }
        .mask(fadeMask)

        switch style {
        case .glass:
            scroller
                .frame(height: Self.barHeight)
                .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule)
                .glassEffectID("format", in: glassNamespace)
        case .keycap:
            scroller.frame(height: Self.barHeight)
        }
    }

    /// 横滑区里的键一律 onTapGesture（横向 ScrollView 会吞 Button 的点按）；
    /// SwiftUI 手势不抢 WKWebView 的第一响应者，键盘不会掉
    private func key(glyph: Glyph, label: String, action: @escaping () -> Void) -> some View {
        glyphView(glyph)
            .frame(width: style == .glass ? Self.keySize : Self.keycapSize, height: style == .glass ? Self.keySize : Self.keycapSize)
            .background {
                if style == .keycap { keycapBackground }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }

    @ViewBuilder
    private func glyphView(_ glyph: Glyph) -> some View {
        switch glyph {
        case .text(let s, let font):
            Text(s).font(font)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 15, weight: .medium))
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.textPrimary.opacity(0.16))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 3)
    }

    private var keycapBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Theme.mainBg)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.textPrimary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.textPrimary.opacity(0.14), lineWidth: 1)
            )
    }

    /// 右端渐隐：提示还能往右滑
    private var fadeMask: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 26)
        }
    }
}

/// iPhone 浮动查找条：和格式浮条同一个位置（互斥），键盘收起时浮在底部安全区上方。
/// 查找并替换 = 下面多一行「替换为」+ 替换 / 全部
struct FileEditorFloatingFindBar: View {
    @Binding var findText: String
    @Binding var replaceText: String
    let showsReplace: Bool
    let status: String
    let hasMatches: Bool
    var focus: FocusState<FileEditorFindField?>.Binding
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                    TextField("查找", text: $findText)
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused(focus, equals: .find)
                        .onSubmit(onNext)
                    Text(status)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                    navButton("chevron.up", label: "上一个", action: onPrevious)
                    navButton("chevron.down", label: "下一个", action: onNext)
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .frame(height: 48)
                .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)

                Button(action: onDone) {
                    Text("完成")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }

            if showsReplace {
                HStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                        TextField("替换为", text: $replaceText)
                            .font(.system(size: 16))
                            .foregroundColor(Theme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused(focus, equals: .replace)
                            .onSubmit(onReplace)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)

                    replaceButton("替换", action: onReplace)
                    replaceButton("全部", action: onReplaceAll)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func navButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(hasMatches ? Theme.textSecondary : Theme.textMuted.opacity(0.5))
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasMatches)
        .accessibilityLabel(label)
    }

    private func replaceButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(hasMatches ? Theme.textSecondary : Theme.textMuted.opacity(0.5))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!hasMatches)
    }
}
#endif
