import XCTest
@testable import 记忆花园

/// A1 工具调用预检（《minis对比》洞 1）：缺参/坏 JSON 一律不执行，回灌让模型自愈。
final class ToolCallPreflightTests: XCTestCase {

    // MARK: 真实事故场景

    func testFsWriteMissingContentIsRejected() {
        // 病根原样：模型发合法 JSON 但缺 content → 原实现把已有文件写成空
        let f = ToolCallPreflight.check(name: "fs_write",
                                        argumentsJSON: #"{"path":"日记.md"}"#,
                                        required: ["path", "content"])
        XCTAssertNotNil(f, "缺 content 必须拒绝——放行会清空已有文件")
        XCTAssertEqual(f?.code, "missing_param")
        XCTAssertTrue(f?.message.contains("content") == true)
    }

    func testFsWriteCompleteIsAllowed() {
        XCTAssertNil(ToolCallPreflight.check(name: "fs_write",
                                             argumentsJSON: #"{"path":"日记.md","content":"今天"}"#,
                                             required: ["path", "content"]))
    }

    // MARK: 坏 JSON（另一半病根：原来降成空字典继续走）

    func testMalformedJSONIsRejected() {
        for bad in [#"{"path":"a.md","content":"#, "not json at all", "[1,2,3]"] {
            let f = ToolCallPreflight.check(name: "fs_write", argumentsJSON: bad, required: ["path", "content"])
            XCTAssertNotNil(f, "坏 JSON 必须拒绝：\(bad)")
            XCTAssertEqual(f?.code, "invalid_json")
        }
    }

    func testEmptyArgumentsStringMeansNoParams() {
        // 空串 = 无参数：无 required 的工具通过，有 required 的按缺参拒
        XCTAssertNil(ToolCallPreflight.check(name: "fs_list", argumentsJSON: "", required: []))
        XCTAssertEqual(ToolCallPreflight.check(name: "fs_read", argumentsJSON: "", required: ["path"])?.code, "missing_param")
        XCTAssertNil(ToolCallPreflight.check(name: "fs_list", argumentsJSON: "{}", required: []))
    }

    // MARK: null / 空串 / 空白

    func testNullAndBlankTreatedAsMissing() {
        XCTAssertNotNil(ToolCallPreflight.check(name: "fs_read", argumentsJSON: #"{"path":null}"#, required: ["path"]))
        XCTAssertNotNil(ToolCallPreflight.check(name: "fs_read", argumentsJSON: #"{"path":""}"#, required: ["path"]))
        XCTAssertNotNil(ToolCallPreflight.check(name: "fs_read", argumentsJSON: #"{"path":"   "}"#, required: ["path"]))
    }

    func testEmptyStringWhitelistForEditDeletion() {
        // fs_edit 用空 new_string 表示「删掉命中内容」——这是合法语义，不能被预检拦
        XCTAssertNil(ToolCallPreflight.check(
            name: "fs_edit",
            argumentsJSON: #"{"path":"a.md","old_string":"要删的","new_string":""}"#,
            required: ["path", "old_string", "new_string"]))
        // 但 old_string 空仍然是缺参（不在白名单）
        XCTAssertNotNil(ToolCallPreflight.check(
            name: "fs_edit",
            argumentsJSON: #"{"path":"a.md","old_string":"","new_string":"x"}"#,
            required: ["path", "old_string", "new_string"]))
    }

    // MARK: 非字符串类型不误判

    func testNonStringRequiredValuesPass() {
        XCTAssertNil(ToolCallPreflight.check(name: "notify_schedule",
                                             argumentsJSON: #"{"title":"喝水","after_seconds":10}"#,
                                             required: ["title"]))
        XCTAssertNil(ToolCallPreflight.check(name: "x", argumentsJSON: #"{"flag":false,"n":0}"#, required: ["flag", "n"]),
                     "false/0 是合法值，不是缺失")
    }

    // MARK: 无约束时只校 JSON

    func testUnknownToolOnlyValidatesJSON() {
        XCTAssertNil(ToolCallPreflight.check(name: "some_mcp_tool", argumentsJSON: #"{"anything":1}"#, required: nil))
        XCTAssertEqual(ToolCallPreflight.check(name: "some_mcp_tool", argumentsJSON: "{broken", required: nil)?.code, "invalid_json")
    }

    // MARK: 约束来源接线（内建工具能查到 required）

    @MainActor
    func testRequiredFieldsFromRegistry() {
        XCTAssertEqual(ToolCallPreflight.requiredFields(for: "fs_write", mcpServerIds: []).map(Set.init), Set(["path", "content"]))
        XCTAssertEqual(ToolCallPreflight.requiredFields(for: "fs_list", mcpServerIds: []), [])
        XCTAssertNil(ToolCallPreflight.requiredFields(for: "definitely_not_a_tool", mcpServerIds: []), "查不到 = nil（只校 JSON）")
    }
}
