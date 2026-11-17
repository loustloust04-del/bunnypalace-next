import MemoryCore
import Foundation

/// 本机执行入口。跑在本楼层真记忆上的重放还没接，先如实拒绝。
/// 纯函数 / 偏好隔离在包里（`MemoryCore.Services.MemoryBench`）。
extension MemoryBenchLocalExecutor {
    static func execute(testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) async throws -> String {
        throw Failure("本楼层的题现在还不能跑")
    }
}
