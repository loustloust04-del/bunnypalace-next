import SwiftUI
import SwiftData

/// 画板（粟粟 10-11 定 A「笔筒」，docs/design-page1-画板UI.html）：sheet 弹出，原生工具栏（✕ / 纸 / 撤销重做 / ✓），
/// 画布卡片，底下一排画出来的笔（选中的往上冒，竖线分三组），右边尺子、颜色圈、三档粗细。
/// `document` 非 nil = 「继续画」。保存回调给透明底裁好边的 PNG 和画稿数据。
struct DrawingBoardView: View {
    var document: DrawingDocument? = nil
    let onSave: (_ png: Data, _ document: Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: DrawingBoardModel?
    /// 画布尺寸要在托盘已占位后量：真模型建好前托盘先用这个占位模型撑起同样的高度
    @State private var placeholder = DrawingBoardModel(canvasSize: CGSize(width: 1, height: 1))
    @State private var confirmDiscard = false
    @State private var showPalette = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Group {
                        if let model { canvas(model, in: geo.size) } else { Color.clear }
                    }
                    .onAppear { makeModel(geo.size) }
                    // sheet 弹上来的过程中可用高度还在变：新画布没落笔前，尺寸稳住 0.15s 就重量一次，落笔后定死
                    .task(id: geo.size) {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, document == nil, let m = model, !m.canUndo, !m.canRedo, m.isEmpty,
                              abs(m.canvasSize.width - geo.size.width) > 1 || abs(m.canvasSize.height - geo.size.height) > 1 else { return }
                        makeModel(geo.size)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                tray(model ?? placeholder)
                    .allowsHitTesting(model != nil)
            }
            .background(Theme.mainBg.ignoresSafeArea())
            .toolbar { toolbar }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(width: 860, height: 760)
        #endif
        .confirmationDialog("不保存就关掉？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("不保存", role: .destructive) { dismiss() }
            Button("继续画", role: .cancel) {}
        }
    }

