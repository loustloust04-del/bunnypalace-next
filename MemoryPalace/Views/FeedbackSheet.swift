import SwiftUI
#if os(iOS)
import PhotosUI
import UIKit
#endif

/// 反馈面板（摇一摇 / ⌘⇧D 触发，或设置反馈区"立即记录"按钮触发）。
/// 上架版收集：截图 + 操作轨迹（不含消息内容）+ 用户手写笔记 + 可选相册补图。
struct FeedbackPayload: Identifiable {
    let id = UUID()
    let screenshot: Data?
    let context: FeedbackStore.Context
}

struct FeedbackSheet: View {
    let payload: FeedbackPayload
    @Environment(\.dismiss) private var dismiss

    @State private var note = ""
    @State private var showBreadcrumbs = false
    @State private var saveError: String? = nil
    @State private var saved = false
    @State private var extraImages: [Data] = []
    #if os(iOS)
    @State private var shareBundle: ShareBundle? = nil
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let data = payload.screenshot, let image = platformImage(data) {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Theme.accent.opacity(0.6), lineWidth: 1)
                            )
                            .frame(maxWidth: .infinity)
                    }

                    #if os(iOS)
                    extraImagesSection
                    #endif

                    versionCard

                    DisclosureGroup(isExpanded: $showBreadcrumbs) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(BreadcrumbLog.shared.entries.reversed()) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.icon)
                                        .font(.system(size: Theme.F.caption))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.text)
                                            .font(.system(size: Theme.F.caption))
                                            .foregroundColor(Theme.textSecondary)
                                            .lineLimit(3)
                                        Text(entry.time, style: .time)
                                            .font(.system(size: 9))
                                            .foregroundColor(Theme.textMuted)
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("最近操作轨迹（\(BreadcrumbLog.shared.entries.count) 条）")
                            .font(.system(size: Theme.F.body, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .tint(Theme.branchIndicator)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("说说遇到了什么")
                            .font(.system(size: Theme.F.body, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        TextEditor(text: $note)
                            .font(.system(size: Theme.F.body))
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebarBg))
                            .scrollContentBackground(.hidden)
                        Text("可选：从照片添加截图说明问题。")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }

                    if let saveError {
                        Text("保存失败：\(saveError)")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.danger)
                    }
                }
                .padding(16)
            }
            .background(Theme.mainBg)
            .navigationTitle(saved ? "已记录 ✓" : "记录反馈")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并发送", action: save)
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(saved)
                }
            }
        }
        #if os(iOS)
        .sheet(item: $shareBundle) { bundle in
            ShareSheet(items: bundle.urls)
        }
        #endif
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
    }

    #if os(iOS)
    private var extraImagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !extraImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                    HStack(spacing: 8) {
                        ForEach(extraImages.indices, id: \.self) { i in
                            if let image = platformImage(extraImages[i]) {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Theme.accent.opacity(0.6), lineWidth: 1)
                                    )
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            extraImages.remove(at: i)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundStyle(.white, Color.black.opacity(0.45))
                                        }
                                        .padding(3)
                                    }
                            }
                        }
                    }
                }
            }

            PhotosPicker(selection: $photoItems, maxSelectionCount: 8, matching: .images) {
                Label("从照片添加截图", systemImage: "photo.on.rectangle")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.branchIndicator)
            }
            .disabled(saved)
            .onChange(of: photoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data),
                           let jpeg = Self.downscale(image, maxEdge: 2048).jpegData(compressionQuality: 0.82) {
                            await MainActor.run { extraImages.append(jpeg) }
                        }
                    }
                    await MainActor.run { photoItems = [] }
                }
            }
        }
    }

    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxEdge else { return image }
        let scale = maxEdge / longEdge
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    #endif

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            versionRow("app", FeedbackStore.appVersionLine)
            versionRow("页面", payload.context.pageDescription)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.25)))
    }

    private func versionRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textMuted)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        do {
            let url = try FeedbackStore.save(
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                screenshot: payload.screenshot,
                extraImages: extraImages,
                context: payload.context
            )
            saved = true
            BreadcrumbLog.shared.add("📝", "记录反馈 \(url.lastPathComponent)")
            #if os(iOS)
            // 落盘后立刻弹分享面板，用户挑微信/AirDrop/邮件发开发者，0 翻文件夹。
            // 取消分享也已经留底（设置反馈区可手动重发）。
            let stem = url.deletingPathExtension().lastPathComponent
            let dir = url.deletingLastPathComponent()
            let siblings = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let urls = siblings.filter { $0.lastPathComponent.hasPrefix(stem) }
            shareBundle = ShareBundle(urls: urls)
            #else
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
            #endif
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(iOS)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #else
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #endif
    }
}

