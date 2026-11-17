#if os(iOS)
import SwiftUI
import UIKit

/// 把 html 放到花园桌面 / 真删（plan-webapp-as-file §2.4 §2.6）。入口（聊天卡片、文件库、资源库、用记忆花园打开、AI 工具）都走这里。
/// 新的 html 先写进这一层文件库 `应用/`，文件库里已有的直接指过去
@MainActor
enum WebAppInstaller {
    struct Installed {
        let app: WebApp
        /// 放在桌面第几页（1 起）；桌面还没初始化 = nil
        let page: Int?
    }

    /// 弹小卡：图标预览 + 名字 → 放到桌面。`path` = 文件库里已有的那个文件（不拷，名字改了就是给文件改名）
    static func present(html: String, suggestedTitle: String? = nil, path: String? = nil) {
        guard let top = topViewController() else { return }
        let title = path.map(WebAppStore.title(ofPath:)) ?? WebAppHTML.title(in: html) ?? suggestedTitle ?? WebAppHTML.fallbackTitle
        let box = HostBox()
        let host = UIHostingController(rootView: WebAppInstallCard(html: html, title: title, path: path) { box.host?.dismiss(animated: true) })
        box.host = host
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.custom { _ in 330 }]
            sheet.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
    }

    /// 「文件」/ 隔空投送里选「用记忆花园打开」的 html：读成文字弹小卡；别的网址不管
    static func openFile(_ url: URL) {
        guard url.isFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let html = String(data: data, encoding: .utf8) else { return }
        // 冷启动时根视图还没挂好，稍等再弹
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            present(html: html, suggestedTitle: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// 新的 html：写进这一层 `应用/<名字>.html` 再放
    static func install(html: String, title: String, id: UUID = UUID()) async throws -> Installed {
        let store = WebAppStore.shared
        guard let profileId = store.profileId else { throw WebAppStore.error("楼层还没准备好") }
        let app = try await store.create(html: html, title: title, id: id, profileId: profileId)
        return await finish(app, html: html)
    }

    /// 文件库里已有的 html：直接指过去；小卡上改了名字 = 给文件改名（同一个文件夹）
    static func install(path: String, title: String, id: UUID = UUID()) async throws -> Installed {
        let store = WebAppStore.shared
        guard let profileId = store.profileId else { throw WebAppStore.error("楼层还没准备好") }
        let name = WebAppStore.fileName(title)
        var target = path
        if name != WebAppStore.title(ofPath: path), store.app(path: path) == nil {
            let folder = (path as NSString).deletingLastPathComponent
            let ext = (path as NSString).pathExtension
            target = (folder.isEmpty ? "" : folder + "/") + name + "." + ext
            try await Task.detached { try FileLibraryStore.rename(path, to: target, profileId: profileId) }.value
        }
        let app = try await store.add(path: target, id: id, profileId: profileId)
        let html = await Task.detached { (try? FileLibraryStore.read(target, profileId: profileId)) ?? "" }.value
        return await finish(app, html: html)
    }

    private static func finish(_ app: WebApp, html: String) async -> Installed {
        let appearance = Page2AppearanceStore.shared
        if appearance.value.icons[app.toolID] == nil,
           let png = await iconPNG(html: html, title: app.title, id: app.id),
           let file = try? await Page2AppearanceStore.shared.importImage(png, isIcon: true) {
            var value = appearance.value
            value.icons[app.toolID] = Page2IconOverride(imageFile: file)
            _ = appearance.save(value)
        }
        let home = Page2HomeStore.shared
        if let page = home.layout.items.first(where: { $0.kind == "app" && $0.toolID == app.toolID }).flatMap({ pageNumber(of: $0.id) }) {
            return Installed(app: app, page: page)
        }
        return Installed(app: app, page: placeOnHome(app.toolID))
    }

    /// 删应用 = 删文件库里那个文件；桌面、图标、数据由 `cleanUp` 收拾（文件在别处被删也走那里）
    static func delete(_ app: WebApp) async throws {
        try await WebAppStore.shared.remove(app.id)
    }

    /// 文件没了：桌面 / 文件夹 / Dock 上的图标、后台里开着的、图标自定义、楼层记录、它存的数据。
    /// 搬家时同一个应用摆在两层、共用一个 id：别的层还登记着就只拿掉这一层的图标
    static func startObserving() {
        guard vanishObserver == nil else { return }
        vanishObserver = NotificationCenter.default.addObserver(forName: .webAppDidVanish, object: nil, queue: .main) { note in
            guard let app = note.object as? WebApp, let profileId = note.userInfo?["profileId"] as? String else { return }
            MainActor.assumeIsolated { Task { await cleanUp(app, profileId: profileId) } }
        }
    }

    private static var vanishObserver: NSObjectProtocol?

    private static func cleanUp(_ app: WebApp, profileId: String) async {
        let toolID = app.toolID
        if profileId == WebAppStore.shared.profileId {
            let home = Page2HomeStore.shared
            for item in home.layout.items where item.kind == "app" && item.toolID == toolID { home.remove(item.id) }
            Page2AppShell.shared.close(toolID)
        }
        guard !WebAppStore.isRegisteredOnAnyFloor(app.id) else { return }
        let appearance = Page2AppearanceStore.shared
        if let override = appearance.value.icons[toolID] {
            var value = appearance.value
            value.icons[toolID] = nil
            if appearance.save(value), let file = override.imageFile { appearance.discardImportedAssets([file]) }
        }
        Page2Apps.clearFloor(toolID)
        await WebAppWebsiteData.remove(app.id)
    }

    private static func pageNumber(of itemID: UUID) -> Int? {
        guard let board = Page2HomeStore.shared.layout.boards.first,
              let pageID = board.placements.first(where: { $0.id == itemID })?.pageID,
              let index = board.pages.filter({ !$0.isHidden }).firstIndex(where: { $0.id == pageID }) else { return nil }
        return index + 1
    }

    private static func placeOnHome(_ toolID: String) -> Int? {
        let home = Page2HomeStore.shared
        guard home.isInitialized, let board = home.layout.boards.first else { return nil }
        let item = Page2Item.app(toolID)
        guard home.insert(item, capacity: board.capacityKey) else { return nil }
        return pageNumber(of: item.id)
    }

    // MARK: 默认图标：网页自己声明的；没有就「标题第一个字 + 柔和底色」

    static func iconPNG(html: String, title: String, id: UUID) async -> Data? {
        if let href = WebAppHTML.iconHref(in: html), let data = await iconData(href), UIImage(data: data) != nil {
            return data
        }
        return letterIcon(title: title, id: id)
    }

    private static func iconData(_ href: String) async -> Data? {
        if href.hasPrefix("data:"), let comma = href.firstIndex(of: ",") {
            let meta = href[..<comma]
            let payload = String(href[href.index(after: comma)...])
            return meta.contains(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard !LocalMode.isOn, let url = URL(string: href), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try? await URLSession.shared.data(for: request).0
    }

    /// 不要蓝、不要黄（粟粟的配色规矩）
    private static let palette: [UIColor] = [
        UIColor(red: 0.56, green: 0.74, blue: 0.62, alpha: 1),
        UIColor(red: 0.66, green: 0.40, blue: 0.45, alpha: 1),
        UIColor(red: 0.47, green: 0.40, blue: 0.49, alpha: 1),
        UIColor(red: 0.74, green: 0.55, blue: 0.47, alpha: 1),
        UIColor(red: 0.36, green: 0.48, blue: 0.41, alpha: 1),
        UIColor(red: 0.42, green: 0.44, blue: 0.43, alpha: 1),
    ]

    static func letterIcon(title: String, id: UUID) -> Data? {
        let side: CGFloat = 180
        let seed = id.uuid.0 &+ id.uuid.5 &+ id.uuid.11
        let color = palette[Int(seed) % palette.count]
        let letter = String(title.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "网")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            color.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))
            let font = UIFont.systemFont(ofSize: 92, weight: .semibold)
            let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 92) } ?? font
            let text = NSAttributedString(string: letter, attributes: [.font: rounded, .foregroundColor: UIColor.white])
            let size = text.size()
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        }
        return image.pngData()
    }

    final class HostBox {
        weak var host: UIViewController?
    }

    static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

