import XCTest
import SwiftUI
@testable import 记忆花园

/// 卡库长字段：全屏编辑器点保存 = 先写回表单、再落盘一次（粟粟 10-15「每次都要保存好几遍」）
@MainActor
final class CardLibrarySaveTests: XCTestCase {
    func testFullScreenSaveWritesFormThenCommitsOnce() throws {
        var form = "旧描述"
        var commits: [String] = []
        let binding = Binding(get: { form }, set: { form = $0 })
        let save = LongTextField.saveHandler(text: binding) { value in
            XCTAssertEqual(form, value, "落盘时表单已经是新值")
            commits.append(value)
        }
        let sheet = FileEditorSheet.text(title: "描述", text: form, format: .markdown,
                                         onSave: save, onCancel: {}, versionKey: .cardField(cardId: "c1", field: "description"))
        try sheet.onSave("新描述", "旧描述")
        XCTAssertEqual(form, "新描述")
        XCTAssertEqual(commits, ["新描述"], "点一次保存只落一次盘")
    }

    func testCommitFailureStillWritesFormAndThrows() {
        struct Boom: Error {}
        var form = ""
        let save = LongTextField.saveHandler(text: Binding(get: { form }, set: { form = $0 })) { _ in throw Boom() }
        XCTAssertThrowsError(try save("x"), "落盘失败往上抛，编辑器弹保存失败")
        XCTAssertEqual(form, "x", "正文留在表单里，改好别的字段再存")
    }

    func testWithoutCommitOnlyWritesForm() throws {
        var form = ""
        let save = LongTextField.saveHandler(text: Binding(get: { form }, set: { form = $0 }), onCommit: nil)
        try save("只写回")
        XCTAssertEqual(form, "只写回")
    }
}
