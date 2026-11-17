#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import Foundation

/// 网易云音源客户端。App 里零网易代码——只认自家网关，cookie 在服务器不下发。
enum MusicLibraryClient {
    struct RemoteSong: Codable, Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Int
        var cover: String? = nil
    }
    struct Playlist: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
        var cover: String? = nil
    }
    struct SongDetail: Codable {
        let url: String?
        let lyric: String
        var translated: String? = nil
        var level: String? = nil
    }
    struct Status: Codable {
        let loggedIn: Bool
        var nickname: String? = nil
        var vip: Int? = nil
    }

    private static var base: String {
        BunnyGateway.baseURL
    }
    private static var key: String { BunnyGateway.token }

    enum RequestError: LocalizedError {
        case invalidURL
        case http(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "音源地址无法使用，请检查网关设置。"
            case .http(401), .http(403): return "音源登录或连接验证未通过，请重新连接后再试。"
            case .http(429): return "音源请求有点多，请稍后再试。"
            case .http: return "音源服务暂时不可用，请稍后重试。"
            case .invalidResponse: return "音源返回的内容无法读取，请稍后重试。"
            }
        }
    }

    /// 搜索页需要区分合法空列表和请求失败；兼容调用方仍可使用下方的可选返回方法。
    private static func request<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(string: base + path)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "key", value: key))
        comps?.queryItems = items
        guard let url = comps?.url else { throw RequestError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RequestError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RequestError.http(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RequestError.invalidResponse }
    }

    private static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async -> T? {
        try? await request(path, query)
    }

    static func failureMessage(_ error: Error) -> String {
        if let error = error as? RequestError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return "网络断开了，连上后再试一次。"
            case .timedOut: return "音源响应超时了，可以重新试试。"
            default: return "暂时连接不上音源，请检查网络后重试。"
            }
        }
        return "暂时无法加载，请稍后重试。"
    }

    private struct SongsWrap: Codable { let songs: [RemoteSong] }
    private struct ListsWrap: Codable { let playlists: [Playlist] }

    static func loadStatus() async throws -> Status { try await request("/api/music/status") }

    static func searchSongs(_ q: String) async throws -> [RemoteSong] {
        let w: SongsWrap = try await request("/api/music/search", ["q": q])
        return w.songs
    }

    static func loadPlaylists() async throws -> [Playlist] {
        let w: ListsWrap = try await request("/api/music/playlists")
        return w.playlists
    }

    static func loadSongs(inPlaylist id: String) async throws -> [RemoteSong] {
        let w: SongsWrap = try await request("/api/music/playlist/\(id)")
        return w.songs
    }

    static func status() async -> Status? { try? await loadStatus() }
    static func search(_ q: String) async -> [RemoteSong] { (try? await searchSongs(q)) ?? [] }
    static func playlists() async -> [Playlist] { (try? await loadPlaylists()) ?? [] }
    static func songs(inPlaylist id: String) async -> [RemoteSong] { (try? await loadSongs(inPlaylist: id)) ?? [] }

    /// 播放前取直链和歌词（直链有时效，每次播放前现取）
    static func detail(songId: String) async -> SongDetail? {
        await get("/api/music/song/\(songId)")
    }
}
#endif
