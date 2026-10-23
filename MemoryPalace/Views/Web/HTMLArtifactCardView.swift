import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// artifact → 文件库 artifacts/ 目录。返回相对路径（nil = profileId 空或写失败）。
func saveArtifactToLibrary(content: String, title: String?, profileId: String) -> String? {
    guard !profileId.isEmpty else { return nil }
    var base = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    base = base.replacingOccurrences(of: "[/\\:*?\"<>|#]", with: "-", options: .regularExpression)
    if base.count > 24 { base = String(base.prefix(24)) }
    if base.isEmpty {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        base = "网页-" + formatter.string(from: Date())
    }
    var candidate = "artifacts/\(base).html"
    var index = 2
    while FileLibraryStore.exists(candidate, profileId: profileId) {
        candidate = "artifacts/\(base)-\(index).html"
        index += 1
    }
    guard (try? FileLibraryStore.write(candidate, content: content, profileId: profileId)) != nil else { return nil }
    NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
    return candidate
}

private struct BrowseTarget: Identifiable {
    let id = UUID()
    let url: URL
}

struct HTMLArtifactPreviewSheet: View {
    let content: String
    var profileId: String = ""
    /// 卡库 ⑦：聊天网页卡没权限运行时传 false，完整页也只静态显示（文件库等调用点不传，维持原样）
    var scriptsAllowed: Bool = true
    /// 卡库第二批 B2：卡聊天的网页，完整页也走同一份联网策略（nil = 非卡，维持原样）
    var card: HTMLPreviewCard? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var pageTitle = ""
    @State private var isLoading = true
    @State private var refreshToken = 0
    @State private var browseTarget: BrowseTarget? = nil
    @State private var savedPath: String? = nil
    #if os(iOS)
    @State private var tempURL: URL?
    #endif

    var body: some View {
        #if os(iOS)
        // 学照片预览：黑底全屏 + 顶部渐变遮罩 + 玻璃圆关闭/菜单，无导航栏白边
        ZStack {
            Color.black.ignoresSafeArea()

            // 四边全出血：页面 canvas 一直铺到灵动岛和 home 条底下，黑 backdrop 只在加载瞬间可见。
            // 不学照片预览的顶部渐变罩——盖在纯色网页上像黑雾，玻璃按钮自带对比度
            HTMLPreviewWebView(
                content: content,
                staticMode: !scriptsAllowed,
                backdrop: .black,
                refreshToken: refreshToken,
                onPageTitle: { pageTitle = $0 },
                onLoadingChanged: { isLoading = $0 },
                onOpenLink: { browseTarget = BrowseTarget(url: $0) },
                card: card
            )
            .ignoresSafeArea()

            // 顶部渐变遮罩：1:1 抄 page1 照片预览（0.88/150），白按钮对比度靠它
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.88), .black.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 150)
                .allowsHitTesting(false)
                Spacer()
            }
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                    }

                    Spacer()

                    // W2：页面标题胶囊（学照片预览的计数胶囊），加载中转菊花
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(pageTitle.isEmpty ? "网页预览" : pageTitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 200)
                    .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)

                    Spacer()

                    Button {
                        isLoading = true
                        refreshToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                    }

                    Menu {
                        Button {
                            savedPath = saveArtifactToLibrary(content: content, title: pageTitle, profileId: profileId)
                        } label: {
                            Label("保存到文件库", systemImage: "books.vertical")
                        }
                        Button {
                            saveToFiles()
                        } label: {
                            Label("保存到文件", systemImage: "folder.badge.plus")
                        }
                        Button {
                            shareItem()
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = content
                        } label: {
                            Label("复制源码", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                    }
                }
                .compositingGroup()
                .padding(.horizontal, 16)
                .padding(.top, 19)

                Spacer()
            }
        }
        .onDisappear { cleanupTempFile() }
        .sheet(item: $browseTarget) { target in
            MiniBrowserView(initialURL: target.url)
        }
        .alert("已保存到文件库", isPresented: Binding(get: { savedPath != nil }, set: { if !$0 { savedPath = nil } })) {
            Button("好") { savedPath = nil }
        } message: {
            Text(savedPath ?? "")
        }
        #else
        NavigationStack {
            HTMLPreviewWebView(
                content: content,
                staticMode: !scriptsAllowed,
                refreshToken: refreshToken,
                onPageTitle: { pageTitle = $0 },
                onLoadingChanged: { isLoading = $0 },
                onOpenLink: { browseTarget = BrowseTarget(url: $0) },
                card: card
            )
                .navigationTitle(pageTitle.isEmpty ? "网页预览" : pageTitle)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                            .foregroundColor(Theme.textMuted)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            isLoading = true
                            refreshToken += 1
                        } label: {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        Menu {
                            Button("保存到文件库") {
                                savedPath = saveArtifactToLibrary(content: content, title: pageTitle, profileId: profileId)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
        }
        .frame(width: 760, height: 640)
        .sheet(item: $browseTarget) { target in
            MiniBrowserView(initialURL: target.url)
        }
        .alert("已保存到文件库", isPresented: Binding(get: { savedPath != nil }, set: { if !$0 { savedPath = nil } })) {
            Button("好") { savedPath = nil }
        } message: {
            Text(savedPath ?? "")
        }
        #endif
    }

    #if os(iOS)
    private func prepareTempFile() -> URL? {
        if let tempURL { return tempURL }
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artifact_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("网页-\(stamp).html")
        guard let data = content.data(using: .utf8), (try? data.write(to: url)) != nil else { return nil }
        tempURL = url
        return url
    }

    private func cleanupTempFile() {
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
    }

    /// 最顶层已 present 的 VC（抄 AttachmentPreviewSheet：sheet 自己挂在 root 上，
    /// 从 root present 会 already presenting 失败，必须 present 到最顶层）
    private func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private func saveToFiles() {
        guard let url = prepareTempFile() else { return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        topPresenter()?.present(picker, animated: true)
    }

    private func shareItem() {
        guard let url = prepareTempFile(), let presenter = topPresenter() else { return }
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = presenter.view
        ac.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        presenter.present(ac, animated: true)
    }
    #endif
}
