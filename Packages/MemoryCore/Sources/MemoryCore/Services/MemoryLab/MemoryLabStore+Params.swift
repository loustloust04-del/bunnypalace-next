import Foundation

/// 存下来的参数组（plan-memory-lab-3 §1）：`<楼层记忆根>/lab/params/<编号>.json`，一组一个文件。
/// 删一组不删记录：记录上的 `paramsId` 指向一个已经没有的组时，那次的参数值还在记录自己的 `params` 里。
public extension MemoryLabStore {
    private func paramsURL(_ id: String) -> URL {
        paramsDir.appendingPathComponent(MemoryBenchStore.fileName(id) + ".json")
    }

    private func readParams(_ url: URL) -> MemoryLabParamSet? {
        (try? Data(contentsOf: url)).flatMap { try? MemoryBench.decoder.decode(MemoryLabParamSet.self, from: $0) }
    }

    /// 没有 / 读不成 = nil（「现在的设置」不在盘上，也是 nil）
    func paramSet(id: String) -> MemoryLabParamSet? {
        readParams(paramsURL(id))
    }

    /// 存过的各组，按存的先后（同一刻按编号）；读不成的跳过。不含「现在的设置」
    func paramSets() -> [MemoryLabParamSet] {
        ((try? FileManager.default.contentsOfDirectory(at: paramsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.compactMap(readParams)
            .sorted {
                let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
                return a != b ? a < b : $0.id < $1.id
            }
    }

    /// 整份写一组（`currentId` 不能存）
    func save(_ paramSet: MemoryLabParamSet) throws {
        guard paramSet.id != MemoryLabParamSet.currentId else { throw StoreError.paramsExists(paramSet.id) }
        try FileManager.default.createDirectory(at: paramsDir, withIntermediateDirectories: true)
        try MemoryBench.encoder.encode(paramSet).write(to: paramsURL(paramSet.id), options: .atomic)
    }

    /// 存成一组。存的是值：`differences` 不存
    @discardableResult
    func createParamSet(name: String, params: MemoryLabRecord.Params, id: String = UUID().uuidString,
                        at: Date = MemoryBench.now()) throws -> MemoryLabParamSet {
        guard id != MemoryLabParamSet.currentId, !FileManager.default.fileExists(atPath: paramsURL(id).path) else {
            throw StoreError.paramsExists(id)
        }
        var values = params
        values.differences = nil
        let paramSet = MemoryLabParamSet(id: id, name: name, createdAt: at, params: values)
        try save(paramSet)
        return paramSet
    }

    @discardableResult
    func renameParamSet(id: String, name: String) throws -> MemoryLabParamSet {
        guard var paramSet = paramSet(id: id) else { throw StoreError.missingParams(id) }
        guard (paramSet.schema ?? 1) <= Self.schema else { throw StoreError.newerParamsSchema(id) }
        paramSet.name = name
        try save(paramSet)
        return paramSet
    }

    /// 只删这一组的文件，不动记录。本来就没有 = 不算错
    func deleteParamSet(id: String) throws {
        let url = paramsURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
