#if os(iOS)
import Foundation
import WebKit
import UIKit

/// `mp-asset://` —— 给 web 按需喂二进制（消息图片、头像）。
///
/// 为什么不用 base64 data URI：大图撑爆 DOM，每次渲染重编码。
/// 为什么不用 file://：记忆 `feedback_wkwebview_fileurl_module_cors`，而且沙箱路径会漏出去。
///
/// **路径约定**（和 ChatWebPayload 里生成的 URL 对齐）：
/// ```
/// mp-asset://msg/{nodeId}/{index}          消息里第 index 个图片附件
/// mp-asset://avatar/{profileId}/{user|ai}  头像
/// mp-asset://skin/Images/xxx.png           当前皮肤自带的图 / 字体
/// mp-asset://bg/user?v={mtime}             设置页选的聊天背景图
/// ```
///
/// 踩坑备忘（kimi 审查提的，全部处理了）：
/// - 必须在 **webView 创建前** `config.setURLSchemeHandler(_:forScheme:)`，http/https 不可注册
/// - 生命周期严格：`didReceive(response)` → `didReceive(data)` → `didFinish()`；
///   **task 被 stop 之后再回调会崩** → 用 inflight 表挡住
/// - 回调都在主线程（SwiftData 是 MainActor，顺路），但大图解码别在回调里做
/// - WebKit 对自定义 scheme **不发 Range header**（WebKit bug 203302）→ 只能整读，
///   所以大文件附件别走它做预览
/// - **URLCache 不缓存自定义 scheme** → 头像每次重渲都会打 handler，自己加内存缓存
@MainActor
final class ChatAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mp-asset"

    private weak var viewModel: ConversationViewModel?
    private var profileProvider: () -> Profile?
    /// stop 之后不能再碰的 task
    private var live = Set<ObjectIdentifier>()
    private let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 32 * 1024 * 1024      // 32MB，够几十张聊天图
        return c
    }()

    init(viewModel: ConversationViewModel?, profileProvider: @escaping () -> Profile?) {
        self.viewModel = viewModel
        self.profileProvider = profileProvider
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        live.insert(key)

        guard let url = task.request.url else { return finish(task, key: key, data: nil, mime: nil) }
        let cacheKey = url.absoluteString as NSString

        if let hit = cache.object(forKey: cacheKey) {
            return finish(task, key: key, data: hit as Data, mime: Self.mime(for: hit as Data))
        }

        // mp-asset://<host>/<p1>/<p2>
        let host = url.host ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        var data: Data?

        switch host {
        case "msg":
            if parts.count >= 2, let idx = Int(parts[1]) {
                data = imageData(nodeId: parts[0], index: idx)
            }
        case "avatar":
            if parts.count >= 1 {
                let p = profileProvider()
                data = parts[0] == "user" ? p?.userAvatarData : p?.assistantAvatarData
            }
        case "skin":
            data = skinFile(parts)
        case "bg":
            data = try? Data(contentsOf: ChatSkinStore.userBackgroundURL)
        default:
            break
        }

        if let d = data { cache.setObject(d as NSData, forKey: cacheKey, cost: d.count) }
        finish(task, key: key, data: data, mime: data.flatMap(Self.mime(for:)))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    // MARK: -

    /// 从内存里的 currentPath 找（不查库——这条路径每张图都会走一次）
    private func imageData(nodeId: String, index: Int) -> Data? {
        guard let node = viewModel?.currentPath.first(where: { $0.id == nodeId }) else { return nil }
        let segs = node.segments?.hydratedForDisplay(profileId: node.profileId) ?? []
        var seen = 0
        for seg in segs {
            if case .image(_, _, let d) = seg {
                if seen == index { return d }
                seen += 1
            }
        }
        return nil
    }

    /// 皮肤自带的图/字体。⚠️ handler 自己就是一个路径穿越面——
    /// zip 侧防了但 URL 侧裸奔等于没防（kimi 审查），所以这里再校验一次。
    private func skinFile(_ parts: [String]) -> Data? {
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        let root = ChatSkinStore.activeSkinDir.standardizedFileURL
        let target = parts.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return try? Data(contentsOf: target)
    }

    private func finish(_ task: WKURLSchemeTask, key: ObjectIdentifier, data: Data?, mime: String?) {
        guard live.contains(key) else { return }        // 已经 stop 了，再碰就崩
        guard let data, let mime else {
            live.remove(key)
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // 字体走 @font-face 是 cors 模式；主文档现在是 file:// origin，
        // 不回这个头的话皮肤字体会静默加载失败（图片不受影响，<img> 默认非 CORS）
        let headers = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "max-age=31536000",
        ]
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
        live.remove(key)
    }

    /// 按魔数认类型（附件落库时不一定带 mime，皮肤资源也没有元数据）
    private static func mime(for data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0x89, b[1] == 0x50 { return "image/png" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b[0] == 0x47, b[1] == 0x49 { return "image/gif" }
        if b[0] == 0x52, b[1] == 0x49 { return "image/webp" }
        // 字体：wOF2 / wOFF / OTTO / 0x00010000(ttf)
        if b == [0x77, 0x4F, 0x46, 0x32] { return "font/woff2" }
        if b == [0x77, 0x4F, 0x46, 0x46] { return "font/woff" }
        if b == [0x4F, 0x54, 0x54, 0x4F] { return "font/otf" }
        if b == [0x00, 0x01, 0x00, 0x00] { return "font/ttf" }
        return "application/octet-stream"
    }
}
#endif
