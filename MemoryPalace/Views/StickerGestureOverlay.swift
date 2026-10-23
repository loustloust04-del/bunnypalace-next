#if os(iOS)
import SwiftUI
import UIKit
import SwiftData

// MARK: - 单指专�� Pan（第二根手指到来立即取消）

private class SingleFingerPanGesture: UIPanGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let before = state.rawValue
        super.touchesBegan(touches, with: event)
        let active = activeTouchCount(event)
        PROBE("[PROBE 贴纸 pan.touchesBegan] touches=\(touches.count) allTouches=\(event.allTouches?.count ?? -1) active=\(active) stateBefore=\(before) stateAfterSuper=\(state.rawValue)")
        // 只在 pan 还没识别为 pan（.possible）时双指 fail，让 pinch/rotate 接管。
        // 一旦 pan 已 .began（用户明确单指拖），容忍第二指误触（手掌 / 另一根手指
        // 意外触屏），pan 继续。修"时灵时不灵"——粟粟实测第一次单指拖会被无意识
        // 第二指触摸 active>1 强制 .failed 杀掉。
        if state == .possible && active > 1 {
            state = .failed
            PROBE("[PROBE 贴纸 pan.touchesBegan] → setting state=.failed (still .possible, active>1)")
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        let before = state.rawValue
        super.touchesMoved(touches, with: event)
        let active = activeTouchCount(event)
        PROBE("[PROBE 贴纸 pan.touchesMoved] touches=\(touches.count) allTouches=\(event.allTouches?.count ?? -1) active=\(active) stateBefore=\(before) stateAfterSuper=\(state.rawValue)")
        // 同 touchesBegan：只在 .possible 时 fail，已 .began/.changed 容忍误触
        if state == .possible && active > 1 {
            state = .failed
            PROBE("[PROBE 贴纸 pan.touchesMoved] → setting state=.failed (still .possible, active>1)")
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        PROBE("[PROBE 贴纸 pan.touchesEnded] touches=\(touches.count) state=\(state.rawValue)")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        PROBE("[PROBE 贴纸 pan.touchesCancelled] touches=\(touches.count) state=\(state.rawValue)")
    }

    private func activeTouchCount(_ event: UIEvent) -> Int {
        event.allTouches?.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }.count ?? 0
    }
}

// MARK: - 画布级统一手势层

struct StickerCanvasGestureOverlay: UIViewRepresentable {
    var stickerVM: StickerViewModel
    var modelContext: ModelContext
    var editModeStartTime: Date

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let c = context.coordinator

