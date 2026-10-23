import Foundation
import SwiftData

/// 卡库 ③-4 / plan §4.2：实发与检查器共用的一次解析——有效身份 + 有效世界书集合（全局 + 楼层 + 对话 + 身份）。
/// 只解析不改存储；PromptAssembler 拿 `profile`（身份套上后的楼层副本）、`worldBooks`、`globalEntries` 照旧组装。
struct SendContext {
    let profile: Profile
    let persona: PersonaResolution
    let worldBooks: [WorldBook]
    let globalEntries: [WorldBookEntry]
    /// 身份绑的书：注入了哪些、哪些找不到（检查器显示）
    let personaBookNotes: [String]

    var inspectorLines: [String] { [persona.summary] + persona.notes + personaBookNotes }
}

enum SendContextResolver {
    static func resolve(profile: Profile, conversation: Conversation?, context: ModelContext, globalEntries: [WorldBookEntry],
                        globalBooks: [GlobalWorldBook]? = nil, personas: [UserPersona]? = nil) -> SendContext {
        let persona = PersonaResolution.resolve(conversationPersonaId: conversation?.personaId, floorPersonaId: profile.personaId,
                                                personas: personas ?? UserPersonaStore.shared.personas)
        let profileId = profile.id
        let floorBooks = (try? context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == profileId }))) ?? []
        let conversationId = conversation?.id ?? ""
        let scoped = floorBooks.filter { $0.scopeConversationId == nil || $0.scopeConversationId == conversationId }
        return combine(profile: profile, persona: persona, floorBooks: scoped, globalEntries: globalEntries,
                       globalBooks: globalBooks ?? GlobalWorldBookManager.live?.books ?? [],
                       bookById: { id in
                           var descriptor = FetchDescriptor<WorldBook>(predicate: #Predicate { $0.id == id })
                           descriptor.fetchLimit = 1
                           return (try? context.fetch(descriptor))?.first
                       },
                       booksNamed: { name in (try? context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.name == name }))) ?? [] })
    }

    /// 纯组合（测试直接调）：floorBooks = 本楼层已按对话范围过滤的书；globalEntries = 开着的全局书条目。
    /// 身份的书引用：`global:<id>` 全局书（关着也按身份注入，开着的已在 globalEntries 里不重复）、
    /// `floor:<uuid>` 楼层书（可以是别的楼层 / 对话的那份）、`name:<源书名>` 导入时包里没有的书——
    /// 只认已导入（带原文）的同名书，唯一才用，没有 / 同名不同内容都报告不注入。同内容的副本只进一份。
    static func combine(profile: Profile, persona: PersonaResolution, floorBooks: [WorldBook], globalEntries: [WorldBookEntry],
                        globalBooks: [GlobalWorldBook], bookById: (UUID) -> WorldBook?, booksNamed: (String) -> [WorldBook]) -> SendContext {
        var books = floorBooks
        var entries = globalEntries
        var notes: [String] = []
        if let refs = persona.persona?.worldSourceRefs, !refs.isEmpty {
            var seenRaw = Set(floorBooks.compactMap(\.rawJSONData) + globalBooks.filter(\.isEnabled).compactMap(\.rawJSONData))
            var bookIds = Set(floorBooks.map(\.id))
            var globalIds = Set(globalBooks.filter(\.isEnabled).map(\.id))

            func addGlobal(_ book: GlobalWorldBook) {
                guard !globalIds.contains(book.id) else { notes.append("身份的书「\(book.name)」：已是开着的全局书"); return }
                if let raw = book.rawJSONData, !seenRaw.insert(raw).inserted { return }
                globalIds.insert(book.id)
                entries += book.entries
                notes.append("身份的书「\(book.name)」：按身份注入（全局书库里关着）")
            }
            func addFloor(_ book: WorldBook) {
                guard !bookIds.contains(book.id) else { notes.append("身份的书「\(book.name)」：这个楼层已有"); return }
                if let raw = book.rawJSONData, !seenRaw.insert(raw).inserted { return }
                bookIds.insert(book.id)
                books.append(book)
                notes.append("身份的书「\(book.name)」：按身份注入" + (book.isEnabled ? "" : "（整本关着，不注入）"))
            }

            for ref in refs {
                if ref.hasPrefix("global:") {
                    let id = String(ref.dropFirst("global:".count))
                    if let book = globalBooks.first(where: { $0.id == id }) { addGlobal(book) }
                    else { notes.append("身份的书找不到了（全局 \(id.prefix(8))），不注入") }
                } else if ref.hasPrefix("floor:") {
                    let raw = String(ref.dropFirst("floor:".count))
                    if let id = UUID(uuidString: raw), let book = bookById(id) { addFloor(book) }
                    else { notes.append("身份的书找不到了（楼层 \(raw.prefix(8))），不注入") }
                } else if ref.hasPrefix("name:") {
                    let name = String(ref.dropFirst("name:".count))
                    let globals = globalBooks.filter { $0.name == name && $0.rawJSONData != nil }
                    let floors = booksNamed(name).filter { $0.rawJSONData != nil }
                    let contents = Set(globals.compactMap(\.rawJSONData) + floors.compactMap(\.rawJSONData))
                    if contents.isEmpty {
                        notes.append("身份的书「\(name)」还没导入，不注入")
                    } else if contents.count > 1 {
                        notes.append("身份的书「\(name)」有 \(contents.count) 本同名内容不同，不猜，不注入")
                    } else if let book = globals.first {
                        addGlobal(book)
                    } else if let book = floors.first(where: { $0.profileId == profile.id }) ?? floors.first {
                        addFloor(book)
                    }
                } else {
                    notes.append("身份的书引用认不出（\(ref.prefix(16))），不注入")
                }
            }
        }
        return SendContext(profile: persona.applied(to: profile), persona: persona, worldBooks: books,
                           globalEntries: entries, personaBookNotes: notes)
    }
}