/// 设置 · 反馈页（iOS）/ 开发调试 tab（macOS）的反馈控制区。
struct FeedbackDebugSection: View {
    @AppStorage("feedbackGestureEnabled") private var feedbackGestureEnabled = true
    @State private var localPayload: FeedbackPayload? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    #if os(iOS)
                    Text("摇一摇记录反馈")
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("任意页面摇一摇手机，弹出反馈面板。点保存后自动弹分享面板，发给开发者。")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    #else
                    Text("⌘⇧D 记录反馈")
                        .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("快捷键弹出反馈面板（自动带截图 + 操作轨迹），也在菜单栏「显示」里。")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    #endif
                }
                Spacer()
                Toggle("", isOn: $feedbackGestureEnabled)
                    .labelsHidden()
                    .tint(Theme.branchIndicator)
            }

            Button {
                let shot = FeedbackStore.captureScreenshot()
                var ctx = FeedbackStore.Context()
                #if os(iOS)
                ctx.pageDescription = "设置 · 反馈"
                #else
                ctx.pageDescription = "设置 · 开发调试"
                #endif
                localPayload = FeedbackPayload(screenshot: shot, context: ctx)
            } label: {
                Label("立即记录反馈", systemImage: "square.and.pencil")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(feedbackGestureEnabled ? Theme.branchIndicator : Theme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!feedbackGestureEnabled)

            #if os(iOS)
            Text("点保存自动弹分享面板（微信 / AirDrop / 邮件都行）。同时本地留底。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))
            #else
            Text("反馈存在 Application Support/MemoryPalace/feedback/。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))
            #endif
        }
        .sheet(item: $localPayload) { payload in
            FeedbackSheet(payload: payload)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationBackground(Theme.mainBg)
                #endif
        }
    }
}

#if os(iOS)
import CoreMotion

/// 包系统 UIActivityViewController 的 SwiftUI sheet：分享 md + 截图 + 附图。
struct ShareBundle: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 摇一摇检测：CoreMotion accelerometer + 阈值判定。
/// 不用 UIWindow.motionEnded swizzle（iOS 17+ 系统对 UIWindow 内部 KVC 复杂，
/// swizzle 后摇手机闪退）；也不用 UIViewController.becomeFirstResponder（SwiftUI 树里
/// child VC 抢不到 first responder）。accelerometer 是公开 API 无需 entitlement，
/// app 启动调 `ShakeMonitor.shared.start()`，进 background 时 stop。
final class ShakeMonitor {
    static let shared = ShakeMonitor()

    private let motion = CMMotionManager()
    private var lastTrigger: Date = .distantPast
    /// 摇晃强度阈值（用户加速度，g）。日常拿手机走路约 0.3-0.5g，刻意摇晃 > 1.5g。
    private let threshold: Double = 1.8
    /// 防抖：两次触发最少间隔 1.5s。
    private let debounce: TimeInterval = 1.5

    private init() {}

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let acc = data?.userAcceleration else { return }
            let mag = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)
            guard mag > self.threshold else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastTrigger) > self.debounce else { return }
            self.lastTrigger = now
            NotificationCenter.default.post(name: .feedbackGestureTriggered, object: nil)
        }
    }

    func stop() {
        if motion.isDeviceMotionActive {
            motion.stopDeviceMotionUpdates()
        }
    }
}
#endif
