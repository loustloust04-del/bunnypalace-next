#if DEBUG && os(iOS)
import SwiftUI

/// 调试面板 sheet。v1：录屏控制 + 已录片段列表 → 进时间轴。
/// 预留更多工具区（手势可视化 / CALayer dump 等）后续扩展。
struct DebugPanelView: View {
    @ObservedObject private var recorder = DebugRecorder.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedClip: DebugRecorder.Clip?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if recorder.isRecording {
                        Button {
                            recorder.stop()
                        } label: {
                            HStack {
                                Image(systemName: "stop.circle.fill")
                                    .foregroundColor(.red)
                                Text("停止录制")
                                    .foregroundColor(.red)
                                Spacer()
                                Text("\(recorder.currentFrameCount) 帧")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Button {
                            recorder.start()
                            // 收起面板让你能操作；停了再点悬浮球回来
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "record.circle")
                                    .foregroundColor(.red)
                                Text("开始录屏")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                } header: {
                    Text("帧捕获")
                } footer: {
                    Text("20 fps，最长 10 秒（200 帧环形 buffer，超出自动丢头）。开始后面板自动关闭，停了再点悬浮球回来 scrub。\n\n注意：iOS 系统级 contextMenu 预览在私有窗口里，app 抓不到那一层；但 bubble 自身高亮/缩放/动画前后帧能看见。")
                        .font(.caption)
                }

                if !recorder.clips.isEmpty {
                    Section("已录片段") {
                        ForEach(recorder.clips) { clip in
                            Button {
                                selectedClip = clip
                            } label: {
                                HStack(spacing: 12) {
                                    if let firstFrame = clip.frames.first {
                                        Image(uiImage: firstFrame.image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 44, height: 62)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(clip.name)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.primary)
                                        Text("\(clip.frames.count) 帧 · \(String(format: "%.1fs", clip.duration))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx {
                                let clip = recorder.clips[i]
                                recorder.deleteClip(clip)
                            }
                        }

                        Button(role: .destructive) {
                            recorder.clearAll()
                        } label: {
                            Label("清空所有片段", systemImage: "trash")
                        }
                    }
                }

                // 预留扩展区
                Section {
                    Text("更多工具会陆续加进来 — 事件日志、手势可视化、CALayer dump…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("更多")
                }
            }
            .navigationTitle("调试面板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $selectedClip) { clip in
                DebugTimelineView(clip: clip)
            }
        }
    }
}
#endif
