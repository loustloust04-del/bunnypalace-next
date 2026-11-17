import MemoryCore
import Foundation

/// 重放的进度：这一趟一共要跑 `total` 句，刚跑完第 `done` 句（那条记录已经落盘）
struct MemoryLabReplayProgress {
    let done: Int
    let total: Int
    let sentenceId: String
    let record: MemoryLabRecord
}

extension MemoryLabRunner {
    /// 把一份测试集在一组参数下重放（plan-memory-lab-3 §2）：这组下还要跑的句子——没跑过的，和上次没问成的
    /// （这组下最新一条没有回复；口径同 `MemoryLabStore.runSummary` 的 `notRun`）——按集子里的顺序一句一句 `run`（不并发），
    /// 每句的记录带上这句话的键、它在哪几份测试集里、这一组的 id。每跑完一句调一次 `progress`。
    ///
    /// - `paramsId` + `params`：`MemoryLabParamSet.currentId` 配 `currentParams()`，或某一组的 id 配它存的值。
    /// - `rerunAll: true` = 整份重跑：每句都出一条新记录，旧的留着。
    /// - 停：取消调用它的那个 Task。**当前这句会跑完**（`run` 不吃取消），下一句不再开始；已经落盘的留着，
    ///   再重放一次只补剩下的。
    /// - 某一句问模型失败：照 `run` 的做法记下原因，接着跑下一句。它不算跑过，下次重放会再问它。
    /// - 只有记录写不进盘才抛错（这一趟到此为止）。
    ///
    ///       let task = Task { try await lab.replay(setId: set.id, paramsId: group.id, params: params) { p in … } }
    ///       task.cancel()   // 停
    ///
    /// 返回这一趟新出的记录（按跑的顺序）。
    @discardableResult
    func replay(setId: String, paramsId: String, params: MemoryLabParams, rerunAll: Bool = false,
                progress: @MainActor (MemoryLabReplayProgress) -> Void = { _ in }) async throws -> [MemoryLabRecord] {
        let store = store
        let pending: [(sentenceId: String, text: String, sets: [String])] = await Task.detached(priority: .userInitiated) {
            let heads = store.heads()
            var items = store.notRun(inSet: setId, paramsId: paramsId, heads: heads)
            if rerunAll {
                // 整份：集子里的每一句；那句话没存在集子里的从记录里补
                let texts = Dictionary(heads.map { ($0.sentence, $0.input.text) }, uniquingKeysWith: { _, newer in newer })
                items = (store.set(id: setId)?.items ?? []).map { item in
                    var item = item
                    if item.text == nil { item.text = texts[item.sentenceId] }
                    return item
                }
            }
            let membership = store.membership()
            return items.compactMap { item in
                guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return (item.sentenceId, text, membership[item.sentenceId] ?? [setId])
            }
        }.value
        var produced: [MemoryLabRecord] = []
        for (index, sentence) in pending.enumerated() {
            // 取消只在两句之间生效：`run` 自己不吃取消，这一句不会选到一半、问到一半
            if Task.isCancelled { break }
            let record = try await run(sentence.text, params: params, sentenceId: sentence.sentenceId, sets: sentence.sets,
                                       paramsId: paramsId)
            produced.append(record)
            progress(.init(done: index + 1, total: pending.count, sentenceId: sentence.sentenceId, record: record))
        }
        return produced
    }
}

/// 同一句话在两组参数下的两条记录比一比（plan-memory-lab-3 §2「跟「现在的设置」比」）。纯函数，不读盘。
/// 推送的东西按回执 `decision.selected` 的来源比（哪一页 / 哪张卡 / 哪条记忆条目；同一页改过版本也算同一样）。
struct MemoryLabComparison: Equatable {
    struct Side: Equatable {
        let recordId: String
        /// 只有这一边推送的
        let only: [RecallItem]
        /// 这一边主动翻了什么
        let reads: [RecallReadReceipt]
        /// 回复原样；没回话时是 nil，原因在 `error`
        let reply: String?
        let error: String?
    }

    /// 这边；nil = 这句在这边还没跑过
    let here: Side?
    /// 那边（比如「现在的设置」）；nil = 这句在那边还没跑过
    let there: Side?
    /// 两边都推送的（给的是这边那一份）
    let both: [RecallItem]

    static func make(here: MemoryLabRecord?, there: MemoryLabRecord?) -> MemoryLabComparison {
        func pushed(_ record: MemoryLabRecord?) -> [RecallItem] { record?.happened?.receipt?.decision.selected ?? [] }
        func key(_ item: RecallItem) -> String { item.source.kind.rawValue + ":" + item.source.path }
        let mine = pushed(here), theirs = pushed(there)
        let mineKeys = Set(mine.map(key)), theirKeys = Set(theirs.map(key))
        func side(_ record: MemoryLabRecord?, only: [RecallItem]) -> Side? {
            record.map {
                Side(recordId: $0.id, only: only, reads: $0.happened?.receipt?.reads ?? [],
                     reply: $0.happened?.reply, error: $0.happened?.error)
            }
        }
        return MemoryLabComparison(here: side(here, only: mine.filter { !theirKeys.contains(key($0)) }),
                                   there: side(there, only: theirs.filter { !mineKeys.contains(key($0)) }),
                                   both: mine.filter { theirKeys.contains(key($0)) })
    }
}