        // 单指拖拽
        let pan = SingleFingerPanGesture(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = c
        view.addGestureRecognizer(pan)

        // 双指缩放
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = c
        view.addGestureRecognizer(pinch)

        // 双指旋转
        let rotate = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.handleRotate(_:)))
        rotate.delegate = c
        view.addGestureRecognizer(rotate)

        // 单击（选中 / 取消）
        let singleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleSingleTap(_:)))
        view.addGestureRecognizer(singleTap)

        // 双击（编辑便签）
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        singleTap.require(toFail: doubleTap)

        // 双指双击（撤回）
        let twoFingerDoubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTwoFingerDoubleTap))
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(twoFingerDoubleTap)

        // 双指触摸即选中（不等 pinch/rotate 识别，手指落下就浮起）
        let twoFingerTouch = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleTwoFingerTouch(_:)))
        twoFingerTouch.minimumPressDuration = 0
        twoFingerTouch.numberOfTouchesRequired = 2
        twoFingerTouch.delegate = c
        view.addGestureRecognizer(twoFingerTouch)

        // 长按弹出原生 context menu（和非编辑模式的 .contextMenu 一样的效果）
        let contextMenu = UIContextMenuInteraction(delegate: c)
        view.addInteraction(contextMenu)

        // 进入编辑模式时已有选中贴纸 → 延迟后自动落下
        DispatchQueue.main.async {
            context.coordinator.scheduleInitialDeselect()

            // [PROBE 贴纸 makeUIView] superview 链 + 祖先 UIScrollView 状态
            PROBE("[PROBE 贴纸 makeUIView] view.frame=\(view.frame) isUserInteractionEnabled=\(view.isUserInteractionEnabled) isMultipleTouchEnabled=\(view.isMultipleTouchEnabled)")
            var node: UIView? = view.superview
            var depth = 0
            while let n = node, depth < 10 {
                PROBE("[PROBE 贴纸 makeUIView]   ancestor[\(depth)] \(type(of: n)) frame=\(n.frame) isUIE=\(n.isUserInteractionEnabled)")
                if let sv = n as? UIScrollView {
                    PROBE("[PROBE 贴纸 makeUIView]     UIScrollView: isScrollEnabled=\(sv.isScrollEnabled) canCancelContentTouches=\(sv.canCancelContentTouches) delaysContentTouches=\(sv.delaysContentTouches)")
                    PROBE("[PROBE 贴纸 makeUIView]     panGR: isEnabled=\(sv.panGestureRecognizer.isEnabled) state=\(sv.panGestureRecognizer.state.rawValue) cancelsTouchesInView=\(sv.panGestureRecognizer.cancelsTouchesInView)")
                    if let grs = sv.gestureRecognizers {
                        for (i, gr) in grs.enumerated() {
                            PROBE("[PROBE 贴纸 makeUIView]       gr[\(i)]=\(type(of: gr)) enabled=\(gr.isEnabled) state=\(gr.state.rawValue)")
                        }
                    }
                }
                node = n.superview
                depth += 1
            }
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        PROBE("[PROBE 贴纸 updateUIView] frame=\(uiView.frame) superview=\(String(describing: type(of: uiView.superview)))")
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
        var parent: StickerCanvasGestureOverlay
        private var isDragging = false
        private var isPinching = false
        private var isRotating = false
        private var isShowingContextMenu = false

        private var didHandleInitialSelection = false

        init(parent: StickerCanvasGestureOverlay) { self.parent = parent }

        /// overlay 刚出现时，如果已有选中贴纸（长按进编辑模式选中的），延迟落下
        func scheduleInitialDeselect() {
            guard !didHandleInitialSelection else { return }
            didHandleInitialSelection = true
            guard vm.selectedPlacedStickerId != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.deselectIfIdle()
            }
        }

        /// 所有手势结束后自动取消选中（贴纸"落回桌面"）
        private func deselectIfIdle() {
            guard !isDragging, !isPinching, !isRotating, !isShowingContextMenu else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self,
                      !self.isDragging, !self.isPinching, !self.isRotating, !self.isShowingContextMenu else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                    self.vm.selectedPlacedStickerId = nil
                }
            }
        }

        private var vm: StickerViewModel { parent.stickerVM }

        // MARK: Hit Testing

        private func stickerAt(_ point: CGPoint) -> PlacedSticker? {
            let sizes = vm.stickerSizes
            for sticker in vm.placedStickers.sorted(by: { $0.zIndex > $1.zIndex }) {
                let size = sizes[sticker.id] ?? CGSize(width: 80, height: 80)
                let w = size.width * sticker.scale
                let h = size.height * sticker.scale
                let hitW = max(w, 44)
                let hitH = max(h, 44)
                let rect = CGRect(
                    x: sticker.positionX - hitW / 2,
                    y: sticker.positionY - hitH / 2,
                    width: hitW, height: hitH
                )
                if rect.contains(point) { return sticker }
            }
            return nil
        }

        private func isPointOnSelectedSticker(_ point: CGPoint) -> Bool {
            guard let id = vm.selectedPlacedStickerId,
                  let sticker = vm.placedStickers.first(where: { $0.id == id }) else { return false }
            let size = vm.stickerSizes[id] ?? CGSize(width: 80, height: 80)
            let w = size.width * sticker.scale
            let h = size.height * sticker.scale
            let hitW = max(w, 44) * 1.3
            let hitH = max(h, 44) * 1.3
            let rect = CGRect(
                x: sticker.positionX - hitW / 2,
                y: sticker.positionY - hitH / 2,
                width: hitW, height: hitH
            )
            return rect.contains(point)
        }

        private var selectedSticker: PlacedSticker? {
            guard let id = vm.selectedPlacedStickerId else { return nil }
            return vm.placedStickers.first { $0.id == id }
        }

        // MARK: Pan

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            PROBE("[PROBE 贴纸 handlePan] state=\(gesture.state.rawValue) numberOfTouches=\(gesture.numberOfTouches)")
            switch gesture.state {
            case .began:
                let loc = gesture.location(in: gesture.view)
                // 触摸点在贴纸上 → 自动选中并开始拖拽（不依赖预先 tap 选中）
                let sticker: PlacedSticker? = {
                    if let sel = selectedSticker, !sel.isLocked, isPointOnSelectedSticker(loc) { return sel }
                    if let hit = stickerAt(loc), !hit.isLocked {
                        vm.selectedPlacedStickerId = hit.id
                        return hit
                    }
                    return nil
                }()
                guard let sticker = sticker else { return }
                isDragging = true
                // 记录触摸点相对贴纸中心的偏移（物理扭矩用）
                vm.dragTouchOffset = CGPoint(
                    x: loc.x - sticker.positionX,
                    y: loc.y - sticker.positionY
                )
                vm.lastRotationDelta = 0
                if !vm.dragStarted {
                    vm.pushUndo(for: sticker)
                    vm.dragStarted = true
                }
            case .changed:
                guard isDragging, let sticker = selectedSticker else { return }
                let t = gesture.translation(in: gesture.view)

                // 平移
                sticker.positionX += t.x
                sticker.positionY += t.y

                // 扭矩：触摸偏离中心时，拖拽产生旋转
                let off = vm.dragTouchOffset
                let crossZ = off.x * t.y - off.y * t.x
                let size = vm.stickerSizes[sticker.id] ?? CGSize(width: 80, height: 80)
                let w = size.width * sticker.scale
                let h = size.height * sticker.scale
                let halfDiagSq = (w * w + h * h) / 4.0
                let torqueFactor: Double = 18.0
                let rotDelta = (crossZ / max(halfDiagSq, 1)) * torqueFactor
                sticker.rotation += rotDelta
                vm.lastRotationDelta = rotDelta

                gesture.setTranslation(.zero, in: gesture.view)
            case .ended, .cancelled:
                if isDragging, let sticker = selectedSticker {
                    // 短促惯性（纸在桌上摩擦大，不滑远）
                    let velocity = gesture.velocity(in: gesture.view)
                    let friction: CGFloat = 0.02
                    let slideX = velocity.x * friction
                    let slideY = velocity.y * friction
                    let angularInertia = vm.lastRotationDelta * 4.0

                    withAnimation(.interpolatingSpring(stiffness: 200, damping: 22)) {
                        sticker.positionX += slideX
                        sticker.positionY += slideY
                        sticker.rotation += angularInertia
                    }

                    // B20 修复：fling 累加后 clamp，防贴纸飞远撑虚高 ZStack
                    vm.clampStickerY(sticker)

                    vm.dragStarted = false
                    vm.lastRotationDelta = 0
                    try? parent.modelContext.save()
                    isDragging = false
                    deselectIfIdle()
                }
            default: break
            }
        }

        // MARK: Pinch

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            PROBE("[PROBE 贴纸 handlePinch] state=\(gesture.state.rawValue) scale=\(gesture.scale) numberOfTouches=\(gesture.numberOfTouches)")
            // 双指中点 hit test → 自动选中
            if selectedSticker == nil, let view = gesture.view {
                let mid = gesture.location(in: view)
                if let hit = stickerAt(mid), !hit.isLocked { vm.selectedPlacedStickerId = hit.id }
            }
            guard let sticker = selectedSticker, !sticker.isLocked else { return }
            switch gesture.state {
            case .began, .changed:
                isPinching = true
                if !vm.pinchStarted {
                    vm.pushUndo(for: sticker)
                    vm.gestureStartScale = sticker.scale
                    vm.gestureStartRotation = sticker.rotation
                    vm.pinchStarted = true
                }
                sticker.scale = min(4.0, max(0.2, vm.gestureStartScale * gesture.scale))
            case .ended, .cancelled:
                vm.pinchStarted = false
                isPinching = false
                try? parent.modelContext.save()
                gesture.scale = 1.0
                deselectIfIdle()
            default: break
            }
        }

        // MARK: Rotation

        @objc func handleRotate(_ gesture: UIRotationGestureRecognizer) {
            PROBE("[PROBE 贴纸 handleRotate] state=\(gesture.state.rawValue) rotation=\(gesture.rotation) numberOfTouches=\(gesture.numberOfTouches)")
            // 双指中点 hit test → 自动选中
            if selectedSticker == nil, let view = gesture.view {
                let mid = gesture.location(in: view)
                if let hit = stickerAt(mid), !hit.isLocked { vm.selectedPlacedStickerId = hit.id }
            }
            guard let sticker = selectedSticker, !sticker.isLocked else { return }
            switch gesture.state {
            case .began, .changed:
                isRotating = true
                if !vm.pinchStarted {
                    vm.pushUndo(for: sticker)
                    vm.gestureStartScale = sticker.scale
                    vm.gestureStartRotation = sticker.rotation
                    vm.pinchStarted = true
                }
                sticker.rotation = vm.gestureStartRotation + gesture.rotation * 180 / .pi
            case .ended, .cancelled:
                vm.pinchStarted = false
                isRotating = false
                try? parent.modelContext.save()
                gesture.rotation = 0
                deselectIfIdle()
            default: break
            }
        }

        // MARK: Single Tap

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            PROBE("[PROBE 贴纸 handleSingleTap] state=\(gesture.state.rawValue) loc=\(gesture.location(in: gesture.view))")
            guard Date().timeIntervalSince(parent.editModeStartTime) > 0.4 else {
                PROBE("[PROBE 贴纸 handleSingleTap] guard editModeStartTime fail → return")
                return
            }
            let loc = gesture.location(in: gesture.view)
            if let sticker = stickerAt(loc) {
                // 短暂浮起 → 0.5s 后落回（视觉反馈，不持久选中）
                withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                    vm.selectedPlacedStickerId = sticker.id
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self,
                          self.vm.selectedPlacedStickerId == sticker.id,
                          !self.isDragging, !self.isPinching, !self.isRotating, !self.isShowingContextMenu else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                        self.vm.selectedPlacedStickerId = nil
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    vm.selectedPlacedStickerId = nil
                }
            }
        }

        // MARK: Double Tap

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            PROBE("[PROBE 贴纸 handleDoubleTap] state=\(gesture.state.rawValue)")
            let loc = gesture.location(in: gesture.view)
            if let sticker = stickerAt(loc), sticker.isNote, !sticker.isLocked {
                NoteEditorView.present { vm.editingNoteStickerId = sticker.id }
            }
        }

        // MARK: Two-Finger Double Tap

        @objc func handleTwoFingerDoubleTap() {
            vm.undo(context: parent.modelContext)
        }

        // MARK: Two-Finger Touch Down（双指一碰就选中，不等 pinch/rotate 识别）

        @objc func handleTwoFingerTouch(_ gesture: UILongPressGestureRecognizer) {
            PROBE("[PROBE 贴纸 handleTwoFingerTouch] state=\(gesture.state.rawValue) numberOfTouches=\(gesture.numberOfTouches)")
            switch gesture.state {
            case .began:
                if selectedSticker == nil, let view = gesture.view {
                    let mid = gesture.location(in: view)
                    if let hit = stickerAt(mid), !hit.isLocked {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                            vm.selectedPlacedStickerId = hit.id
                        }
                    }
                }
            case .ended, .cancelled:
                deselectIfIdle()
            default: break
            }
        }

        // MARK: Context Menu（长按弹出原生菜单）

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            // 防抖：进入编辑模式后 0.5s 内不弹菜单（防止长按进编辑 → 手指未抬 → 立刻弹菜单）
            guard Date().timeIntervalSince(parent.editModeStartTime) > 0.5 else { return nil }
            guard let sticker = stickerAt(location) else { return nil }

            // 选中该贴纸，标记菜单打开中
            isShowingContextMenu = true
            vm.selectedPlacedStickerId = sticker.id

            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self = self else { return nil }
                var actions: [UIMenuElement] = []

                if let assetId = sticker.stickerAssetId,
                   StickerFileManager.hasDrawing(id: assetId, profileId: sticker.profileId) {
                    actions.append(UIAction(title: "继续画", image: UIImage(systemName: "paintbrush.pointed")) { _ in
                        self.vm.continueDrawingAssetId = assetId
                    })
                }
                if sticker.isNote {
                    actions.append(UIAction(title: "编辑内容", image: UIImage(systemName: "square.and.pencil")) { _ in
                        NoteEditorView.present { self.vm.editingNoteStickerId = sticker.id }
                    })
                    actions.append(UIAction(title: "导出为图片", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                        self.vm.shareNoteAsPNG(content: sticker.noteContent ?? "", style: sticker.noteStyle ?? "yellow_square")
                    })
                }

                actions.append(UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                    self.vm.copySticker(sticker)
                })

                if self.vm.copiedSnapshot != nil {
                    actions.append(UIAction(title: "粘贴", image: UIImage(systemName: "doc.on.clipboard")) { _ in
                        self.vm.pasteSticker(
                            conversationId: sticker.conversationId,
                            nearPosition: CGPoint(x: sticker.positionX, y: sticker.positionY),
                            profileId: sticker.profileId,
                            context: self.parent.modelContext
                        )
                    })
                }

                if let assetId = sticker.stickerAssetId {
                    // 重命名（面 3.5 / G7，对齐 mac 右键菜单）：菜单构造时就捕获 assetId、不回读选中态
                    //（菜单消失后 deselectIfIdle 会清 selectedPlacedStickerId）；共同 alert 在 StickerCanvasLayer
                    actions.append(UIAction(title: "重命名", image: UIImage(systemName: "pencil")) { _ in
                        self.vm.renameText = self.vm.stickerAssets.first(where: { $0.id == assetId })?.name ?? ""
                        self.vm.renamingStickerId = assetId
                    })
                }

                actions.append(UIAction(
                    title: sticker.isLocked ? "解锁" : "锁定",
                    image: UIImage(systemName: sticker.isLocked ? "lock.open" : "lock")
                ) { _ in
                    self.vm.toggleLock(sticker, context: self.parent.modelContext)
                })

                actions.append(UIAction(title: "置于最前", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { _ in
                    self.vm.bringToFront(sticker, context: self.parent.modelContext)
                })
                actions.append(UIAction(title: "置于最后", image: UIImage(systemName: "square.3.layers.3d.bottom.filled")) { _ in
                    self.vm.sendToBack(sticker, context: self.parent.modelContext)
                })

                actions.append(UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.vm.removePlacedSticker(sticker, context: self.parent.modelContext)
                })

                let assetName = self.vm.stickerAssets.first(where: { $0.id == sticker.stickerAssetId })?.name
                let label = sticker.isNote ? "📝 便签" : "🎨 \(assetName ?? "贴纸")"
                return UIMenu(title: label, children: actions)
            }
        }

        // MARK: Context Menu Preview（只框贴纸，不框整个画布）

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            return makeStickerPreview(in: interaction.view)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
            return makeStickerPreview(in: interaction.view)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            animator?.addCompletion { [weak self] in
                guard let self = self else { return }
                self.isShowingContextMenu = false
                self.deselectIfIdle()
            } ?? {
                isShowingContextMenu = false
                deselectIfIdle()
            }()
        }

        private func makeStickerPreview(in view: UIView?) -> UITargetedPreview? {
            guard let view = view,
                  let sticker = selectedSticker else { return nil }
            // 1x1 透明 view + 空 shadow → 无黑雾、无大框
            let params = UIPreviewParameters()
            params.backgroundColor = .clear
            params.shadowPath = UIBezierPath()
            let dot = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            dot.backgroundColor = .clear
            let target = UIPreviewTarget(container: view, center: CGPoint(x: sticker.positionX, y: sticker.positionY))
            return UITargetedPreview(view: dot, parameters: params, target: target)
        }

        // MARK: Gesture Delegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // 双指手势互相允许同时识别（pinch + rotate + 双指触摸选中）
            let isMultiTouch = { (g: UIGestureRecognizer) -> Bool in
                g is UIPinchGestureRecognizer || g is UIRotationGestureRecognizer
                || (g is UILongPressGestureRecognizer && g.numberOfTouches >= 2)
            }
            let result: Bool
            if isMultiTouch(gestureRecognizer) || isMultiTouch(other) {
                result = true
            } else if String(describing: type(of: other)).contains("_UIRelationshipGestureRecognizer") ||
                      String(describing: type(of: gestureRecognizer)).contains("_UIRelationshipGestureRecognizer") {
                // [FIX 单指拖时灵时不灵] iOS 内部 _UIRelationshipGestureRecognizer 在
                // SwiftUI .onLongPressGesture 进编辑模式后停留 state=3 (.recognized/.ended)
                // 几秒，require-to-fail SingleFingerPanGesture，导致 pan 卡 .possible
                // 不能 .began（log 实测：state=3 时 pan 死，state=0 时 pan 活）。
                // 对它返回 simultaneously=true 解开阻塞 — 私有类用 className 匹配。
                // 详见 docs/plan-sticker-pan-relationship-fix-2026-04-25.md
                result = true
            } else {
                result = false
            }
            PROBE("[PROBE 贴纸 shouldSimul] self=\(type(of: gestureRecognizer))(s=\(gestureRecognizer.state.rawValue)) other=\(type(of: other))(s=\(other.state.rawValue)) → \(result)")
            return result
        }
    }
}
#endif