/// 放到桌面的小卡（plan §5）
private struct WebAppInstallCard: View {
    let html: String
    @State var title: String
    let path: String?
    var onDone: () -> Void
    @State private var preview: UIImage?
    /// 预览和放上去的同一个 id：首字方块的底色按 id 挑，两边一致
    @State private var id = UUID()
    @State private var busy = false
    @State private var result: String?
    @FocusState private var focused: Bool

    init(html: String, title: String, path: String?, onDone: @escaping () -> Void) {
        self.html = html
        _title = State(initialValue: title)
        self.path = path
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 18) {
            Group {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    Color(uiColor: .tertiarySystemFill)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let result {
                Text(result).font(.headline)
                Button("好", action: onDone).buttonStyle(.glassProminent).tint(Theme.branchIndicator)
            } else {
                TextField("名字", text: $title)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    Button("取消", action: onDone).buttonStyle(.glass)
                    Button("放到桌面") { install() }
                        .buttonStyle(.glassProminent).tint(Theme.branchIndicator)
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .task {
            let png = await WebAppInstaller.iconPNG(html: html, title: title, id: id)
            preview = png.flatMap(UIImage.init(data:))
        }
    }

    private func install() {
        busy = true
        Task {
            do {
                let done = if let path {
                    try await WebAppInstaller.install(path: path, title: title, id: id)
                } else {
                    try await WebAppInstaller.install(html: html, title: title, id: id)
                }
                let place = done.page.map { "已放到桌面第 \($0) 页" } ?? "已放到桌面"
                result = path == nil ? "\(place)\n文件在「\(done.app.path)」" : place
            } catch {
                result = "没放上去：\(error.localizedDescription)"
            }
            busy = false
        }
    }
}
#endif
