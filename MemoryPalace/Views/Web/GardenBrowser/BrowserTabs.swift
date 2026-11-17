#if os(iOS)
import Combine
import SwiftUI
import UIKit
import WebKit

/// 花园浏览器的标签页（docs/plan-browser-tabs.md）：聊天弹出来的浏览器和 page2 浏览器 app 共用这一套。
/// 列表 / 当前页 / 截图存盘，App 重开还在；真网页点开才建，最多同时留 `BrowserTabList.liveLimit` 个
@MainActor
@Observable
final class BrowserTabs {
    static let shared = BrowserTabs()

    private(set) var list: BrowserTabList
    /// 截图（总览卡片用），按标签页 id
    private(set) var snapshots: [UUID: UIImage] = [:]
    /// 网页被别处（sheet ↔ page2）借走过：显示它的地方据此重新把网页放回自己身上
    private(set) var hostGeneration = 0

    @ObservationIgnored private var live: [UUID: Live] = [:]
    @ObservationIgnored private var diskSnapshots: [UUID: UIImage] = [:]
    @ObservationIgnored private let directory: URL

    struct Live {
        let controller: MiniBrowserController
        let webView: WKWebView
        var watchers: [AnyCancellable]
    }

    init(directory: URL = BrowserIdentityStore.directory) {
        self.directory = directory
        list = (try? Data(contentsOf: directory.appendingPathComponent("browser-tabs.json")))
            .flatMap { try? JSONDecoder().decode(BrowserTabList.self, from: $0) } ?? BrowserTabList()
    }

    private var fileURL: URL { directory.appendingPathComponent("browser-tabs.json") }
    private var snapshotDirectory: URL { directory.appendingPathComponent("BrowserTabs", isDirectory: true) }

    var records: [BrowserTabRecord] { list.records }
    var active: BrowserTabRecord? { list.active }

    func identity(of record: BrowserTabRecord) -> BrowserIdentity {
        BrowserIdentityStore.load().first { $0.id == record.identityID } ?? .main
    }

    func owns(_ controller: MiniBrowserController) -> Bool { live.values.contains { $0.controller === controller } }

    // MARK: 开 / 切 / 关

    /// 新开一页（url nil = 新标签页，显示浏览器主页）并切过去
    @discardableResult
    func open(_ url: URL?, identity: BrowserIdentity) -> UUID {
        captureActive()
        let id = list.open(url: url?.absoluteString, title: url?.host() ?? "", identityID: identity.id)
        settle()
        return id
    }

    func select(_ id: UUID) {
        guard id != list.activeID else { return }
        captureActive()
        list.select(id)
        settle()
    }

    func close(_ id: UUID) {
        drop(id)
        list.close(id)
        removeSnapshot(id)
        settle()
    }

    func closeOthers(keeping id: UUID) {
        for r in list.records where r.id != id { drop(r.id); removeSnapshot(r.id) }
        list.closeOthers(keeping: id)
        settle()
    }

    func closeAll() {
        for r in list.records { drop(r.id); removeSnapshot(r.id) }
        list.closeAll()
        settle()
    }

    /// 新标签页（还没网页）在主页上打开一个网址
    func load(_ url: URL, in id: UUID) {
        if let l = live[id] { l.controller.load(url); return }
        list.update(id, url: url.absoluteString, title: url.host() ?? "")
        settle()
    }

    /// 新标签页在主页上换身份（还没网页，换了直接生效）
    func setIdentity(_ identity: BrowserIdentity, for id: UUID) {
        guard live[id] == nil else { return }
        list.update(id, identityID: identity.id)
        save()
    }

    /// 「用别的身份打开」：同一个网址换身份重开（数据仓建网页时就定了，只能新建）
    func reopen(_ id: UUID, as identity: BrowserIdentity) {
        let url = live[id]?.controller.url?.absoluteString ?? list.record(id)?.url
        drop(id)
        list.update(id, url: url, identityID: identity.id)
        settle()
    }

    /// 当前页的活网页；还没建（刚重开 App / 被卸掉 / 新开）就现在建并加载
    func activeLive() -> Live? {
        guard let record = list.active, record.url != nil else { return nil }
        return liveFor(record)
    }

    /// sheet 关了：page2 那边把借走的网页拿回来
    func hostChanged() { hostGeneration += 1 }

    // MARK: 活网页

    private func liveFor(_ record: BrowserTabRecord) -> Live? {
        if let l = live[record.id] { return l }
        guard let raw = record.url, let url = URL(string: raw) else { return nil }
        let controller = MiniBrowserController()
        let webView = BrowserWebView(initialURL: url, controller: controller, identity: identity(of: record)).makeWebView()
        return adopt(webView, controller: controller, for: record.id)
    }

