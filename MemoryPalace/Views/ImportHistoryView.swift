import SwiftUI
import SwiftData

/// 设置 › 数据 › 导入历史：一条记录一行，点进详情（#061）。直接放在 Section 里，每条是 List 的一行
struct ImportHistoryView: View {
    @Environment(\.settingsMetrics) private var m
    let profileId: String
    @Query private var records: [ImportRecord]

    init(profileId: String) {
        self.profileId = profileId
        _records = Query(
            filter: #Predicate<ImportRecord> { $0.profileId == profileId },
            sort: \ImportRecord.importDate,
            order: .reverse
        )
    }

    var body: some View {
        if records.isEmpty {
            Text("还没有导入记录")
                .font(m.body)
                .foregroundColor(Theme.textMuted)
                .padding(.vertical, 4)
        } else {
            ForEach(records) { record in
                SettingsNavRow(.importRecordDetail) {
                    ImportRecordDetailView(recordId: record.id, profileId: profileId)
                } label: {
                    ImportRecordRow(record: record)
                }
                #if os(macOS)
                // mac 设置窗的 path 只存 SettingsRoute（不带 id），点哪条先记下来
                .simultaneousGesture(TapGesture().onEnded { ImportRecordSelection.shared.recordId = record.id })
                #endif
            }
        }
    }
}

/// mac 设置窗：`SettingsRoute.importRecordDetail` 打开的是哪条记录
@MainActor
@Observable
final class ImportRecordSelection {
    static let shared = ImportRecordSelection()
    var recordId: UUID?
}

// MARK: - Import Record Row

struct ImportRecordRow: View {
    @Environment(\.settingsMetrics) private var m
    let record: ImportRecord

    private var providerLabel: String {
        Conversation.importedProviderName(record.provider) ?? record.provider
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.fileName)
                        .font(m.label.weight(.medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    Text(providerLabel)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.branchIndicator.opacity(0.12)))
                }
                Text("\(record.summaryText) · \(record.dateText)")
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted)
            }
            Spacer()
            if !record.supportsUndo {
                Text(record.isLegacyRecord ? "旧记录" : "不可撤回")
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

extension ImportRecord {
    var modeLabel: String {
        if isLegacyRecord { return "旧记录" }
        switch mode {
        case .merge: return "叠加导入"
        case .backfill: return "补原图"
        case .normal: return "普通导入"
        }
    }

    var summaryText: String {
        if isLegacyRecord { return "\(conversationCount) 条对话 · 暂不支持安全撤回" }
        if mode == .backfill { return "补原图 · \(nodeCount) 张，在 \(updatedConversationCount) 段对话里" }
        if addedConversationCount + updatedConversationCount + skippedConversationCount
            + ignoredConversationCount + conflictConversationCount == 0 {
            return "\(modeLabel) · 对话没有变化"
        }
        var parts = [modeLabel, "新增 \(addedConversationCount)", "更新 \(updatedConversationCount)",
                     "保持本地 \(skippedConversationCount)"]
        if conflictConversationCount > 0 { parts.append("已在其他楼层 \(conflictConversationCount)") }
        if ignoredConversationCount > 0 { parts.append("未导入 \(ignoredConversationCount)") }
        return parts.joined(separator: " · ")
    }

    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: importDate)
    }
}
