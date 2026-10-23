import SwiftUI

/// 导入报告正文（plan §6.3，小样 09 第二台）：只有数字、相对路径、行号 / 字段、原因，不显示任何正文。
/// 放在 CalendarTicket 里用（导入流程第 ③ 步、来源列表点「报告」）。
struct SillyTavernImportReportContent: View {
    let report: SillyTavernImportReport
    @State private var showIssues = false

    private typealias P = SillyTavernImportPresentation

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundColor(Theme.branchIndicator)
                    .accessibilityHidden(true)
                Text(report.isReimport ? "已重新核对一遍" : "资料已经安放好")
                    .font(.system(size: 19, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Text(P.headline(report)).font(.system(size: 13)).foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                Text("来源「\(report.sourceName)」").font(.system(size: 12)).foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, IOSCal.pad)
            .padding(.top, 14)

            TicketNotch()
            IOSSubLabel(text: "按文件类别")
            categoryTable
            ForEach(P.categoryFootnotes(report), id: \.self) { note($0) }

            IOSSubLabel(text: "内容")
            ForEach(P.contentRows(report)) { valueRow($0.title, $0.value) }

            let objects = P.objectRows(report)
            IOSSubLabel(text: "新建的东西")
            if objects.isEmpty {
                note("这次没有新建任何东西")
            }
            ForEach(objects) { valueRow($0.title, $0.value) }

            TicketNotch()
            issuesSection
            TicketNotch()
            note("✓ 表示资料已导入或保留，导入完成不代表卡里的脚本都能用。")
            ForEach(report.warnings, id: \.self) { note($0) }
        }
    }

    private var categoryTable: some View {
        let rows = P.categoryRows(report)
        return Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 8) {
            GridRow {
                Text("类别").gridColumnAlignment(.leading)
                Text("源"); Text("新建"); Text("跳过"); Text("仅归档"); Text("失败"); Text("未支持")
            }
            .font(.system(size: 11)).foregroundColor(Theme.textMuted)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows) { row in
                GridRow {
                    Text(row.title).foregroundColor(Theme.textPrimary).lineLimit(2).gridColumnAlignment(.leading)
                    cell(row.source, strong: true)
                    cell(row.created)
                    cell(row.skipped)
                    cell(row.archivedOnly)
                    cell(row.failed, danger: true)
                    cell(row.unsupported)
                }
                .font(.system(size: 13))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.title)：源 \(row.source)，新建 \(row.created)，跳过 \(row.skipped)，仅归档 \(row.archivedOnly)，失败 \(row.failed)，未支持 \(row.unsupported)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, IOSCal.pad)
        .padding(.vertical, 8)
    }

    private func cell(_ value: Int, strong: Bool = false, danger: Bool = false) -> some View {
        Text(value == 0 ? "·" : "\(value)")
            .monospacedDigit()
            .fontWeight(strong ? .medium : .regular)
            .foregroundColor(value == 0 ? Theme.textMuted.opacity(0.6) : (danger ? Theme.danger : Theme.textPrimary))
    }

    @ViewBuilder
    private var issuesSection: some View {
        let issues = P.issueRows(report)
        Button { showIssues.toggle() } label: {
            HStack {
                Text("查看问题（\(issues.count)）").font(.system(size: 15, weight: .medium))
                    .foregroundColor(issues.isEmpty ? Theme.textMuted : Theme.branchIndicator)
                Spacer()
                Image(systemName: showIssues ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, IOSCal.pad).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(issues.isEmpty)
        if showIssues {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.location).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textPrimary)
                        .lineLimit(2).truncationMode(.middle)
                    Text("原因：\(issue.reason)").font(.system(size: 12)).foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("处理：\(issue.action)" + (issue.retryable ? " · 可以重试" : ""))
                        .font(.system(size: 12)).foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IOSCal.pad).padding(.vertical, 8)
                IOSHairline()
            }
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 14)).monospacedDigit().foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, IOSCal.pad).padding(.vertical, 10)
            IOSHairline()
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IOSCal.pad).padding(.top, 6)
    }
}

