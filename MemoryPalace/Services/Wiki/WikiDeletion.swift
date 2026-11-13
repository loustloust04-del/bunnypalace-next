import MemoryCore
import Foundation
import SwiftData

extension WikiStore {
    struct DeletionReceipt: Codable, Equatable, Identifiable, Sendable {
        enum Phase: String, Codable, Sendable { case prepared, deleted, restored }
        var id: String = UUID().uuidString
        var path: String
        var title: String
        var deletedAt: Date
        var deletedVersion: String
        var historyEntry: String
        var phase: Phase = .prepared
        var restoredAt: Date?
        var reason: String?

        // 只读核账结果，不写入收据。
        var incomplete = false
        var problem: String?
        enum CodingKeys: String, CodingKey {
            case id, path, title, deletedAt, deletedVersion, historyEntry, phase, restoredAt, reason
        }
    }

    struct DeletionOutcome: Sendable {
        var receipt: DeletionReceipt
        var indexError: String?

        var warning: String? {
            let indexWarning = indexError.map { "正文已提交，索引更新失败：\($0)" }
            guard let problem = receipt.problem else { return indexWarning }
            let receiptWarning = "正文已提交，\(problem)"
            return indexWarning.map { receiptWarning + "\n" + $0 } ?? receiptWarning
        }
    }

    struct DeletionFailure: LocalizedError {
        let receipt: DeletionReceipt
        let message: String
        var errorDescription: String? { message }
    }

    private static let deletedFolder = [historyFolder, ".deleted"]

    private func writeDeletion(_ receipt: DeletionReceipt) throws {
        try beforeWrite?((Self.deletedFolder + [receipt.id + ".json"]).joined(separator: "/"))
        try SafeWiki.write(JSONEncoder().encode(receipt), name: receipt.id + ".json", in: Self.deletedFolder, under: root)
    }

    private func readDeletion(id: String) throws -> DeletionReceipt {
        let dir = try SafeWiki.folder(Self.deletedFolder, under: root, create: false)
        let url = try SafeWiki.file(id + ".json", in: dir)
        let receipt = try JSONDecoder().decode(DeletionReceipt.self, from: Data(contentsOf: url))
        guard receipt.id == id, Self.isValidPagePath(receipt.path),
              !receipt.historyEntry.isEmpty, !receipt.historyEntry.contains("/"), !receipt.historyEntry.contains("\\"),
              receipt.historyEntry.hasSuffix(".md"), receipt.deletedVersion.count == 64 else {
            throw WikiError.conflict(id, "收据损坏")
        }
        return receipt
    }

    private func deletionData(_ receipt: DeletionReceipt) throws -> Data {
        let dir: URL
        do {
            dir = try SafeWiki.folder([Self.historyFolder] + receipt.path.split(separator: "/").map(String.init), under: root, create: false)
        } catch SafeWiki.PathError.missing {
            throw WikiError.conflict(receipt.path, "历史副本缺失")
        }
        let url = try SafeWiki.file(receipt.historyEntry, in: dir)
        guard try SafeWiki.itemType(url) != nil else { throw WikiError.conflict(receipt.path, "历史副本缺失") }
        let data = try Data(contentsOf: url)
        guard Self.version(of: data) == receipt.deletedVersion else {
            throw WikiError.conflict(receipt.path, "历史副本版本不符")
        }
        return data
    }

    private func liveDeletionVersion(_ path: String) throws -> String? {
        let url: URL
        do { url = try checkedPageURL(path) }
        catch SafeWiki.PathError.missing { return nil }
        guard try SafeWiki.itemType(url) != nil else { return nil }
        return Self.version(of: try Data(contentsOf: url))
    }

