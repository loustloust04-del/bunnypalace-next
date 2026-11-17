import MemoryCore
import Foundation

extension WikiStore {
    init(profileId: String) {
        self.init(root: FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent("wiki", isDirectory: true))
    }

    /// 启动后每层楼一次（`CatalogRunner.attach`）：旧摆法 `楼层/…` 下的页搬到现在的位置。没有旧文件夹 = 后台看一眼就回，不取锁、不写；
    /// 搬了才在记忆日志留一行（只有数量）
    @MainActor
    static func relocateLegacyLayout(profileId: String, user: String) async {
        let found = await Task.detached(priority: .utility) { () -> (root: URL, wiki: WikiStore)? in
            let root = FileLibraryStore.memoryRoot(profileId: profileId)
            let wiki = WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true))
            return wiki.hasLegacyLayout ? (root, wiki) : nil
        }.value
        guard let found else { return }
        let done = try? await WikiProposalReview.exclusive(wiki: found.wiki) {
            await Task.detached(priority: .utility) { found.wiki.relocateLegacyLayout(user: user) }.value
        }
        guard let done, let note = done.logNote else { return }
        MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: done.skipped[.failed] == nil && !done.indexFailed, note: note, model: "",
                              memoryRoot: found.root)
    }
}

extension CatalogRecallIndexer {
    func deleteProfile(_ profileId: String, wiki: WikiStore? = nil) {
        deleteProfile(profileId, wiki: wiki, fallback: { WikiStore(profileId: profileId) })
    }
}
