import Foundation

/// AI 和花园桌面上的网页应用（plan-webapp-as-file §2.7、§6 返工）：应用就是这一层文件库里的 html。
/// 放：`garden_app_add`；读 / 改：`garden_app_read` / `garden_app_edit`（只碰桌面应用的文件，文件库权限关着也能改，改了照样记版本；
/// 文件库权限开着的话 fs 工具也行）。都归「AI 往桌面放应用」权限域（默认每次询问）；只在 iOS 下发。
/// 走设备工具那一支（`DeviceToolDispatcher`），对话循环里不另加分支；上限在这里自己数：同一个对话 10 分钟内放 3 个，读 / 改不算
enum WebAppTools {
    static let addName = "garden_app_add"
    static let readName = "garden_app_read"
    static let editName = "garden_app_edit"
    static let names: Set<String> = [addName, readName, editName]

    static let limit = 3
    static let limitWindow: TimeInterval = 600
    static let limitMessage = "刚刚已经放了 \(limit) 个桌面应用，先停下，告诉对方做了什么"
    static let readLimit = 60_000
    @MainActor private static var recent: [String: [Date]] = [:]

    private static let appProperty: [String: Any] = [
        "type": "string", "description": "哪个应用：名字（桌面图标下面那几个字）或文件路径（如 \(WebAppStore.folderName)/喝水.html）",
    ]

    static let definition = ToolDefinition(name: addName, description: """
    把一个网页做成对方花园桌面上的全屏应用（像手机 App）：桌面上多一个图标，她点开就是这个网页铺满屏幕，没有浏览器的栏。\
    她说「做个 xx 小工具放桌面」「把这个做成 App」时用。
    应用就是她文件库里的一个 html 文件（新做的放在「\(WebAppStore.folderName)/名字.html」）。\
    要改桌面上已有的应用，别用这个再放一个新的（新的是另一个应用，数据从空开始）：用 garden_app_read 读、garden_app_edit 改。
    每个应用的存储（localStorage / IndexedDB）是各自独立的一份：两个应用就算代码一样、用同一个键名，也读不到对方存的东西。\
    你没有删应用的工具：要删让她自己长按图标 →「删除应用」，删了连它存的数据一起没了，删之前提醒她里面记的东西会跟着没。
    两种用法：给 path 把文件库里已有的 html 放到桌面；或者给 title + html 新做一个。\
    html 要是完整、自带样式和脚本的单文件（<!doctype html> 开头，写好 <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"> 和 <title>），\
    手机竖屏优先，顶部用 env(safe-area-inset-top) 让开刘海；可以从 CDN 引库，也可以引用同文件夹里的图片 / js / css；要记住的东西存 localStorage / IndexedDB，关了再开还在。\
    想要图标就在 <head> 里写 <link rel="apple-touch-icon" href="data:image/png;base64,…"> 或 svg 以外的图片网址，不写就用名字的第一个字。
    """, properties: [
        "path": ["type": "string", "description": "文件库里已有的 html 的路径（和 title + html 二选一）"] as [String: Any],
        "title": ["type": "string", "description": "新应用的名字，也是文件名，显示在图标下面，短一点（2～6 个字最好）"] as [String: Any],
        "html": ["type": "string", "description": "新应用的完整 html 文档"] as [String: Any],
    ], required: [])

    static let readDefinition = ToolDefinition(name: readName, description: """
    读桌面上一个网页应用现在的完整源码（html），改之前先读。最多 \(readLimit) 字，超了会截断并说明。
    """, properties: ["app": appProperty], required: ["app"])

    static let editDefinition = ToolDefinition(name: editName, description: """
    原地改桌面上已有的网页应用（改的就是文件库里那个 html）：图标、位置、名字不变，她存在这个应用里的东西（它自己那份 localStorage / IndexedDB）都还在，\
    把别的应用的代码搬进来只搬代码、不搬那个应用存的数据，\
    开着的话会自动刷新，改之前的样子留在版本历史里（她长按图标「历史版本」能看、能回去）。先 garden_app_read 读源码。
    两种改法：给 old_string + new_string 换掉唯一命中的一段（小改用这个）；或者给 html 整份换掉。存数据的键名别随便改，不然她以前存的东西就读不到了。
    """, properties: [
        "app": appProperty,
        "old_string": ["type": "string", "description": "要换掉的那一段原文（必须在文件里只出现一次）"] as [String: Any],
        "new_string": ["type": "string", "description": "换成什么"] as [String: Any],
        "html": ["type": "string", "description": "整份新的 html（和 old_string / new_string 二选一）"] as [String: Any],
    ], required: ["app"])

    static var definitions: [ToolDefinition] { [definition, readDefinition, editDefinition] }

