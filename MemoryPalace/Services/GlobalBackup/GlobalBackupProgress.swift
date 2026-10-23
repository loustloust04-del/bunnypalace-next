import Foundation
import SwiftUI

// MARK: - Global Backup Progress
//
// @MainActor ObservableObject，UI 订阅。Export/Import 流程按 section 报进度。
// section 名见 1.1 包结构。

@MainActor
final class GlobalBackupProgress: ObservableObject {
    @Published var currentSection: String = ""
    @Published var sectionFraction: Double = 0   // 0..1 当前 section 进度
    @Published var overallFraction: Double = 0   // 0..1 全流程进度（按 weights 加权）

    /// 各 section 的权重（导出时用）
    static let exportSectionWeights: [String: Double] = [
        "config":          0.02,
        "userdefaults":    0.03,
        "swiftdata":       0.40,
        "stickers":        0.20,
        "audiobooks":      0.15,
        "themes":          0.02,
        "filelibrary":     0.13,
        "manifest+zip":    0.05,
    ]

    /// 各 section 的权重（导入 staging 阶段用）
    static let importStagingSectionWeights: [String: Double] = [
        "validate":        0.05,
        "swiftdata":       0.40,
        "userdefaults":    0.05,
        "stickers":        0.20,
        "audiobooks":      0.15,
        "themes":          0.02,
        "filelibrary":     0.13,
    ]

    /// 各 section 的权重（PendingImportApplier 用）
    static let pendingApplySectionWeights: [String: Double] = [
        "phase1":          0.40,  // archive 主位
        "phase2":          0.55,  // install staging
        "cleanup":         0.05,
    ]

    private var sectionWeights: [String: Double] = [:]
    private var completedSections: Set<String> = []

    func reset(mode: Mode) {
        currentSection = ""
        sectionFraction = 0
        overallFraction = 0
        completedSections.removeAll()
        switch mode {
        case .export:        sectionWeights = Self.exportSectionWeights
        case .importStaging: sectionWeights = Self.importStagingSectionWeights
        case .pendingApply:  sectionWeights = Self.pendingApplySectionWeights
        }
    }

    func beginSection(_ name: String) {
        currentSection = name
        sectionFraction = 0
        recomputeOverall()
    }

    func updateSection(_ name: String, fraction: Double) {
        currentSection = name
        sectionFraction = max(0, min(1, fraction))
        recomputeOverall()
    }

    func completeSection(_ name: String) {
        completedSections.insert(name)
        sectionFraction = 1
        recomputeOverall()
    }

    private func recomputeOverall() {
        var total: Double = 0
        for (name, weight) in sectionWeights {
            if completedSections.contains(name) {
                total += weight
            } else if name == currentSection {
                total += weight * sectionFraction
            }
        }
        overallFraction = max(0, min(1, total))
    }

    enum Mode {
        case export
        case importStaging
        case pendingApply
    }
}