    private func makeModel(_ size: CGSize) {
        let previous = model
        let m = DrawingBoardModel(canvasSize: CGSize(width: max(200, size.width), height: max(200, size.height)), document: document)
        if let previous {
            // 重量尺寸时把已经挑好的笔 / 颜色 / 纸带过去
            m.tool = previous.tool; m.waterColor = previous.waterColor; m.inkColor = previous.inkColor
            m.size = previous.size; m.water = previous.water; m.angle = previous.angle; m.paper = previous.paper
        }
        model = m
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                if model?.canUndo == true { confirmDiscard = true } else { dismiss() }
            } label: { Image(systemName: "xmark") }
            .accessibilityLabel("关闭")
        }
        if let model {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("纸", selection: Binding(get: { model.paper }, set: { model.paper = $0 })) {
                        ForEach(PaperKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(model.paper.title, systemImage: "doc.plaintext").labelStyle(.titleAndIcon)
                }
                .accessibilityIdentifier("drawing-paper")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .accessibilityLabel("撤销")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .accessibilityLabel("重做")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { save(model) } label: { Image(systemName: "checkmark") }
                    .tint(Theme.branchIndicator)
                    .disabled(model.isEmpty || model.isRestoring)
                    .accessibilityLabel("保存")
                    .accessibilityIdentifier("drawing-save")
            }
        }
    }

    private func save(_ model: DrawingBoardModel) {
        Task {
            // 最后一笔水彩可能还在晕开，等它落到颜料层再导
            await model.settle()
            guard let out = model.export() else { return }
            onSave(out.png, out.document)
            dismiss()
        }
    }

    // MARK: 画布

    private func canvas(_ model: DrawingBoardModel, in avail: CGSize) -> some View {
        let magnet = model.paper == .magnet
        let chrome: CGFloat = magnet ? 42 : 0
        let cs = model.canvasSize
        let fit = min(1, avail.width / (cs.width + chrome), avail.height / (cs.height + chrome))
        return ZStack {
            if let paper = model.paperImage {
                Image(decorative: paper, scale: BrushEngine.scale).resizable()
            }
            PaintCanvasRepresentable(model: model)
            #if os(macOS)
            if let kept = model.keptPencilImage {
                Image(decorative: kept, scale: BrushEngine.scale).resizable().allowsHitTesting(false)
            }
            #endif
            if model.isRestoring { ProgressView().controlSize(.large) }
        }
        .frame(width: cs.width, height: cs.height)
        // 换了模型（新画布重量尺寸）就换一套底下的 UIKit 画布
        .id(ObjectIdentifier(model))
        .clipShape(RoundedRectangle(cornerRadius: magnet ? 10 : 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: magnet ? 10 : 20, style: .continuous).stroke(.black.opacity(magnet ? 0 : 0.06), lineWidth: 0.5))
        .modifier(MagnetShell(on: magnet))
        .scaleEffect(fit)
        .frame(width: avail.width, height: avail.height)
        .accessibilityIdentifier("drawing-canvas")
    }

    // MARK: 笔筒

    private func tray(_ model: DrawingBoardModel) -> some View {
        let tools = model.settings.tools + BoardTool.available.filter(\.isFixed)
        return VStack(spacing: 2) {
            HStack(alignment: .bottom, spacing: 6) {
                ZStack(alignment: .bottom) {
                    // 搁笔的台子
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [.white, Color(red: 0.965, green: 0.945, blue: 0.918)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: Color(red: 0.24, green: 0.16, blue: 0.08).opacity(0.07), radius: 4, y: 2)
                        .frame(height: 46)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(Array(tools.enumerated()), id: \.element) { i, tool in
                                if i > 0, tools[i - 1].group != tool.group {
                                    Rectangle().fill(Theme.textMuted.opacity(0.3)).frame(width: 0.5, height: 40).padding(.horizontal, 4).padding(.bottom, 4)
                                }
                                penButton(tool, model: model)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
                .frame(height: 110, alignment: .bottom)
                side(model)
            }
            .padding(.horizontal, 10)
            Text(model.tool.title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, 6)
        }
        .padding(.top, 6)
    }

    private func penButton(_ tool: BoardTool, model: DrawingBoardModel) -> some View {
        let on = model.tool == tool
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { model.tool = tool }
        } label: {
            PenIllustration(tool: tool, tip: Color(brushHex: tool == .watercolor ? model.waterColor : model.inkColor))
                .frame(width: 26, height: 90)
                .frame(width: 32)
                .offset(y: on ? 0 : 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func side(_ model: DrawingBoardModel) -> some View {
        VStack(spacing: 9) {
            #if os(iOS)
            Button { model.rulerOn.toggle() } label: {
                Image(systemName: "ruler")
                    .font(.system(size: 15))
                    .frame(width: 36, height: 30)
                    .background(Capsule().fill(model.rulerOn ? Theme.accent : Theme.textMuted.opacity(0.1)))
                    .foregroundStyle(model.rulerOn ? Theme.branchIndicator : Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("尺子")
            .accessibilityAddTraits(model.rulerOn ? .isSelected : [])
            #endif
            Button { showPalette = true } label: {
                Circle()
                    .fill(model.tool == .eraser || model.tool == .lasso ? Theme.textMuted.opacity(0.25) : Color(brushHex: model.activeColor))
                    .padding(3)
                    .background(Circle().fill(.white))
                    .padding(3)
                    .background(Circle().fill(AngularGradient(colors: [Color(red: 0.9, green: 0.54, blue: 0.54), Color(red: 0.91, green: 0.73, blue: 0.54),
                                                                       Color(red: 0.65, green: 0.81, blue: 0.6), Color(red: 0.56, green: 0.76, blue: 0.75),
                                                                       Color(red: 0.64, green: 0.6, blue: 0.82), Color(red: 0.9, green: 0.54, blue: 0.54)],
                                                              center: .center)))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(model.tool == .eraser || model.tool == .lasso)
            .accessibilityLabel("颜色")
            .popover(isPresented: $showPalette) { palette(model) }
            HStack(spacing: 5) {
                ForEach(Array(BoardTool.sizes.enumerated()), id: \.offset) { i, s in
                    Circle()
                        .fill(Theme.textPrimary.opacity(model.size == s ? 0.9 : 0.3))
                        .frame(width: CGFloat(6 + i * 4), height: CGFloat(6 + i * 4))
                        .frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { model.size = s }
                        .accessibilityLabel(["细", "中", "粗"][i])
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func palette(_ model: DrawingBoardModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 6), spacing: 10) {
                ForEach(model.palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(brushHex: hex))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().stroke(Theme.textPrimary, lineWidth: model.activeColor == hex ? 2 : 0))
                        .onTapGesture { model.activeColor = hex }
                        .accessibilityLabel("颜色 \(hex)")
                        .accessibilityAddTraits(model.activeColor == hex ? .isSelected : [])
                }
            }
            if model.tool == .watercolor {
                labeledSlider("水量", value: Binding(get: { model.water }, set: { model.water = $0 }), range: 0...1)
            } else if model.tool == .nib {
                labeledSlider("笔尖角", value: Binding(get: { model.angle }, set: { model.angle = $0 }), range: 0...90)
            }
        }
        .padding(16)
        .frame(width: 260)
        #if os(iOS)
        .presentationCompactAdaptation(.popover)
        #endif
    }

    private func labeledSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Slider(value: value, in: range).tint(Theme.branchIndicator)
        }
    }
}

/// 磁性画板那张纸：原来的粉紫壳 + 青绿内框（去掉了调试调色板）
private struct MagnetShell: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.66, green: 0.82, blue: 0.81)))
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.80, green: 0.66, blue: 0.73), Color(red: 0.76, green: 0.61, blue: 0.69)],
                                         startPoint: .top, endPoint: .bottom)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        } else {
            content
        }
    }
}

/// 弹画板：sheet（粟粟 10-11）。画画时下拉不关（会和往下画打架），要点 ✕
extension View {
    func drawingBoard(isPresented: Binding<Bool>, document: DrawingDocument? = nil,
                      onSave: @escaping (_ png: Data, _ document: Data) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DrawingBoardView(document: document, onSave: onSave)
                .interactiveDismissDisabled()
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }

    /// 「继续画」：assetId 有值就带着它的画稿开画板，保存覆盖原贴纸
    func continueDrawing(assetId: Binding<UUID?>, profileId: String?, stickerVM: StickerViewModel,
                         context: ModelContext) -> some View {
        let shown = Binding(get: { assetId.wrappedValue != nil }, set: { if !$0 { assetId.wrappedValue = nil } })
        let doc = assetId.wrappedValue.flatMap { id in profileId.flatMap { StickerFileManager.loadDrawing(id: id, profileId: $0) } }
        return drawingBoard(isPresented: shown, document: doc) { png, data in
            guard let id = assetId.wrappedValue, let pid = profileId else { return }
            stickerVM.saveDrawing(png: png, document: data, assetId: id, profileId: pid, context: context)
        }
    }
}
