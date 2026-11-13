import Foundation

/// 链接直读（plan-link-direct-read）：输入框里的链接先读好，发送时当文字附件带上，所有走 API 的卡都看得到。
enum LinkRead {
    static let maxLinks = 3
    static let timeout: TimeInterval = 10
    /// 借 Mac 上 Chrome 拉 YouTube 字幕最多等多久（plan-opencli-in-app 3.4）；hub 自己 90 秒超时，链接小方块不陪它等那么久
    static let transcriptTimeout: TimeInterval = 25
    static let noTranscriptLine = "字幕：读不到（只有标题、频道、时长、简介）"

    enum Decision: Equatable { case skip, ask, read }

    enum Source: String {
        case youtube = "YouTube"
        case instagram = "Instagram"
        case web = "网页"
    }

    struct Result: Equatable {
        let url: URL
        let source: Source
        let title: String
        let body: String
        var imageData: Data? = nil
    }

    enum Failure: LocalizedError {
        case needsLogin(String)
        case empty
        case other(String)

        var errorDescription: String? {
            switch self {
            case .needsLogin: return "没登录或打不开"
            case .empty: return "没有正文"
            case .other(let msg): return msg
            }
        }
    }

    // MARK: - 找链接

    /// 草稿里的 http(s) 链接：按出现顺序、去重、最多 3 个
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        var out: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host != nil, seen.insert(url.absoluteString).inserted else { continue }
            out.append(url)
            if out.count == maxLinks { break }
        }
        return out
    }

    // MARK: - 读 / 问 / 不读（粟粟 11-09）

    static func decide(_ url: URL, webLevel: PermissionLevel, localMode: Bool, blocked: Bool, isCC: Bool) -> Decision {
        guard !isCC, webLevel != .notAllowed, !blocked, LinkPreviewStore.isPublicTarget(url) else { return .skip }
        if localMode || webLevel == .askOnce { return .ask }
        return .read
    }

    @MainActor
    static func decide(_ url: URL, isCC: Bool, profileId: String?) -> Decision {
        decide(url, webLevel: PermissionCenter.level(.webSearch, profileId: profileId), localMode: LocalMode.isOn,
               blocked: WebSearchSettings.shared.isBlocked(host: url.host), isCC: isCC)
    }

    // MARK: - 站点

    static func source(of url: URL) -> Source {
        if youtubeID(url) != nil { return .youtube }
        let host = url.host?.lowercased() ?? ""
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return .instagram }
        return .web
    }

    static func youtubeID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        let id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if parts.first == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) {
                id = parts[1]
            } else {
                id = nil
            }
        } else {
            id = nil
        }
        guard let id, id.count == 11, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    // MARK: - 读

    @MainActor
    static func read(_ url: URL) async throws -> Result {
        let source = source(of: url)
        if source == .youtube, let id = youtubeID(url) {
            async let transcript = youtubeTranscript(url)
            if let info = try? await readYouTube(id: id) {
                let body = await transcript.map { info.body.replacingOccurrences(of: noTranscriptLine, with: "字幕：\n" + $0) } ?? info.body
                return Result(url: url, source: .youtube, title: info.title, body: body)
            }
        }
        let page: InternalBrowser.ExtractedPage
        do {
            page = try await InternalBrowser.shared.read(url: url, timeout: timeout, metaFallback: true)
        } catch {
            if source == .instagram { throw Failure.needsLogin("Instagram") }
            if case InternalBrowser.BrowseError.timeout = error { throw Failure.other("超时") }
            throw Failure.other("打不开")
        }
        // IG 的配文只在页头简介里；正文那块没登录时是登录页 / 「Page not found」，不算读到
        let text = source == .instagram ? (page.metaDescription ?? "")
            : page.markdown.isEmpty ? (page.metaDescription ?? "") : page.markdown
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw source == .instagram ? Failure.needsLogin("Instagram") : Failure.empty
        }
        var lines = ["网址：\(url.absoluteString)"]
        if let byline = page.byline, !byline.isEmpty { lines.append("作者：\(byline)") }
        lines.append(source == .instagram ? "配文：\(text)" : text)
        var result = Result(url: url, source: source, title: page.title.isEmpty ? (url.host ?? url.absoluteString) : page.title,
                            body: lines.joined(separator: "\n"))
        if source == .instagram, let image = page.metaImage {
            result.imageData = await imageData(image)
        }
        return result
    }

    private static func imageData(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(WebUserAgent.platformDefault, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= PendingChatAttachment.maxImageBytes else { return nil }
        return data
    }

    // MARK: - YouTube（视频页自带的播放器数据：标题 / 频道 / 时长 / 简介；字幕见 plan 第 5 节）

    struct YouTubeInfo: Equatable {
        let title: String
        let body: String
    }

    private static func readYouTube(id: String) async throws -> YouTubeInfo {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { throw Failure.empty }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(WebUserAgent.macDesktop, forHTTPHeaderField: "User-Agent")
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8), let info = parseYouTube(html: html, url: url) else { throw Failure.empty }
        return info
    }

    static func parseYouTube(html: String, url: URL) -> YouTubeInfo? {
        guard let marker = html.range(of: "ytInitialPlayerResponse = {"),
              let json = balancedObject(in: html[html.index(before: marker.upperBound)...]),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let details = root["videoDetails"] as? [String: Any],
              let title = details["title"] as? String, !title.isEmpty else { return nil }
        var lines = ["网址：\(url.absoluteString)"]
        var meta: [String] = []
        if let author = details["author"] as? String, !author.isEmpty { meta.append("频道：\(author)") }
        if let secs = Int(details["lengthSeconds"] as? String ?? "") , secs > 0 { meta.append("时长：\(clock(secs))") }
        if !meta.isEmpty { lines.append(meta.joined(separator: "　")) }
        let description = (details["shortDescription"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("简介：" + (description.isEmpty ? "（无）" : description))
        lines.append(noTranscriptLine)
        return YouTubeInfo(title: title, body: lines.joined(separator: "\n"))
    }

    /// Mac 上开了「让 AI 用 Chrome 登录态」就经 hub 跑 `opencli youtube transcript`；没开 / 失败 / 超时给 nil
    @MainActor
    private static func youtubeTranscript(_ url: URL) async -> String? {
        guard ChromeBridgeTools.hubReady else { return nil }
        let request: [String: Any] = [
            "tool": ChromeBridgeTools.queryName, "site": "youtube", "command": "transcript",
            "args": ["url": url.absoluteString], "blocked": WebSearchSettings.shared.blockedDomains,
        ]
        let text: String? = await withCheckedContinuation { cont in
            var finished = false
            let finish: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            CCBridgeWebSocketClient.shared.opencli(request) { result in
                if case .success(let reply) = result { finish(reply.text) } else { finish(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + transcriptTimeout) { finish(nil) }
        }
        return text.flatMap(transcriptText)
    }

    /// hub 回的字幕（一行一条 `{timestamp, speaker, text}`，第一行是不可信标记）→「0:05 句子」一行一句
    static func transcriptText(_ text: String) -> String? {
        let lines = text.split(separator: "\n").compactMap { line -> String? in
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let sentence = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty else { return nil }
            let stamp = row["timestamp"] as? String ?? ""
            return stamp.isEmpty ? sentence : "\(stamp) \(sentence)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 从 `{` 起截出配平的 JSON 对象（跳过字符串里的括号）
    static func balancedObject(in text: Substring) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        for i in text.indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[text.startIndex...i]) }
            default: break
            }
        }
        return nil
    }

    static func clock(_ secs: Int) -> String {
        secs >= 3600
            ? String(format: "%d:%02d:%02d", secs / 3600, secs % 3600 / 60, secs % 60)
            : String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - 附件

    static func attachments(for result: Result) -> [PendingChatAttachment] {
        let title = result.title.replacingOccurrences(of: "/", with: "／")
        var out = [PendingChatAttachment.text(name: "已读取：\(title)", typeDescription: result.source.rawValue,
                                              extractedText: result.body, byteCount: result.body.utf8.count)]
        if let data = result.imageData,
           let image = try? PendingChatAttachment.image(name: "\(title).jpg", typeDescription: "\(result.source.rawValue) 图片",
                                                        mimeType: "image/jpeg", data: data) {
            out.append(image)
        }
        return out
    }
}