/// 来源列表里点「报告」：独立一页
struct SillyTavernReportSheet: View {
    let report: SillyTavernImportReport
    let onGoToWall: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    CalendarTicket {
                        SillyTavernImportReportContent(report: report)
                        Color.clear.frame(height: 12)
                    }
                    Button { onGoToWall(); dismiss() } label: {
                        Text("去卡墙看看").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
                .padding(.vertical, 12)
            }
            .background(Theme.sidebarBg)
            .navigationTitle("导入报告")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 680)
        #endif
    }
}

/// 撤回结果：逐项列删 / 留 / 已不在 + 原因
struct SillyTavernRetractResultSheet: View {
    let report: SillyTavernRetractReport
    @Environment(\.dismiss) private var dismiss

    private typealias P = SillyTavernImportPresentation

    var body: some View {
        NavigationStack {
            ScrollView {
                CalendarTicket {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("撤回完成").font(.system(size: 19, weight: .semibold)).foregroundColor(Theme.textPrimary)
                        Text(P.retractSummary(report)).font(.system(size: 13)).foregroundColor(Theme.textMuted)
                    }
                    .padding(.horizontal, IOSCal.pad).padding(.top, 16)
                    ForEach(P.retractGroups(report)) { group in
                        IOSSubLabel(text: group.title)
                        ForEach(group.items) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.system(size: 14)).foregroundColor(Theme.textPrimary)
                                    .lineLimit(2).truncationMode(.middle)
                                Text(line.reason).font(.system(size: 12)).foregroundColor(Theme.textMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, IOSCal.pad).padding(.vertical, 8)
                            IOSHairline()
                        }
                    }
                    Text("原件和导入报告都还在；留下的东西保持你改过的样子，不会被还原。")
                        .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                        .padding(.horizontal, IOSCal.pad).padding(.vertical, 12)
                }
                .padding(.vertical, 12)
            }
            .background(Theme.sidebarBg)
            .navigationTitle("撤回结果")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }
}

