#if os(iOS)
// [Bunny] 一起听：自大肥兔（7f2c6c4df）移植。Song 存在兔兔自己的 SwiftData 容器（BunnyMusicStore），不进上游 schema；网关地址 / 口令改读 BunnyGateway。
import Foundation
import Observation

/// 曲库的异步状态；只读曲库，不触碰播放器或共听通道。
@MainActor
@Observable
final class MusicLibraryBrowser {
    enum LoadState<Value> {
        case idle
        case loading
        case loaded(Value)
        case failed(String)
    }

    struct Catalogue {
        let status: MusicLibraryClient.Status
        let playlists: [MusicLibraryClient.Playlist]
    }

    private(set) var catalogue: LoadState<Catalogue> = .idle
    private(set) var search: LoadState<[MusicLibraryClient.RemoteSong]> = .idle
    private(set) var playlist: LoadState<[MusicLibraryClient.RemoteSong]> = .idle
    private(set) var submittedQuery: String?
    private(set) var openedList: MusicLibraryClient.Playlist?

    @ObservationIgnored private var catalogueTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var playlistTask: Task<Void, Never>?
    @ObservationIgnored private var catalogueID = UUID()
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var playlistID = UUID()

    func start() {
        stop()
        reloadCatalogue()
    }

    func reloadCatalogue() {
        catalogueTask?.cancel()
        let requestID = UUID()
        catalogueID = requestID
        catalogue = .loading
        catalogueTask = Task { [weak self] in
            do {
                let status = try await MusicLibraryClient.loadStatus()
                try Task.checkCancellation()
                let playlists: [MusicLibraryClient.Playlist]
                if status.loggedIn { playlists = try await MusicLibraryClient.loadPlaylists() }
                else { playlists = [] }
                guard let self, !Task.isCancelled, self.catalogueID == requestID else { return }
                self.catalogue = .loaded(Catalogue(status: status, playlists: playlists))
            } catch {
                guard let self, !Task.isCancelled, self.catalogueID == requestID else { return }
                self.catalogue = .failed(MusicLibraryClient.failureMessage(error))
            }
        }
    }

    func inputChanged(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != submittedQuery { clearSearch() }
    }

    func runSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clearSearch()
        guard !query.isEmpty else { return }
        let requestID = UUID()
        searchID = requestID
        submittedQuery = query
        search = .loading
        searchTask = Task { [weak self] in
            do {
                let songs = try await MusicLibraryClient.searchSongs(query)
                guard let self, !Task.isCancelled, self.searchID == requestID else { return }
                self.search = .loaded(songs)
            } catch {
                guard let self, !Task.isCancelled, self.searchID == requestID else { return }
                self.search = .failed(MusicLibraryClient.failureMessage(error))
            }
        }
    }

    func clearSearch() {
        searchID = UUID()
        searchTask?.cancel()
        searchTask = nil
        submittedQuery = nil
        search = .idle
    }

    func open(_ list: MusicLibraryClient.Playlist) {
        clearSearch()
        playlistTask?.cancel()
        let requestID = UUID()
        playlistID = requestID
        openedList = list
        playlist = .loading
        playlistTask = Task { [weak self] in
            do {
                let songs = try await MusicLibraryClient.loadSongs(inPlaylist: list.id)
                guard let self, !Task.isCancelled, self.playlistID == requestID else { return }
                self.playlist = .loaded(songs)
            } catch {
                guard let self, !Task.isCancelled, self.playlistID == requestID else { return }
                self.playlist = .failed(MusicLibraryClient.failureMessage(error))
            }
        }
    }

    func closePlaylist() {
        playlistID = UUID()
        playlistTask?.cancel()
        playlistTask = nil
        openedList = nil
        playlist = .idle
    }

    /// 离页或切 profile 后，任务取消和请求标识同时失效，迟到结果无权改 UI。
    func stop() {
        catalogueID = UUID()
        catalogueTask?.cancel()
        catalogueTask = nil
        catalogue = .idle
        clearSearch()
        closePlaylist()
    }
}
#endif
