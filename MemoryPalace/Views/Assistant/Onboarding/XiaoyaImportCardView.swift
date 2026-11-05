import SwiftUI
import UniformTypeIdentifiers

// MARK: - 导卡卡（小样 importCard：⑨ 酒馆线）
// 选文件 → 读卡中 → 摘要 +「卡里的 {{user}} 会叫你「X」」→「好，就是 Ta」；坏文件给原因，可以重选。
// 只读不写：选中的文件拷一份进临时目录（之后不用再开安全作用域）再解析，答案里带这份拷贝的地址，
// 真正进卡库 / 建楼层是 P4（cardManager.importFromFile → floors.enter(card:activate:false)）。

enum XiaoyaImportPhase: Equatable {
    case idle
    case reading
    case bad(String)
    case ready(XiaoyaImportedCard)
}

struct XiaoyaImportCardView: View {
    let answer: XiaoyaCardAnswer?
    /// 卡里 {{user}} 会被叫成什么（默认称呼；空 → 「你」）
    let userName: String
    let onAnswer: (XiaoyaCardAnswer) -> Void

    @State private var phase: XiaoyaImportPhase
    @State private var picking = false

    init(answer: XiaoyaCardAnswer?, userName: String, initialPhase: XiaoyaImportPhase = .idle,
         onAnswer: @escaping (XiaoyaCardAnswer) -> Void) {
        self.answer = answer
        self.userName = userName
        self.onAnswer = onAnswer
        _phase = State(initialValue: initialPhase)
    }

    var body: some View {
        if case .imported(let card) = answer {
            XiaoyaCardFrame(kicker: "导入 · 角色卡") {
                XiaoyaCardSummary(text: "已导入「\(card.name)」") {
                    XiaoyaInitialAvatar(name: card.name, size: 30)
                }
                .padding(.top, 6)
            }
        } else {
            XiaoyaCardFrame(kicker: "导入 · 角色卡", question: "把你的角色卡给我") {
                content
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.png, .json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { read(url) }
                case .failure(let error):
                    phase = .bad("文件打不开：\(error.localizedDescription)")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .bad:
            XiaoyaHint(".png（带角色数据的卡图）或 .json 都认；酒馆 V2 / V3 格式。")
                .padding(.top, -9)
            if case .bad(let why) = phase {
                XiaoyaResultBar(tone: .bad, badge: "!", title: "这张读不出来") {
                    Text(why).fixedSize(horizontal: false, vertical: true)
                }
            }
            XiaoyaCardActions {
                Button(phase == .idle ? "选择角色卡" : "换一张") { picking = true }
                    .buttonStyle(.xiaoya(.primary))
            }
        case .reading:
            XiaoyaResultBar(tone: .wait, title: "在读卡…")
                .padding(.top, -12)
        case .ready(let card):
            XiaoyaTaHeader(name: card.name, meta: card.meta)
                .padding(.top, -6)
            XiaoyaHint(text: Text("卡里的 ") + Text(verbatim: "{{user}}").font(.system(size: XiaoyaCardFont.mono, design: .monospaced))
                + Text(" 会叫你「\(userName.isEmpty ? "你" : userName)」——以后在 Ta 楼层的 Prompt 页能改。"))
            XiaoyaCardActions {
                Button("好，就是 Ta") { onAnswer(.imported(card)) }
                    .buttonStyle(.xiaoya(.primary))
                Button("换一张") { picking = true }
                    .buttonStyle(.xiaoya(.text))
            }
        }
    }

    private func read(_ url: URL) {
        phase = .reading
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.load(url) }.value
            switch result {
            case .success(let card): phase = .ready(card)
            case .failure(let why): phase = .bad(why.message)
            }
        }
    }

    struct ReadFailure: Error, Sendable {
        let message: String
    }

    /// 拷进临时目录 + 解析；失败给一句人话（小样 FAILS 口径）
    nonisolated static func load(_ url: URL) -> Result<XiaoyaImportedCard, ReadFailure> {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let dir = AppPaths.temporaryDirectory
            .appendingPathComponent("xiaoya-import", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            return .failure(ReadFailure(message: "文件打不开：\(error.localizedDescription)"))
        }
        let tavern: TavernCard
        do {
            tavern = try TavernCard.parseFile(url: copy)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return .failure(ReadFailure(message: reason(error)))
        }
        let name = tavern.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            return .failure(ReadFailure(message: "卡里没有名字——可能不是角色卡，或者只导出了一半。"))
        }
        let greetings = (tavern.firstMes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
            + tavern.alternateGreetings.count
        return .success(XiaoyaImportedCard(
            name: name,
            greetingCount: greetings,
            worldBookEntries: tavern.characterBookEntries.count,
            hasSystemPrompt: !tavern.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            fileURL: copy))
    }

    nonisolated static func reason(_ error: Error) -> String {
        switch error as? TavernCardError {
        case .noCharaChunk?: return "图里没有角色数据（缺 chara 字段）——可能是被压缩过的图，换原始卡图试试。"
        case .invalidPNG?: return "这不是一张完整的 PNG 图——可能下载到一半，或者被转过格式。"
        case .invalidBase64?: return "卡图里的角色数据坏了（编码不对）——换原始卡图试试。"
        case .invalidJSON?: return "这个 JSON 读不出来——可能不是角色卡，或者文件不完整。"
        case .unsupportedFormat(let ext)?: return "只认 .png 和 .json，这个是 .\(ext)。"
        case nil: return "读不出来：\(error.localizedDescription)"
        }
    }
}
