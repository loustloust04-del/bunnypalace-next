#if DEBUG && os(iOS)
import SwiftUI

/// 帧 scrub 时间轴。上半屏大图 + 中间帧信息 + 单帧 step 按钮 + slider + 横向缩略条。
/// 关键诉求：能停在 contextMenu 弹出那一瞬，逐帧看 bubble 状态。
///
/// 多选模式：toolbar 点「选择」进入；缩略图改成「点 = 切换勾选」，再次点「完成」退出。
/// 退出/分享后清空 selection。一次最多 30 帧（避 OOM；不强拦但 disable 按钮）。
struct DebugTimelineView: View {
    let clip: DebugRecorder.Clip
    @State private var currentIndex: Int = 0
    @State private var selectionMode = false
    @State private var selectedIndices: Set<Int> = []
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var exporting = false
    @State private var exportProgress: Int = 0
    @State private var exportTotal: Int = 0
    @Environment(\.dismiss) private var dismiss

    private let maxSelectable = 30

    private var currentFrame: DebugRecorder.Frame? {
        guard clip.frames.indices.contains(currentIndex) else { return nil }
        return clip.frames[currentIndex]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 大图
                if let frame = currentFrame {
                    Image(uiImage: frame.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 帧信息条
                HStack {
                    Text("第 \(currentIndex + 1) / \(clip.frames.count) 帧")
                        .font(.system(.subheadline, design: .monospaced))
                    Spacer()
                    if let f = currentFrame {
                        Text(String(format: "t=%.3fs", f.timestamp))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))

                // 单帧 step + slider
                HStack(spacing: 12) {
                    Button {
                        if currentIndex > 0 { currentIndex -= 1 }
                    } label: {
                        Image(systemName: "backward.frame.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(currentIndex == 0)

                    Slider(
                        value: Binding(
                            get: { Double(currentIndex) },
                            set: { currentIndex = Int($0.rounded()) }
                        ),
                        in: 0...Double(max(clip.frames.count - 1, 0)),
                        step: 1
                    )

                    Button {
                        if currentIndex < clip.frames.count - 1 { currentIndex += 1 }
                    } label: {
                        Image(systemName: "forward.frame.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(currentIndex >= clip.frames.count - 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                // 选择模式提示条
                if selectionMode {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.red)
                        Text("已选 \(selectedIndices.count) / \(maxSelectable)")
                            .font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Button("全清") {
                            selectedIndices.removeAll()
                        }
                        .disabled(selectedIndices.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                }

                // 缩略条
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                        HStack(spacing: 4) {
                            ForEach(Array(clip.frames.enumerated()), id: \.element.id) { idx, frame in
                                thumbnail(idx: idx, frame: frame)
                                    .id(idx)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .frame(height: 92)
                    .background(Color(.systemBackground))
                    .onChange(of: currentIndex) { _, new in
                        guard !selectionMode else { return }   // 选择模式不自动滚
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle(clip.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showShareSheet, onDismiss: {
                shareItems = []
            }) {
                ActivityShareSheet(items: shareItems)
            }
        }
    }

    // MARK: - Thumbnail (with selection overlay)

    @ViewBuilder
    private func thumbnail(idx: Int, frame: DebugRecorder.Frame) -> some View {
        let isSelected = selectedIndices.contains(idx)
        let isCurrent = idx == currentIndex
        Image(uiImage: frame.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 48, height: 72)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isSelected ? Color.red : (isCurrent ? Color.red.opacity(0.5) : Color.gray.opacity(0.3)),
                        lineWidth: isSelected ? 3 : (isCurrent ? 2 : 1)
                    )
            )
            .overlay(alignment: .topTrailing) {
                if selectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(isSelected ? .red : .white)
                        .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.4)).frame(width: 18, height: 18))
                        .padding(2)
                }
            }
            .overlay(alignment: .bottom) {
                // 帧号小标签便于挑出来告诉粟粟"看第 N 帧"
                Text("\(idx + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6))
            }
            .onTapGesture {
                if selectionMode {
                    toggleSelection(idx)
                } else {
                    currentIndex = idx
                }
            }
    }

    private func toggleSelection(_ idx: Int) {
        if selectedIndices.contains(idx) {
            selectedIndices.remove(idx)
        } else if selectedIndices.count < maxSelectable {
            selectedIndices.insert(idx)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(selectionMode ? "完成" : "关闭") {
                if selectionMode {
                    selectionMode = false
                    selectedIndices.removeAll()
                } else {
                    dismiss()
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if exporting {
                HStack(spacing: 4) {
                    ProgressView()
                    Text("\(exportProgress)/\(exportTotal)")
                        .font(.system(.caption2, design: .monospaced))
                }
            } else if selectionMode {
                Button {
                    shareSelected()
                } label: {
                    Label("导出 \(selectedIndices.count)", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedIndices.isEmpty)
            } else {
                Menu {
                    if let f = currentFrame {
                        Button {
                            shareSingleFrame(f, index: currentIndex)
                        } label: {
                            Label("当前帧（第 \(currentIndex + 1) 帧）", systemImage: "photo")
                        }
                    }
                    Button {
                        selectionMode = true
                    } label: {
                        Label("选择多张...", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - Export

    private func shareSingleFrame(_ frame: DebugRecorder.Frame, index: Int) {
        exportFrames([(index, frame)])
    }

    private func shareSelected() {
        let picks = selectedIndices.sorted().compactMap { idx -> (Int, DebugRecorder.Frame)? in
            guard clip.frames.indices.contains(idx) else { return nil }
            return (idx, clip.frames[idx])
        }
        guard !picks.isEmpty else { return }
        exportFrames(picks)
    }

    /// 单一导出路径：写 JPEG 到 tmp + UIActivityViewController。
    /// 包 autoreleasepool 让 jpegData buffer 写完立即释放避免 OOM。
    private func exportFrames(_ frames: [(Int, DebugRecorder.Frame)]) {
        guard !frames.isEmpty else { return }
        exporting = true
        exportProgress = 0
        exportTotal = frames.count
        let safeName = clip.name.replacingOccurrences(of: ":", with: "-")
        let dirName = "debug-clip-\(safeName)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(dirName, isDirectory: true)

        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var urls: [URL] = []
            for (i, pair) in frames.enumerated() {
                let (idx, frame) = pair
                autoreleasepool {
                    let url = dir.appendingPathComponent("frame-\(String(format: "%03d", idx + 1)).jpg")
                    if let data = frame.image.jpegData(compressionQuality: 0.7) {
                        try? data.write(to: url)
                        urls.append(url)
                    }
                }
                let done = i + 1
                DispatchQueue.main.async {
                    exportProgress = done
                }
            }
            DispatchQueue.main.async {
                shareItems = urls
                exporting = false
                exportProgress = 0
                exportTotal = 0
                showShareSheet = true
            }
        }
    }
}

/// UIActivityViewController 的 SwiftUI 包装。批量分享 URL 数组：AirDrop / 存照片 /
/// 发到任何支持多文件的 app 都能一次性接收所有帧。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
