#if PERSONAL_APPS
import XCTest
@testable import 记忆花园

/// 门控：别的楼层拿不到工具、未启用拿不到工具；执行时再判一次。只读她的 UserDefaults，不写
@MainActor
final class DeathScaleAIToolTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DeathScaleAITool-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testGatePureFunction() {
        XCTAssertTrue(DeathScaleAITool.isAvailable(profileId: "p1", toolEnabled: true, readableProfileIds: ["p1"]))
        XCTAssertFalse(DeathScaleAITool.isAvailable(profileId: "p2", toolEnabled: true, readableProfileIds: ["p1"]), "别的楼层拿不到")
        XCTAssertFalse(DeathScaleAITool.isAvailable(profileId: "p1", toolEnabled: false, readableProfileIds: ["p1"]), "未启用拿不到")
        XCTAssertFalse(DeathScaleAITool.isAvailable(profileId: nil, toolEnabled: true, readableProfileIds: ["p1"]))
        XCTAssertFalse(DeathScaleAITool.isAvailable(profileId: "", toolEnabled: true, readableProfileIds: [""]))
    }

    func testRegistryHidesToolFromUnauthorizedFloor() {
        XCTAssertTrue(ToolRegistry.all.contains { $0.definition.name == DeathScaleAITool.toolName })
        for pid in [nil, "", "death-scale-test-\(UUID().uuidString)"] as [String?] {
            let names = ToolRegistry.enabledDefinitions(ToolGateContext(family: .anthropic, deferMCP: false, profileId: pid)).map(\.name)
            XCTAssertFalse(names.contains(DeathScaleAITool.toolName), "profileId=\(pid ?? "nil")")
        }
    }

    func testExecuteRechecksGate() {
        let store = DeathScaleStore(root: root)
        store.grantRead("p1")
        let denied = DeathScaleAITool.execute(inputJSON: #"{"section":"all"}"#, profileId: "p2", store: store, toolEnabled: true)
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.text.hasPrefix("permission_denied"))
        let disabled = DeathScaleAITool.execute(inputJSON: #"{"section":"all"}"#, profileId: "p1", store: store, toolEnabled: false)
        XCTAssertTrue(disabled.isError)
    }

    func testReadsAllSectionsInShanghaiTime() throws {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let t0 = Date(timeIntervalSince1970: 1_790_838_005)
        var clock = t0
        let store = DeathScaleStore(root: root, now: { clock })
        store.grantRead("p1")
        _ = store.add(side: .die, text: "累", weight: 4)
        _ = store.add(side: .live, text: "小雾", weight: 9)
        store.startHour()
        clock += 61
        store.endHour()
        store.setCarnet("横线纸")

        let r = DeathScaleAITool.execute(inputJSON: #"{"section":"all","limit":2}"#, profileId: "p1", store: store, toolEnabled: true)
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("UTC+8"))
        XCTAssertTrue(r.text.contains("total weight 4"))
        XCTAssertTrue(r.text.contains("total weight 9"))
        XCTAssertTrue(r.text.contains("01.10.2026 · 15:00:05 – 01.10.2026 · 15:01:06 (0:01:01)"))
        XCTAssertTrue(r.text.contains("last 2 of 4"))
        XCTAssertTrue(r.text.contains("横线纸"))

        let bad = DeathScaleAITool.execute(inputJSON: #"{"section":"write"}"#, profileId: "p1", store: store, toolEnabled: true)
        XCTAssertTrue(bad.isError)
        XCTAssertEqual(store.ledger.count, 4, "读不留痕")
    }

    func testNeverOffloaded() {
        XCTAssertTrue(ConversationViewModel.skipsOffload(DeathScaleAITool.toolName))
    }

    // MARK: schema 契约（共享 golden fixture 不收私有工具，death_scale 的双家形状钉在这里）

    /// 原 `Fixtures/tools-schema-golden.json` 里的两段 death_scale，逐字搬来（#009 从共享 fixture 移出）
    private static let goldenJSON = #"""
        {
          "anthropic": {
            "description": "Read-only access to \"Mort sans sépulture\", Susu's own private scale. It holds her personal record of reasons to die (left pan) and reasons to live (right pan), each written by her with a weight from 1 to 9; an append-only ledger of every change with the running totals of both pans; the time periods she marked, to the second; and her notebook (carnet). This is Susu's intimate private record. You can only read it, never change it. All times are Asia/Shanghai (UTC+8).\nsection: reasons = both pans and their totals; ledger = most recent ledger entries; hours = marked periods; carnet = the notebook text; all = everything. limit caps how many ledger entries / periods are returned (default 50, max 500).",
            "input_schema": {
              "properties": {
                "limit": {
                  "description": "Max ledger entries / periods to return, newest kept (default 50, max 500)",
                  "type": "integer"
                },
                "section": {
                  "description": "Which part to read",
                  "enum": [
                    "reasons",
                    "ledger",
                    "hours",
                    "carnet",
                    "all"
                  ],
                  "type": "string"
                }
              },
              "required": [
                "section"
              ],
              "type": "object"
            },
            "name": "death_scale"
          },
          "openai": {
            "function": {
              "description": "Read-only access to \"Mort sans sépulture\", Susu's own private scale. It holds her personal record of reasons to die (left pan) and reasons to live (right pan), each written by her with a weight from 1 to 9; an append-only ledger of every change with the running totals of both pans; the time periods she marked, to the second; and her notebook (carnet). This is Susu's intimate private record. You can only read it, never change it. All times are Asia/Shanghai (UTC+8).\nsection: reasons = both pans and their totals; ledger = most recent ledger entries; hours = marked periods; carnet = the notebook text; all = everything. limit caps how many ledger entries / periods are returned (default 50, max 500).",
              "name": "death_scale",
              "parameters": {
                "properties": {
                  "limit": {
                    "description": "Max ledger entries / periods to return, newest kept (default 50, max 500)",
                    "type": "integer"
                  },
                  "section": {
                    "description": "Which part to read",
                    "enum": [
                      "reasons",
                      "ledger",
                      "hours",
                      "carnet",
                      "all"
                    ],
                    "type": "string"
                  }
                },
                "required": [
                  "section"
                ],
                "type": "object"
              }
            },
            "type": "function"
          }
        }
        """#

    private func canonical(_ obj: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
    }

    /// 和 ToolRegistryTests.testSchemaMatchesGoldenFixture 同一条渲染路径：ToolRegistry.all 的定义 → ToolSchemaRenderer
    func testSchemaMatchesGolden() throws {
        let golden = try JSONSerialization.jsonObject(with: Data(Self.goldenJSON.utf8)) as! [String: Any]
        let entry = try XCTUnwrap(ToolRegistry.all.first { $0.definition.name == DeathScaleAITool.toolName })
        XCTAssertEqual(try canonical(ToolSchemaRenderer.openAI(entry.definition)), try canonical(golden["openai"]!), "openai/death_scale schema 漂移")
        XCTAssertEqual(try canonical(ToolSchemaRenderer.anthropic(entry.definition)), try canonical(golden["anthropic"]!), "anthropic/death_scale schema 漂移")
    }
}
#endif