    private func adopt(_ webView: WKWebView, controller: MiniBrowserController, for id: UUID) -> Live {
        controller.onOpenWindow = { [weak self, weak controller] configuration, request in
            guard let self, let controller else { return nil }
            return self.openWindow(configuration: configuration, request: request, opener: controller)
        }
        controller.onCloseWindow = { [weak self] in self?.close(id) }
        let watchers: [AnyCancellable] = [
            controller.$url.dropFirst().sink { [weak self] url in
                guard let url, url.scheme?.hasPrefix("http") == true else { return }
                self?.list.update(id, url: url.absoluteString)
                self?.save()
            },
            controller.$title.dropFirst().sink { [weak self] title in
                guard !title.isEmpty else { return }
                self?.list.update(id, title: title)
                self?.save()
            }
        ]
        let l = Live(controller: controller, webView: webView, watchers: watchers)
        live[id] = l
        return l
    }

    /// 网页要开新窗口：用 WebKit 给的 configuration 建（同一个数据仓 = 同一个身份），开成新标签页并切过去
    private func openWindow(configuration: WKWebViewConfiguration, request: URLRequest, opener: MiniBrowserController) -> WKWebView {
        captureActive()
        let identityID = opener.identityID
        let identity = BrowserIdentityStore.load().first { $0.id == identityID } ?? .main
        let url = request.url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        let id = list.open(url: url?.absoluteString ?? "about:blank", title: url?.host() ?? "", identityID: identityID)
        let controller = MiniBrowserController()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        BrowserWebView.setUp(webView, controller: controller, identity: identity)
        _ = adopt(webView, controller: controller, for: id)
        settle()
        return webView
    }

    private func drop(_ id: UUID) {
        guard let l = live.removeValue(forKey: id) else { return }
        l.webView.stopLoading()
        l.webView.removeFromSuperview()
        l.controller.webView = nil
    }

    /// 切了页 / 开了页之后：多出来的真网页卸掉，存盘
    private func settle() {
        for id in list.toUnload(live: Set(live.keys)) { drop(id) }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: 截图

    /// 渲染时读：从盘上读到的放不参与观察的缓存里（渲染中改被观察的状态会循环刷新）
    func snapshot(_ id: UUID) -> UIImage? {
        if let image = snapshots[id] ?? diskSnapshots[id] { return image }
        guard let image = UIImage(contentsOfFile: snapshotDirectory.appendingPathComponent("\(id.uuidString).jpg").path) else { return nil }
        diskSnapshots[id] = image
        return image
    }

    /// 切走 / 打开总览之前给当前页截一张（只截看得见的这一屏）
    func captureActive() {
        guard let id = list.activeID, let l = live[id], l.webView.window != nil, l.webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 360
        l.webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self, let image else { return }
            self.snapshots[id] = image
            let dir = self.snapshotDirectory
            Task.detached {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? image.jpegData(compressionQuality: 0.6)?.write(to: dir.appendingPathComponent("\(id.uuidString).jpg"), options: .atomic)
            }
        }
    }

    private func removeSnapshot(_ id: UUID) {
        snapshots[id] = nil
        diskSnapshots[id] = nil
        try? FileManager.default.removeItem(at: snapshotDirectory.appendingPathComponent("\(id.uuidString).jpg"))
    }
}

/// 把当前标签页的网页放进来。同一个网页在 sheet 和 page2 之间挪：谁显示就挪到谁身上（UIView 只能有一个父视图）
struct BrowserTabHost: UIViewRepresentable {
    let webView: WKWebView
    /// 变了就重新挂一次（sheet 关掉后 page2 拿回网页）
    let generation: Int

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .systemBackground
        view.show(webView)
        return view
    }

    func updateUIView(_ view: HostView, context: Context) { view.show(webView) }

    /// 真在屏幕上：有窗口、没有藏起来的祖先（page2 后台 app 是 isHidden）、而且落在窗口里（page2 翻页时另一页在屏幕外）
    static func isVisible(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        var v: UIView? = view
        while let current = v {
            if current.isHidden || current.alpha < 0.01 { return false }
            v = current.superview
        }
        return view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    final class HostView: UIView {
        private weak var current: WKWebView?

        func show(_ webView: WKWebView) {
            if current !== webView, let current, current.superview === self { current.removeFromSuperview() }
            current = webView
            guard webView.superview !== self else { return }
            // 藏在后台的 page2 浏览器别把网页从看得见的 sheet 手里抢走；网页没人拿着时谁都可以拿
            if webView.superview != nil, !BrowserTabHost.isVisible(self) { return }
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(webView)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let current { show(current) }
        }
    }
}
#endif