    /// 同楼层锁内调用；先存确切前像和 prepared 收据，才允许移除活页；移除后的收据 / 索引失败只随 outcome 返回。
    @discardableResult
    func delete(_ path: String, expectedVersion: String, now: Date = Date(), reason: String? = nil,
                rebuildingIndexes: Bool = true,
                beforeRemove: @Sendable (URL) throws -> Void = { _ in }) throws -> DeletionOutcome {
        MainThreadIO.assertOffMain(.write, "WikiStore.delete")
        guard try liveDeletionVersion(path) == expectedVersion else {
            throw WikiError.conflict(path, "页后来改过 / 被删，先处理")
        }
        var stage = "保存删除前像"
        do {
            guard let entry = try snapshotCurrent(path, now: now) else {
                throw WikiError.conflict(path, "页后来改过 / 被删，先处理")
            }
            let receipt = DeletionReceipt(path: path, title: read(path)?.title ?? path, deletedAt: now,
                                          deletedVersion: expectedVersion, historyEntry: entry, reason: reason)
            stage = "持久删除收据"
            try writeDeletion(receipt)
            return try finishDeletion(receipt, rebuildingIndexes: rebuildingIndexes, beforeRemove: beforeRemove)
        } catch {
            if error is DeletionFailure { throw error }
            if case WikiError.conflict = error { throw error }
            throw WikiError.conflict(path, "\(stage)：\(error.localizedDescription)")
        }
    }

    private func finishDeletion(_ initial: DeletionReceipt, rebuildingIndexes: Bool = true,
                                beforeRemove: @Sendable (URL) throws -> Void = { _ in }) throws -> DeletionOutcome {
        let url: URL
        do {
            url = try checkedPageURL(initial.path)
            try beforeRemove(url)
            guard try liveDeletionVersion(initial.path) == initial.deletedVersion else {
                throw WikiError.conflict(initial.path, "页后来改过 / 被删，先处理")
            }
            try FileManager.default.removeItem(at: url)
        } catch {
            throw DeletionFailure(receipt: initial, message: "删除活页：\(error.localizedDescription)")
        }
        // 索引重建失败也必须撤掉缓存 / 召回里的旧活页。
        defer {
            WikiInjectionCache.shared.invalidate()
            CatalogRecallIndexer.shared.changed(at: url)
        }
        var receipt = initial
        receipt.phase = .deleted
        receipt.incomplete = false
        do { try writeDeletion(receipt) }
        catch {
            receipt.phase = .prepared
            receipt.problem = "提交删除收据失败：\(error.localizedDescription)"
        }
        var indexError: String?
        if rebuildingIndexes {
            do { try rebuildIndexes(affecting: [receipt.path]) }
            catch { indexError = error.localizedDescription }
        }
        return DeletionOutcome(receipt: receipt, indexError: indexError)
    }

    @discardableResult
    func continueDeletion(id: String) throws -> DeletionOutcome {
        MainThreadIO.assertOffMain(.write, "WikiStore.continueDeletion")
        let receipt = try readDeletion(id: id)
        guard receipt.phase == .prepared, try liveDeletionVersion(receipt.path) == receipt.deletedVersion else {
            throw WikiError.conflict(receipt.path, "页后来改过 / 被删，不能继续删除")
        }
        _ = try deletionData(receipt)
        return try finishDeletion(receipt)
    }

    func cancelDeletion(id: String) throws {
        MainThreadIO.assertOffMain(.write, "WikiStore.cancelDeletion")
        let receipt = try readDeletion(id: id)
        guard receipt.phase == .prepared else {
            throw WikiError.conflict(receipt.path, "只能丢弃未生效的删除收据")
        }
        try SafeWiki.remove(id + ".json", in: Self.deletedFolder, under: root)
    }

    func deletion(id: String) -> DeletionReceipt {
        do {
            var receipt = try readDeletion(id: id)
            guard receipt.phase != .restored else { return receipt }
            let live = try liveDeletionVersion(receipt.path)
            if live != nil {
                if receipt.phase == .prepared {
                    receipt.incomplete = true
                    receipt.problem = "删除未生效 · 页后来改过"
                    return receipt
                }
                receipt.problem = "已有同名页"
            } else {
                receipt.phase = .deleted
            }
            _ = try deletionData(receipt)
            return receipt
        } catch {
            if var receipt = try? readDeletion(id: id) {
                receipt.problem = error.localizedDescription
                return receipt
            }
            return DeletionReceipt(id: id, path: "", title: "收据损坏", deletedAt: .distantPast,
                                   deletedVersion: "", historyEntry: "", problem: "收据损坏：\(error.localizedDescription)")
        }
    }

