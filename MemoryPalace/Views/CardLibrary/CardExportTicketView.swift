import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 卡库第二批 B7（小样 05）：导出小票。三段票根——卡面与身份 / 带不带这里改过的世界书和正则 / 出口（PNG、JSON）。
/// 导出在后台线程写，出口段就地换成珠串进度 + 取消；写完读回核对，再走系统存储面板（同「导出 JSON」）。
struct CardExportTicketView: View {
    let card: CharacterCard
    /// 卡库里的卡（有原 PNG / 原 JSON）；楼层卡（没绑卡的楼层）是 false
    let isLibraryCard: Bool
    let profile: Profile?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var status: Status?
    @State private var includeEdits = true
    @State private var job = CardExportJob()
    @State private var document: CardExportDocument?
    @State private var exporterPresented = false
    @State private var errorMessage: String?

    /// 进页算一次：字段改没改、我们这边的世界书 / 正则改动、卡面来源和预览
    struct Status {
        var fieldsChanged: Bool
        var edits: CardExportEdits
        var source: TavernCardExport.ImageSource
        var preview: Data?
    }

    private var hasEdits: Bool { status.map { !$0.edits.isEmpty } ?? false }
    private var changed: Bool { (status?.fieldsChanged ?? false) || (includeEdits && hasEdits) }

    var body: some View {
        NavigationStack {
            ScrollView {
                CalendarTicket {
                    identity.opacity(job.kind == nil ? 1 : 0.45)
                    TicketNotch()
                    if hasEdits || !(status?.edits.notes.isEmpty ?? true) {
                        editsSection.opacity(job.kind == nil ? 1 : 0.45).disabled(job.kind != nil)
                        TicketNotch()
                    }
                    exitSection
                }
                .overlay(alignment: .topTrailing) { DotStar().frame(width: 18, height: 18).padding(.trailing, 26).padding(.top, 16) }
                .padding(.vertical, 12)
            }
            .background(Theme.sidebarBg)
            .navigationTitle("导出卡")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { job.cancel(); dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 680)
        #endif
        .task { await loadStatus() }
        .fileExporter(isPresented: $exporterPresented, document: document, contentType: document?.type ?? .png,
                      defaultFilename: card.name.isEmpty ? "角色卡" : card.name) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            document = nil
        }
        .alert("导出失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好的") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: 卡面与身份

    private var identity: some View {
        VStack(spacing: 0) {
            cardFace
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text(card.name.isEmpty ? "（没名字）" : card.name).font(.system(size: 22, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    if changed, isLibraryCard {
                        Text("在这里改过").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text(byline).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
            .padding(.top, 12).padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, IOSCal.pad).padding(.top, 18)
    }

    private var byline: String {
        let author = (card.creator ?? "").isEmpty ? "作者未署名" : "作者 \(card.creator ?? "")"
        let version = (card.characterVersion ?? "").isEmpty ? "" : " · 版本 \(card.characterVersion ?? "")"
        return author + version
    }

    private var cardFace: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 164, height: 246)
            .overlay {
                if let data = status?.preview, let image = platformImage(data) {
                    image.resizable().scaledToFill().frame(width: 164, height: 246).clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Text(sourceLabel(status.source)).font(.system(size: 9)).foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.mainBg.opacity(0.85), in: Capsule())
                        .padding(7)
                }
            }
            .shadow(color: Theme.textPrimary.opacity(0.12), radius: 9, y: 6)
            .accessibilityLabel("卡面预览")
    }

    private func sourceLabel(_ source: TavernCardExport.ImageSource) -> String {
        switch source {
        case .original: "原图"
        case .cover: "楼层封面"
        case .generated: "默认卡面"
        }
    }

    // MARK: 带不带改动

    private var editsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasEdits {
                Toggle(isOn: $includeEdits) {
                    Text("带上在这里改过的世界书和正则").font(.system(size: 14)).foregroundColor(Theme.textPrimary)
                }
                .tint(Theme.branchIndicator)
                .frame(minHeight: 52)
                Text("关掉会用卡里原来的世界书和正则。").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    .padding(.bottom, 6)
            }
            ForEach(status?.edits.notes ?? [], id: \.self) { note in
                Text(note).font(.system(size: 11)).foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, IOSCal.pad)
    }

    // MARK: 出口

