import XCTest
@testable import MemoryCore

final class CatalogRecordLineTests: XCTestCase {
    /// Reader 造出处只带 layer / filePath / name（不带 day）；期望串取自 HEAD `CatalogSources.label(cite)` 的三种输出。
    ///
    /// 其余断言按 HEAD `CatalogWriter.swift:72-83`、`CatalogSurvey.swift:101-104` 的公式手算：
    /// - 页面 `memory/wiki/人/阿青.md`：去 `memory/wiki/` 前缀与 `.md` 得 `人/阿青`（首段「人」在 `WikiStore.branches`）→ `wiki 人/阿青`
    /// - 分组索引 `memory/wiki/人/INDEX.md`：去前缀与 `/INDEX.md` 得 `人` → `wiki 人 索引`
    /// - 根索引 `memory/wiki/INDEX.md`：命中 `wikiIndexPath` → 空分组 → `wiki 根索引`
    /// - 问卷 `.survey/ABC12345.json`：末段前 8 位 `ABC12345`，日期原样 → `问卷「在做什么」2026-10-22#ABC12345`
    func testCiteLabelMatchesHeadForReaderLayers() {
        XCTAssertEqual(CatalogRecordLine.citeLabel(layer: "CC", filePath: "memory/cc/星砚.md", name: "星砚", day: nil),
                       "CC memory/cc/星砚.md")
        XCTAssertEqual(CatalogRecordLine.citeLabel(layer: "Prompt", filePath: "memory/prompt/星砚#01", name: "星砚", day: nil),
                       "Prompt 星砚")
        XCTAssertEqual(CatalogRecordLine.citeLabel(layer: "问卷", filePath: ".survey/ABC12345.json", name: "在做什么", day: nil),
                       "问卷「在做什么」#ABC12345")
        XCTAssertEqual(CatalogRecordLine.citeLabel(layer: "wiki", filePath: "memory/wiki/人/阿青.md", name: "阿青", day: nil),
                       "wiki 人/阿青")
        XCTAssertEqual(CatalogRecordLine.citeLabel(layer: "wiki", filePath: "memory/wiki/人/INDEX.md", name: "人", day: nil),
                       "wiki 人 索引")
        XCTAssertEqual(CatalogRecordLine.citeLabel(layer: "wiki", filePath: "memory/wiki/INDEX.md", name: "wiki 根索引", day: nil),
                       "wiki 根索引")
        XCTAssertEqual(CatalogRecordLine.citeLabel(layer: "问卷", filePath: ".survey/ABC12345.json", name: "在做什么", day: "2026-10-22"),
                       "问卷「在做什么」2026-10-22#ABC12345")
    }
}