    /// 新→旧；坏收据保留一行诊断，不能 compactMap 掉当成没有删除记录。
    func deletions() -> [DeletionReceipt] {
        MainThreadIO.assertOffMain(.enumerate, "WikiStore.deletions")
        do {
            let dir = try SafeWiki.folder(Self.deletedFolder, under: root, create: false)
            return try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".json") }
                .map { deletion(id: String($0.dropLast(5))) }
                .sorted { $0.deletedAt == $1.deletedAt ? $0.id > $1.id : $0.deletedAt > $1.deletedAt }
        } catch SafeWiki.PathError.missing {
            return []
        } catch {
            return [DeletionReceipt(id: "unreadable", path: "", title: "收据损坏", deletedAt: .distantPast,
                                    deletedVersion: "", historyEntry: "", problem: "收据损坏：\(error.localizedDescription)")]
        }
    }

    /// 只读收据 JSON，不读取或校验历史副本；用于缺页提示，不代表副本可恢复。
    func hasDeletionReceipt(for path: String) -> Bool {
        MainThreadIO.assertOffMain(.enumerate, "WikiStore.hasDeletionReceipt")
        guard Self.isValidPagePath(path),
              let dir = try? SafeWiki.folder(Self.deletedFolder, under: root, create: false),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return files.contains { file in
            guard file.hasSuffix(".json"), let receipt = try? readDeletion(id: String(file.dropLast(5))) else { return false }
            return receipt.path == path && receipt.phase != .restored
        }
    }

    func unavailablePageMessage(_ path: String) -> String? {
        guard !pageExists(path) else { return nil }
        return hasDeletionReceipt(for: path) ? "原整理页已删除" : "目标页不可用"
    }

    /// 只从收据指向的精确副本恢复；任何同名活页（即使字节相同）都不能覆盖。
    func restoreDeleted(id: String, now: Date = Date()) throws {
        MainThreadIO.assertOffMain(.write, "WikiStore.restoreDeleted")
        var receipt = try readDeletion(id: id)
        guard receipt.phase != .restored else { throw WikiError.conflict(receipt.path, "这页已经恢复，不能再次恢复") }
        guard try liveDeletionVersion(receipt.path) == nil else { throw WikiError.conflict(receipt.path, "已有同名页") }
        let data = try deletionData(receipt)
        var stage = "恢复活页"
        do {
            let url = try checkedPageURL(receipt.path, create: true)
            try beforeWrite?(receipt.path + ".md")
            try Self.writeAtomic(data, to: url)
            stage = "提交恢复收据"
            receipt.phase = .restored
            receipt.restoredAt = now
            try writeDeletion(receipt)
            stage = "重建恢复索引"
            try rebuildIndexes(affecting: [receipt.path])
        } catch {
            throw WikiError.conflict(receipt.path, "\(stage)：\(error.localizedDescription)")
        }
    }

    func incomingLinkCount(to path: String) -> Int {
        MainThreadIO.assertOffMain(.enumerate, "WikiStore.incomingLinkCount")
        return SafeWiki.scan(self, memoryRoot: root.deletingLastPathComponent()).pages
            .filter { $0.page.links.contains { $0.target == path } }.count
    }
}

extension CatalogMaterial {
    /// 人工解除这一张碎片的归页；不清审计 / 驳回等资格，不触发自动整理或改提案。
    @MainActor
    static func releaseOrganization(_ memory: Memory, expectedPage: String, profileId: String, context: ModelContext) throws {
        guard memory.profileId == profileId, memory.organizedPage == expectedPage else {
            throw WikiStore.WikiError.conflict(expectedPage, "碎片归页后来改过，请重新查看")
        }
        let at = memory.organizedAt
        memory.organizedPage = nil
        memory.organizedAt = nil
        do { try context.save() }
        catch {
            memory.organizedPage = expectedPage
            memory.organizedAt = at
            throw error
        }
    }
}