    @MainActor
    static func execute(name: String, inputJSON: String, conversationId: String, now: Date = Date()) async -> (text: String, isError: Bool) {
        #if os(iOS)
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        switch name {
        case readName: return await read(args)
        case editName: return await edit(args)
        default: return await add(args, conversationId: conversationId, now: now)
        }
        #else
        return ("花园桌面只在 iPhone 上有，这台设备用不了", true)
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func add(_ args: [String: Any], conversationId: String, now: Date) async -> (text: String, isError: Bool) {
        let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let html = (args["html"] as? String) ?? ""
        guard !path.isEmpty || !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ("给 path，或者给 title + html", true) }
        guard take(conversationId, now: now) else { return (limitMessage, true) }
        do {
            if !path.isEmpty {
                let done = try await WebAppInstaller.install(path: path, title: WebAppStore.title(ofPath: path))
                let place = done.page.map { "桌面第 \($0) 页" } ?? "App 资源库「我的应用」"
                return ("已放到\(place)：\(done.app.title)（文件 \(done.app.path)）。她点图标就能打开；内容没动，要改用 garden_app_edit。", false)
            }
            let title = (args["title"] as? String) ?? WebAppHTML.title(in: html) ?? WebAppHTML.fallbackTitle
            let twin = WebAppStore.shared.apps.first { $0.title == WebAppStore.fileName(title) }
            let done = try await WebAppInstaller.install(html: html, title: title)
            let place = done.page.map { "桌面第 \($0) 页" } ?? "App 资源库「我的应用」"
            var text = "已放到\(place)：\(done.app.title)（文件 \(done.app.path)）。这是一个新应用，存的数据从空开始；以后要改它用 garden_app_edit。"
            if let twin {
                text += "\n注意：桌面上原来就有一个「\(twin.title)」，这次放的是另一个，两个各存各的数据，原来那个里她记的东西不在新的里。如果本意是改原来那个，告诉她别删原来的，用 garden_app_edit 改原来那个。"
            }
            return (text, false)
        } catch {
            return ("没放上去：\(error.localizedDescription)", true)
        }
    }

    @MainActor
    private static func read(_ args: [String: Any]) async -> (text: String, isError: Bool) {
        guard let (app, profileId) = find(args["app"] as? String) else { return (notFound(args["app"]), true) }
        guard let html = await Task.detached(operation: { try? FileLibraryStore.read(app.path, profileId: profileId) }).value else {
            return ("「\(app.title)」的文件（\(app.path)）读不出来", true)
        }
        if html.count <= readLimit { return ("「\(app.title)」（\(app.path)）现在的源码：\n\(html)", false) }
        return ("「\(app.title)」（\(app.path)）现在的源码（太长，只给前 \(readLimit) 字，共 \(html.count) 字）：\n\(html.prefix(readLimit))", false)
    }

    /// 改应用的文件：改之前那份、改之后那份都进版本历史（同 AI 文件工具），开着的应用跟着文件库的写通知刷新
    @MainActor
    private static func edit(_ args: [String: Any]) async -> (text: String, isError: Bool) {
        guard let (app, profileId) = find(args["app"] as? String) else { return (notFound(args["app"]), true) }
        let html = args["html"] as? String
        let old = args["old_string"] as? String, new = args["new_string"] as? String
        guard html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || (old?.isEmpty == false && new != nil) else {
            return ("给 old_string + new_string，或者给整份 html", true)
        }
        let actor = UserDefaults.standard.string(forKey: "assistantName").flatMap { $0.isEmpty ? nil : $0 } ?? "AI"
        let path = app.path
        do {
            try await Task.detached {
                let key = FileVersionStore.Key.file(profileId: profileId, relativePath: path)
                let before = try? FileLibraryStore.read(path, profileId: profileId)
                if let html {
                    try FileLibraryStore.write(path, content: WebAppHTML.document(html, title: app.title), profileId: profileId)
                } else if let old, let new {
                    try FileLibraryStore.edit(path, oldString: old, newString: new, profileId: profileId)
                }
                if let before { _ = try? await FileVersionStore.shared.record(key: key, content: before, source: .external) }
                if let after = try? FileLibraryStore.read(path, profileId: profileId) {
                    _ = try? await FileVersionStore.shared.record(key: key, content: after, source: .external, actor: actor)
                }
            }.value
            return ("改好了：\(app.title)（\(path)）。图标、位置、她存的东西都没动；开着的话已经自动刷新，改之前的样子在历史版本里。", false)
        } catch {
            return ("没改成：\(error.localizedDescription)", true)
        }
    }

    /// 名字或路径，只在这一层的桌面应用里找
    @MainActor
    private static func find(_ key: String?) -> (WebApp, String)? {
        let store = WebAppStore.shared
        guard let profileId = store.profileId,
              let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        let app = store.apps.first { $0.path == key } ?? store.apps.first { $0.title == key }
            ?? store.apps.first { $0.title == WebAppStore.title(ofPath: key) }
        return app.map { ($0, profileId) }
    }

    @MainActor
    private static func notFound(_ key: Any?) -> String {
        let names = WebAppStore.shared.apps.map { "「\($0.title)」（\($0.path)）" }.joined(separator: "、")
        return "桌面上没有「\(key as? String ?? "")」这个应用。现在有：\(names.isEmpty ? "（没有）" : names)"
    }
    #endif

    /// 同一个对话 10 分钟内最多 3 次
    @MainActor
    private static func take(_ conversationId: String, now: Date) -> Bool {
        let times = (recent[conversationId] ?? []).filter { now.timeIntervalSince($0) < limitWindow }
        guard times.count < limit else { return false }
        recent[conversationId] = times + [now]
        return true
    }
}
