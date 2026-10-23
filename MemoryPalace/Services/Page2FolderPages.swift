import Foundation

enum Page2FolderPages {
    static func appendPosition(in pages: [[UUID]]) -> (page: Int, slot: Int) {
        if pages.last?.count == 9 { return (pages.count, 0) }
        return (max(0, pages.count - 1), pages.last?.count ?? 0)
    }

    static func inserting(_ id: UUID, page requestedPage: Int, slot requestedSlot: Int, into original: [[UUID]]) -> [[UUID]] {
        var pages = original.map { $0.filter { $0 != id } }
        let page = max(0, min(requestedPage, pages.count))
        if page == pages.count { pages.append([]) }
        pages[page].insert(id, at: max(0, min(requestedSlot, pages[page].count)))
        var index = page
        while index < pages.count {
            if pages[index].count > 9 {
                let overflow = Array(pages[index].dropFirst(9))
                pages[index] = Array(pages[index].prefix(9))
                if index + 1 == pages.count { pages.append([]) }
                pages[index + 1].insert(contentsOf: overflow, at: 0)
            }
            index += 1
        }
        return pages
    }
}
