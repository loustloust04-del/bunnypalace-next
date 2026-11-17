#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 网页应用长按的「历史版本」「从文件换一版」「分享」（plan-webapp-as-file §2.3）：桌面和资源库共用。
/// 历史就是文件库那套（`FileVersionHistoryView`，有对比）；换版 = 直接写那个文件，开着的应用跟着刷新
@MainActor
enum WebAppActions {
    static func app(for toolID: String) -> WebApp? {
        WebAppStore.appID(fromToolID: toolID).flatMap { WebAppStore.shared.app($0) }
    }

    static func showHistory(_ app: WebApp) {
        guard let profileId = WebAppStore.shared.profileId else { return }
        Task {
            let current = await Task.detached { try? FileLibraryStore.read(app.path, profileId: profileId) }.value
            guard let top = WebAppInstaller.topViewController() else { return }
            let key = FileVersionStore.Key.file(profileId: profileId, relativePath: app.path)
            let host = UIHostingController(rootView: FileVersionHistoryView(
                key: key, currentContent: current ?? "",
                onRestore: { restored in Task { try? await overwrite(app, with: restored.text, source: .restore) } },
                restoreHint: "「\(app.title)」会换成这一版，开着的话马上刷新；网页里存的数据不会跟着回去。"
            ))
            host.modalPresentationStyle = .pageSheet
            host.sheetPresentationController?.detents = [.medium(), .large()]
            host.sheetPresentationController?.prefersGrabberVisible = true
            top.present(host, animated: true)
        }
    }

    /// 挑一个 html，换掉这个应用现在的内容（换之前那份留在历史里）
    static func replaceFromFile(_ app: WebApp) {
        guard let top = WebAppInstaller.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.html], asCopy: true)
        let delegate = PickDelegate { url in
            guard let data = try? Data(contentsOf: url), let html = String(data: data, encoding: .utf8) else { return }
            Task { try? await overwrite(app, with: html, source: .external) }
        }
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &PickDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
    }

    /// 写应用的文件：改之前那份、改之后那份都进版本历史
    static func overwrite(_ app: WebApp, with text: String, source: FileVersionStore.Source) async throws {
        guard let profileId = WebAppStore.shared.profileId else { return }
        let path = app.path
        try await Task.detached {
            let key = FileVersionStore.Key.file(profileId: profileId, relativePath: path)
            if let before = try? FileLibraryStore.read(path, profileId: profileId) {
                _ = try? await FileVersionStore.shared.record(key: key, content: before, source: .external)
            }
            try FileLibraryStore.write(path, content: text, profileId: profileId)
            _ = try? await FileVersionStore.shared.record(key: key, content: text, source: source)
        }.value
    }

    static func deleteMessage(_ app: WebApp?) -> String {
        "会删掉文件库里的「\(app?.path ?? "")」和它存的数据，删了找不回来。只想拿掉图标用「从主屏移除」。"
    }

    static func confirmDelete(_ app: WebApp) {
        guard let top = WebAppInstaller.topViewController() else { return }
        let alert = UIAlertController(title: "删除「\(app.title)」？", message: deleteMessage(app), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in Task { try? await WebAppInstaller.delete(app) } })
        top.present(alert, animated: true)
    }

    /// 分享文件库里那个 html 本身，网页存的数据不带
    static func share(_ app: WebApp) {
        guard let profileId = WebAppStore.shared.profileId else { return }
        Task {
            guard let file = await Task.detached(operation: { FileLibraryStore.resolve(app.path, profileId: profileId) }).value,
                  let top = WebAppInstaller.topViewController() else { return }
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            top.present(sheet, animated: true)
        }
    }

    private final class PickDelegate: NSObject, UIDocumentPickerDelegate {
        nonisolated(unsafe) static var key = 0
        let picked: (URL) -> Void

        init(picked: @escaping (URL) -> Void) { self.picked = picked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { picked(url) }
        }
    }
}
#endif