/// 卡库设置「酒馆整包」一组：导入入口 + 来源列表（名字、批次时间、对象数、报告、撤回）
struct SillyTavernImportSettingsSection: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(GlobalWorldBookManager.self) private var globalBooks: GlobalWorldBookManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?

    /// 撤回时上层挂遮罩
    @Binding var busyText: String?

    private typealias P = SillyTavernImportPresentation

    private struct ReportItem: Identifiable {
        let id: String
        let report: SillyTavernImportReport
    }

    private struct RetractTarget: Identifiable {
        var id: String { batchId }
        let sourceId: String
        let batchId: String
    }

    private struct RetractItem: Identifiable {
        let id = UUID()
        let report: SillyTavernRetractReport
    }

    @State private var sources: [ImportSource] = []
    @State private var pendingBatch = false
    @State private var showImport = false
    @State private var viewingReport: ReportItem?
    @State private var confirmRetract: RetractTarget?
    @State private var retractResult: RetractItem?
    @State private var message: String?

    private var environment: SillyTavernImportCommitter.Environment? {
        SillyTavernImportManagers(profiles: profileManager, presets: presetManager, cards: cardManager, globalBooks: globalBooks).environment
    }

    var body: some View {
        VStack(spacing: 0) {
            IOSCalendarRow(icon: "archivebox", title: "导入酒馆整包") { showImport = true }
            if pendingBatch {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上次导入没收尾").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.danger)
                    Button("去恢复") { recover() }.font(.system(size: 14)).tint(Theme.branchIndicator).frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IOSCal.pad).padding(.top, 6)
            }
            note("选「下载全部数据」的压缩包或 data/default-user 文件夹；先关掉酒馆再导。")
            IOSSubLabel(text: "导入来源")
            if sources.isEmpty { note("还没有导入过") }
            ForEach(sources) { source in sourceBlock(source) }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showImport, onDismiss: reload) { SillyTavernImportFlowView() }
        .sheet(item: $viewingReport) { item in
            SillyTavernReportSheet(report: item.report) {
                let cardId = P.firstCardId(source: ImportSourceStore.shared.source(id: item.report.sourceId), batchId: item.report.batchId)
                navigator?.pendingTarget = .init(tool: "cardLibrary", id: cardId ?? "tab:characters")
            }
        }
        .sheet(item: $retractResult) { item in SillyTavernRetractResultSheet(report: item.report) }
        .confirmationDialog("撤回这次导入？", isPresented: Binding(get: { confirmRetract != nil }, set: { if !$0 { confirmRetract = nil } }),
                            titleVisibility: .visible, presenting: confirmRetract) { target in
            Button("撤回", role: .destructive) { retract(target) }
            Button("取消", role: .cancel) {}
        } message: { _ in Text(P.retractConfirmMessage) }
        .alert("酒馆整包", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好的") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func sourceBlock(_ source: ImportSource) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shippingbox").font(.system(size: 12)).foregroundColor(Theme.textMuted).frame(width: 20)
                Text(source.name).font(.system(size: 16, weight: .medium)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(source.batches.count) 次").font(.system(size: 13)).foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, IOSCal.pad).frame(minHeight: 44)
            ForEach(P.batchRows(source)) { row in
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(P.batchSubtitle(row)).font(.system(size: 13)).foregroundColor(Theme.textMuted)
                        HStack(spacing: 16) {
                            Button("报告") { openReport(row) }
                                .font(.system(size: 14)).tint(Theme.branchIndicator)
                            if row.retractedAt == nil && row.objectCount > 0 {
                                Button("撤回这次导入") { confirmRetract = .init(sourceId: source.id, batchId: row.id) }
                                    .font(.system(size: 14)).tint(Theme.danger)
                            }
                            Spacer()
                        }
                        .buttonStyle(.borderless)
                        .frame(minHeight: 32)
                    }
                    .padding(.leading, IOSCal.pad + 32).padding(.trailing, IOSCal.pad).padding(.vertical, 6)
                    IOSHairline(leading: IOSCal.pad + 32)
                }
            }
        }
    }

    private func reload() {
        sources = ImportSourceStore.shared.sources.sorted { $0.updatedAt > $1.updatedAt }
        pendingBatch = (try? ImportSourceStore.shared.pendingBatch()) != nil
    }

    private func openReport(_ row: P.BatchRow) {
        do {
            viewingReport = .init(id: row.id, report: try ImportSourceStore.shared.readReport(SillyTavernImportReport.self, file: row.reportFile))
        } catch {
            message = "报告读不出来：\(error.localizedDescription)"
        }
    }

    private func retract(_ target: RetractTarget) {
        guard let env = environment else { return }
        busyText = "正在撤回"
        SillyTavernImportGate.shared.isBusy = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            defer {
                busyText = nil
                SillyTavernImportGate.shared.isBusy = false
                reload()
            }
            do {
                retractResult = .init(report: try SillyTavernImportCommitter.retract(sourceId: target.sourceId, batchId: target.batchId, env: env))
            } catch {
                message = P.failure(error).message.replacingOccurrences(of: "这次没有导入任何东西。", with: "这次什么都没删。")
            }
        }
    }

    private func recover() {
        guard let env = environment else { return }
        busyText = "正在恢复上次导入"
        SillyTavernImportGate.shared.isBusy = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            defer {
                busyText = nil
                SillyTavernImportGate.shared.isBusy = false
                reload()
            }
            do { message = P.recoveryText(try SillyTavernImportCommitter.recover(env: env)) }
            catch { message = "恢复没完成：\(error.localizedDescription)。下次打开 app 会再试。" }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IOSCal.pad).padding(.top, 6)
    }
}
