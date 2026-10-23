import XCTest
@testable import 记忆花园

/// AgentConfigEditor：文本层改 agent 配置（研究报告 2.3）——保 key 顺序/缩进/注释、原子写、没变化不写、坏 JSON 不动。
final class AgentConfigEditorTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConfigEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 文本层

    func testReplaceTopLevelKeepsKeyOrderAndIndent() throws {
        let src = """
        {
            "zeta": 1,
            "alpha": false,
            "mid": "x"
        }

        """
        let out = try AgentConfigEditor.setting(true, at: ["alpha"], in: src)
        XCTAssertEqual(out, """
        {
            "zeta": 1,
            "alpha": true,
            "mid": "x"
        }

        """)
    }

    func testInsertTopLevelAppendsAtEndWithFileIndent() throws {
        let src = "{\n    \"zeta\": 1,\n    \"alpha\": 2\n}\n"
        let out = try AgentConfigEditor.setting(30, at: ["cleanupPeriodDays"], in: src)
        XCTAssertEqual(out, "{\n    \"zeta\": 1,\n    \"alpha\": 2,\n    \"cleanupPeriodDays\": 30\n}\n")
    }

    func testInsertIntoEmptyObject() throws {
        XCTAssertEqual(try AgentConfigEditor.setting(true, at: ["a"], in: "{}\n"), "{\n  \"a\": true\n}\n")
        XCTAssertEqual(try AgentConfigEditor.setting(true, at: ["a"], in: "{}"), "{\"a\":true}")
    }

    func testSetNestedCreatesMissingParents() throws {
        let src = "{\n  \"model\": \"opus\"\n}\n"
        let out = try AgentConfigEditor.setting("x", at: ["env", "FOO"], in: src)
        XCTAssertEqual(out, "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"FOO\": \"x\"\n  }\n}\n")
    }

    func testAppendToNestedArrayKeepsEverythingElse() throws {
        let src = """
        {
          // 用户的注释
          "permissions": {"allow": ["Bash(ls)"]},
          "hooks": {
            "Stop": [
              {"hooks": [{"type": "command", "command": "echo hi"}]}
            ],
            "PreToolUse": []
          },
          "theme": "dark"
        }

        """
        let entry = AgentConfigEditor.OrderedObject([
            ("matcher", "AskUserQuestion"),
            ("hooks", [AgentConfigEditor.OrderedObject([("type", "command"), ("command", "python3 x.py")])]),
        ])
        var out = try AgentConfigEditor.appending(entry, toArrayAt: ["hooks", "Stop"], in: src)
        out = try AgentConfigEditor.appending(entry, toArrayAt: ["hooks", "PreToolUse"], in: out)
        XCTAssertEqual(out, """
        {
          // 用户的注释
          "permissions": {"allow": ["Bash(ls)"]},
          "hooks": {
            "Stop": [
              {"hooks": [{"type": "command", "command": "echo hi"}]},
              {
                "matcher": "AskUserQuestion",
                "hooks": [
                  {
                    "type": "command",
                    "command": "python3 x.py"
                  }
                ]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "AskUserQuestion",
                "hooks": [
                  {
                    "type": "command",
                    "command": "python3 x.py"
                  }
                ]
              }
            ]
          },
          "theme": "dark"
        }

        """)
    }

    func testAppendCreatesMissingArray() throws {
        let out = try AgentConfigEditor.appending(1, toArrayAt: ["hooks", "Stop"], in: "{\n  \"a\": 1\n}")
        XCTAssertEqual(out, "{\n  \"a\": 1,\n  \"hooks\": {\n    \"Stop\": [\n      1\n    ]\n  }\n}")
    }

    func testRemoveMemberAndArrayItems() throws {
        let src = "{\n  \"a\": 1,\n  \"b\": [1, 2, 3],\n  \"c\": 3\n}\n"
        XCTAssertEqual(try AgentConfigEditor.removing(at: ["a"], in: src), "{\n  \"b\": [1, 2, 3],\n  \"c\": 3\n}\n")
        XCTAssertEqual(try AgentConfigEditor.removing(at: ["c"], in: src), "{\n  \"a\": 1,\n  \"b\": [1, 2, 3]\n}\n")
        XCTAssertEqual(try AgentConfigEditor.removing(at: ["nope"], in: src), src)
        let out = try AgentConfigEditor.removingItems(inArrayAt: ["b"], in: src) { ($0 as? Int) == 2 }
        XCTAssertEqual(out, "{\n  \"a\": 1,\n  \"b\": [1, 3],\n  \"c\": 3\n}\n")
        let all = try AgentConfigEditor.removingItems(inArrayAt: ["b"], in: src) { _ in true }
        XCTAssertEqual(all, "{\n  \"a\": 1,\n  \"b\": [],\n  \"c\": 3\n}\n")
    }

    func testJSONCTrailingCommaAndCommentsTolerated() throws {
        let src = "{\n  /* block */ \"a\": 1, // tail\n  \"b\": 2,\n}\n"
        XCTAssertEqual(try AgentConfigEditor.value(at: ["b"], in: src) as? Int, 2)
        let out = try AgentConfigEditor.setting(5, at: ["a"], in: src)
        XCTAssertEqual(out, "{\n  /* block */ \"a\": 5, // tail\n  \"b\": 2,\n}\n")
    }

    func testValueOfStringContainingBracesAndSlashes() throws {
        let src = #"{"cmd": "echo '{ // not a comment }'", "n": null}"#
        XCTAssertEqual(try AgentConfigEditor.value(at: ["cmd"], in: src) as? String, "echo '{ // not a comment }'")
        XCTAssertTrue(try AgentConfigEditor.value(at: ["n"], in: src) is NSNull)
        XCTAssertNil(try AgentConfigEditor.value(at: ["missing"], in: src))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try AgentConfigEditor.setting(1, at: ["a"], in: "{ \"a\": "))
        XCTAssertThrowsError(try AgentConfigEditor.setting(1, at: ["a"], in: "[1, 2]"))
        // 中间节点不是 object → 不硬改
        XCTAssertThrowsError(try AgentConfigEditor.appending(1, toArrayAt: ["hooks", "Stop"], in: "{\"hooks\": 3}"))
        XCTAssertThrowsError(try AgentConfigEditor.appending(1, toArrayAt: ["hooks"], in: "{\"hooks\": {}}"))
    }

    // MARK: - 文件层

    func testUpdateFileNoChangeDoesNotWrite() throws {
        let url = tmp.appendingPathComponent("settings.json")
        try Data("{\n  \"a\": true\n}\n".utf8).write(to: url)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        let wrote = try AgentConfigEditor.update(fileAt: url) { try AgentConfigEditor.setting(true, at: ["a"], in: $0) }
        XCTAssertFalse(wrote)
        let inode2 = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertEqual(inode, inode2, "内容没变却重写了文件")
    }

    func testUpdateFileBadJSONLeavesFileUntouched() throws {
        let url = tmp.appendingPathComponent("settings.json")
        let bad = "{ \"a\": tru"
        try Data(bad.utf8).write(to: url)
        XCTAssertThrowsError(try AgentConfigEditor.update(fileAt: url) { try AgentConfigEditor.setting(true, at: ["a"], in: $0) })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), bad)
    }

    func testUpdateFilePreservesPermissionsAndCreatesMissing() throws {
        let url = tmp.appendingPathComponent("settings.json")
        try Data("{\"a\": 1}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertTrue(try AgentConfigEditor.update(fileAt: url) { try AgentConfigEditor.setting(2, at: ["a"], in: $0) })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"a\": 2}")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let fresh = tmp.appendingPathComponent("sub/dir/new.json")
        XCTAssertTrue(try AgentConfigEditor.update(fileAt: fresh) { try AgentConfigEditor.setting(1, at: ["x"], in: $0) })
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), "{\n  \"x\": 1\n}\n")
    }

    func testUpdateFileWritesThroughSymlink() throws {
        let real = tmp.appendingPathComponent("real.json")
        let link = tmp.appendingPathComponent("link.json")
        try Data("{\"a\": 1}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(try AgentConfigEditor.update(fileAt: link) { try AgentConfigEditor.setting(2, at: ["a"], in: $0) })
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{\"a\": 2}")
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "原子写把软链替换成了普通文件")
    }
}