    @ViewBuilder
    private var exitSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kind = job.kind {
                HStack(alignment: .firstTextBaseline) {
                    Text("正在导出 \(kind)").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text("\(Int(job.progress * 100))%").font(.custom("Georgia", size: 13)).foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button("取消") { job.cancel() }.font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                        .buttonStyle(.plain).frame(minHeight: 44)
                }
                BeadProgress(progress: job.progress).frame(height: 16).padding(.vertical, 6)
                    .accessibilityElement().accessibilityLabel("导出进度").accessibilityValue("\(Int(job.progress * 100))%")
                Text("写好后会读回来核对一遍。").font(.system(size: 11)).foregroundColor(Theme.textMuted).padding(.bottom, 4)
            } else {
                if changed, status?.source == .original {
                    Label("出图工具信息会去掉", systemImage: "circle.slash").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                        .padding(.bottom, 10)
                }
                HStack(spacing: 10) {
                    Button { start(png: true) } label: {
                        Text("导出 PNG").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button { start(png: false) } label: {
                        Text("导出 JSON").font(.system(size: 14)).foregroundColor(Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .buttonStyle(.plain)
                .disabled(status == nil)
            }
        }
        .padding(.horizontal, IOSCal.pad).padding(.top, 8).padding(.bottom, 16)
    }

    // MARK: 动作

    @MainActor
    private func loadStatus() async {
        let floorBooks = isLibraryCard ? fetchFloorBooks() : nil
        let card = card, isLibraryCard = isLibraryCard
        let cover = profile?.coverImageData ?? profile?.assistantAvatarData
        status = await Task.detached(priority: .userInitiated) {
            let edits = isLibraryCard ? CardExportEditsResolver.make(card: card, floorBooks: floorBooks) : CardExportEdits()
            let fieldsChanged = (try? TavernCardExport.envelope(card: card, edits: nil).changed) ?? true
            let original = isLibraryCard ? card.imageData : nil
            if original != nil { return Status(fieldsChanged: fieldsChanged, edits: edits, source: .original, preview: card.coverImageData) }
            if cover != nil { return Status(fieldsChanged: fieldsChanged, edits: edits, source: .cover, preview: cover) }
            return Status(fieldsChanged: fieldsChanged, edits: edits, source: .generated, preview: CardDefaultFace.png(name: card.name))
        }.value
    }

    /// 这张卡绑的楼层里的书（只有卡库卡、绑着楼层的才有「卡带进来的那本」）
    @MainActor
    private func fetchFloorBooks() -> [CardExportEditsResolver.FloorBook]? {
        guard card.bindingState == .active, let pid = card.linkedProfileId else { return nil }
        let descriptor = FetchDescriptor<WorldBook>(predicate: #Predicate<WorldBook> { $0.profileId == pid })
        guard let books = try? modelContext.fetch(descriptor) else { return nil }
        return books.map { .init(name: $0.name, entries: $0.entries, rawJSONData: $0.rawJSONData) }
    }

    private func start(png: Bool) {
        guard job.kind == nil, let status else { return }
        let card = card, isLibraryCard = isLibraryCard
        let edits: CardExportEdits? = includeEdits ? status.edits : nil
        let cover = status.source == .cover ? status.preview : nil
        let job = job
        job.begin(png ? "PNG" : "JSON")
        Task.detached(priority: .userInitiated) {
            let result: Result<CardExportDocument, Error>
            do {
                if png {
                    let out = try TavernCardExport.png(card: card, original: isLibraryCard ? card.imageData : nil, cover: cover, edits: edits,
                                                      progress: { value in Task { @MainActor in job.update(value) } },
                                                      isCancelled: { job.isCancelled })
                    result = .success(CardExportDocument(data: out.data, type: .png))
                } else {
                    let data = try TavernCardExport.json(card: card, edits: edits)
                    if job.isCancelled { throw TavernCardPNGWriter.Failure.cancelled }
                    result = .success(CardExportDocument(data: data, type: .json))
                }
            } catch { result = .failure(error) }
            await MainActor.run { finish(result) }
        }
    }

    @MainActor
    private func finish(_ result: Result<CardExportDocument, Error>) {
        let cancelled = job.isCancelled
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { job.end() }
        switch result {
        case .success(let doc) where !cancelled:
            document = doc
            exporterPresented = true
        case .failure(let error) where (error as? TavernCardPNGWriter.Failure) != .cancelled:
            errorMessage = error.localizedDescription
        default: break
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}

/// 导出进度 + 取消（后台线程读 isCancelled，加锁）
@Observable
final class CardExportJob: @unchecked Sendable {
    private(set) var kind: String?
    private(set) var progress: Double = 0
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    @MainActor func begin(_ kind: String) {
        lock.withLock { cancelled = false }
        self.kind = kind
        progress = 0
    }

    @MainActor func update(_ value: Double) { if kind != nil { progress = max(progress, value) } }

    @MainActor func end() { kind = nil; progress = 0 }

    func cancel() { lock.withLock { cancelled = true } }
}

/// 开屏页的珠串：大小珠交替，走过的染薄荷
private struct BeadProgress: View {
    let progress: Double
    private static let count = 27

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.count, id: \.self) { i in
                Circle()
                    .fill(Double(i) < progress * Double(Self.count) ? Theme.branchIndicator : Theme.textPrimary.opacity(0.14))
                    .frame(width: i % 2 == 0 ? 8 : 4, height: i % 2 == 0 ? 8 : 4)
                if i < Self.count - 1 { Spacer(minLength: 0) }
            }
        }
    }
}

/// 点点金星（小样的四角星：中心 + 四个方向由大到小的点）
private struct DotStar: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 20
            let gold = Color(red: 0xB8 / 255, green: 0x95 / 255, blue: 0x4C / 255)
            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                ctx.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)), with: .color(gold))
            }
            dot(10, 10, 1.6)
            for (d, r) in [(3.4, 1.1), (6.2, 0.8), (8.4, 0.55)] as [(CGFloat, CGFloat)] {
                dot(10, 10 - d, r); dot(10, 10 + d, r); dot(10 - d, 10, r); dot(10 + d, 10, r)
            }
        }
        .accessibilityHidden(true)
    }
}

struct CardExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .json] }
    let data: Data
    let type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw TavernCardError.invalidJSON }
        self.data = data
        self.type = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
