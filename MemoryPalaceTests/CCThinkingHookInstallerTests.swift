#if os(macOS)
import XCTest
@testable import 记忆花园

/// CCThinkingHookInstaller 走 AgentConfigEditor：保格式、没变化不写、坏 JSON 不动、stash + 卸载还原。
final class CCThinkingHookInstallerTests: XCTestCase {

    private var root: URL!
    private let thinking = "/support/cc/thinking-hook.py"
    private let ask = "/support/cc/askuser-hook.py"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCThinkingHookInstallerTests-\(UUID().uuidString)", isDirectory: true)
        CCThinkingHookInstaller.overrideRoot = root
        try FileManager.default.createDirectory(at: CCThinkingHookInstaller.workdir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CCThinkingHookInstaller.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    private var settingsURL: URL { CCThinkingHookInstaller.settingsURL }

    private func writeSettings(_ s: String) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: settingsURL)
    }

    private func readSettings() throws -> String { try String(contentsOf: settingsURL, encoding: .utf8) }

    private func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func testPathsFollowOverrideRoot() {
        XCTAssertTrue(CCThinkingHookInstaller.settingsURL.path.hasPrefix(root.path))
        XCTAssertTrue(CCThinkingHookInstaller.stashURL.path.hasPrefix(root.path))
    }

    func testInstallKeepsUserKeyOrderAndAddsHooks() throws {
        let original = """
        {
          "zeta": 1,
          "model": "opus",
          "alpha": {"b": 2, "a": 1}
        }

        """
        try writeSettings(original)
        XCTAssertTrue(try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: ask))
        let out = try readSettings()
        XCTAssertTrue(out.hasPrefix("{\n  \"zeta\": 1,\n  \"model\": \"opus\",\n  \"alpha\": {\"b\": 2, \"a\": 1},\n"), out)
        let obj = try json(out)
        XCTAssertEqual(obj["showThinkingSummaries"] as? Bool, true)
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 1)
        XCTAssertEqual((hooks["PreToolUse"] as? [Any])?.count, 1)
        XCTAssertEqual((hooks["PostToolUse"] as? [Any])?.count, 1)
        XCTAssertTrue(out.contains("thinking-hook.py"))
    }

    func testSecondInstallIsNoOpAndDoesNotRewrite() throws {
        try writeSettings("{\n  \"a\": 1\n}\n")
        XCTAssertTrue(try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: ask))
        let first = try readSettings()
        let inode = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.systemFileNumber] as? Int
        XCTAssertFalse(try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: ask))
        XCTAssertEqual(try readSettings(), first)
        let inode2 = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.systemFileNumber] as? Int
        XCTAssertEqual(inode, inode2)
    }

    func testBadJSONIsNotTouched() throws {
        let bad = "{ \"hooks\": { oops"
        try writeSettings(bad)
        XCTAssertThrowsError(try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: ask))
        XCTAssertEqual(try readSettings(), bad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CCThinkingHookInstaller.stashURL.path))
    }

    func testStashRecordsOriginalAndUninstallRestoresExactly() throws {
        let original = """
        {
          "showThinkingSummaries": false,
          "hooks": {
            "Stop": [
              {"hooks": [{"type": "command", "command": "echo mine"}]}
            ]
          }
        }

        """
        try writeSettings(original)
        XCTAssertTrue(try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: ask))
        XCTAssertNotEqual(try readSettings(), original)

        let stash = try json(String(contentsOf: CCThinkingHookInstaller.stashURL, encoding: .utf8))
        let entry = try XCTUnwrap(stash[settingsURL.resolvingSymlinksInPath().path] as? [String: Any])
        XCTAssertEqual((entry["showThinkingSummaries"] as? [String: Any])?["value"] as? Bool, false)
        XCTAssertEqual((entry["hooks.PreToolUse"] as? [String: Any])?["absent"] as? Bool, true)

        XCTAssertTrue(try CCThinkingHookInstaller.uninstall())
        XCTAssertEqual(try readSettings(), original)
        // stash 用完即清
        let after = try json(String(contentsOf: CCThinkingHookInstaller.stashURL, encoding: .utf8))
        XCTAssertNil(after[settingsURL.resolvingSymlinksInPath().path])
    }

    func testUninstallFromMissingFileRestoresToEmptyObject() throws {
        XCTAssertTrue(try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: nil))
        XCTAssertTrue(try readSettings().contains("thinking-hook.py"))
        XCTAssertTrue(try CCThinkingHookInstaller.uninstall())
        XCTAssertEqual(try json(readSettings()).count, 0)
    }

    func testReinstallDoesNotOverwriteStashedOriginal() throws {
        try writeSettings("{\"showThinkingSummaries\": false}")
        XCTAssertTrue(try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: nil))
        // 装完再装一次（值已是 true），stash 仍记着最初的 false
        _ = try CCThinkingHookInstaller.applySettings(thinkingHookPath: thinking, askHookPath: nil)
        XCTAssertTrue(try CCThinkingHookInstaller.uninstall())
        XCTAssertEqual(try readSettings(), "{\"showThinkingSummaries\": false}")
    }
}
#endif
