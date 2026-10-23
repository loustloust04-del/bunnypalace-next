import XCTest
@testable import 记忆花园

/// Mermaid 图表卡接入（docs/plan-mermaid.md M10）：registry 三处 + 类型名
@MainActor
final class MermaidCardTests: XCTestCase {

    private let flow = "flowchart TD\n  A[开始] --> B[结束]"

    func testKindStreamingIsPlaceholderAndFinalIsMermaid() {
        XCTAssertEqual(ChatCardRegistry.kind(language: "mermaid", code: flow, streaming: true), .mermaidPlaceholder)
        XCTAssertEqual(ChatCardRegistry.kind(language: "mermaid", code: flow, streaming: false), .mermaid)
        XCTAssertEqual(ChatCardRegistry.kind(language: "Mermaid", code: flow, streaming: false), .mermaid)
    }

    func testStandaloneCardBlockAcceptsMermaid() {
        let block = "```mermaid\n\(flow)\n```"
        let hit = ChatCardRegistry.standaloneCardBlock("\n" + block + "\n")
        XCTAssertEqual(hit?.language, "mermaid")
        XCTAssertEqual(hit?.code, flow)
        XCTAssertNil(ChatCardRegistry.standaloneCardBlock("前文\n" + block))
    }

    func testTypeName() {
        XCTAssertEqual(MermaidCardView.typeName(svgType: "flowchart-v2", code: ""), "流程图")
        XCTAssertEqual(MermaidCardView.typeName(svgType: "sequence", code: ""), "时序图")
        XCTAssertEqual(MermaidCardView.typeName(svgType: nil, code: "graph LR\n a-->b"), "流程图")
        XCTAssertEqual(MermaidCardView.typeName(svgType: nil, code: "%% 注释\nclassDiagram\n A <|-- B"), "类图")
        XCTAssertEqual(MermaidCardView.typeName(svgType: nil, code: "---\ntitle: x\n---\nstateDiagram-v2\n [*] --> A"), "状态图")
        XCTAssertEqual(MermaidCardView.typeName(svgType: nil, code: "pie title 宠物\n \"狗\" : 3"), "饼图")
        XCTAssertEqual(MermaidCardView.typeName(svgType: "er", code: "erDiagram\n A ||--o{ B : has"), "图表")
    }
}
