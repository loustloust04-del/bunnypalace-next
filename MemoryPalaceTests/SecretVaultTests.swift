import XCTest
@testable import 记忆花园

/// 加密值占位扫描 / 替换 / 范围 / 擦除（docs/plan-secure-ask.md）。纯函数，不碰钥匙串
final class SecretVaultTests: XCTestCase {

    private func lookup(_ table: [String: SecretVault.Lookup]) -> (String) -> SecretVault.Lookup {
        { table[$0] ?? .missing }
    }

    func testIdsInText() {
        let text = #"{"command":"echo {{secret:s-1a2b3c4d}} && echo {{secret:s-ffff0000}} {{secret:s-1a2b3c4d}}"}"#
        XCTAssertEqual(SecretVault.ids(in: text), ["s-1a2b3c4d", "s-ffff0000"])
        XCTAssertEqual(SecretVault.ids(in: "{{secret:}} {secret:s-1} {{secret:S-ABC}}"), [])
        XCTAssertTrue(SecretVault.isPlaceholder("{{secret:s-1a2b}}"))
        XCTAssertFalse(SecretVault.isPlaceholder("x {{secret:s-1a2b}}"))
    }

    func testSubstituteEscapesIntoValidJSON() throws {
        let json = #"{"command":"sshpass -p {{secret:s-aaaa}} ssh root@h"}"#
        let value = #"pa"ss\wo/rd"#
        let r = SecretVault.substitute(json, lookup: lookup(["s-aaaa": .found(label: "服务器密码", value: value)]))
        XCTAssertTrue(r.problems.isEmpty)
        XCTAssertEqual(r.used.map(\.id), ["s-aaaa"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["command"] as? String, "sshpass -p \(value) ssh root@h")
    }

    func testSubstituteScopeAndMissingLeavePlaceholder() {
        let json = #"{"a":"{{secret:s-0001}}","b":"{{secret:s-0002}}","c":"{{secret:s-0003}}"}"#
        let r = SecretVault.substitute(json, lookup: lookup([
            "s-0001": .found(label: "x", value: "real-1"),
            "s-0002": .wrongScope(label: "别处的"),
        ]))
        XCTAssertEqual(r.used.map(\.id), ["s-0001"])
        XCTAssertEqual(r.problems.count, 2)
        XCTAssertTrue(r.problems[0].contains("别处的"))
        XCTAssertTrue(r.problems[1].contains("{{secret:s-0003}}"))
        XCTAssertTrue(r.json.contains("{{secret:s-0002}}"))
        XCTAssertTrue(r.json.contains("{{secret:s-0003}}"))
        XCTAssertFalse(r.json.contains("{{secret:s-0001}}"))
    }

    func testNoPlaceholderIsUntouched() {
        let json = #"{"command":"ls"}"#
        let r = SecretVault.substitute(json, lookup: lookup([:]))
        XCTAssertEqual(r.json, json)
        XCTAssertTrue(r.used.isEmpty)
        XCTAssertTrue(r.problems.isEmpty)
    }

    func testScrubRawAndJSONEscaped() {
        let value = #"hun/ter"2"#
        let used = [SecretVault.Use(id: "s-aaaa", label: "pw", value: value)]
        // MCP 报错回显参数用的是 JSONSerialization，跟 jsonEscaped 同一套转义
        let echoed = String(data: try! JSONSerialization.data(withJSONObject: ["args": value]), encoding: .utf8)!
        let out = SecretVault.scrub("stdout: \(value) | echo: \(echoed)", used: used)
        XCTAssertFalse(out.contains("hun/ter"))
        XCTAssertFalse(out.contains(#"hun\/ter"#))
        XCTAssertFalse(out.contains(SecretVault.jsonEscaped(value)))
        XCTAssertEqual(out.components(separatedBy: "{{secret:s-aaaa}}").count - 1, 2)
    }

    func testScrubSkipsShortValues() {
        let used = [SecretVault.Use(id: "s-bbbb", label: "pin", value: "123")]
        XCTAssertEqual(SecretVault.scrub("code 123", used: used), "code 123")
    }

    func testScrubLongerValueFirst() {
        let used = [SecretVault.Use(id: "s-short", label: "a", value: "abcd"),
                    SecretVault.Use(id: "s-long", label: "b", value: "abcdefgh")]
        XCTAssertEqual(SecretVault.scrub("abcdefgh", used: used), "{{secret:s-long}}")
    }
}
