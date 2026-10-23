#if os(macOS)
import XCTest
@testable import 记忆花园

/// N1-i 图片（移植 Wake `parse_utils.rs` 图片测试 + 七种形状夹具）：只在详情路径解码、索引路径占位；远程 / 本地路径不碰；
/// 单张上限 + 转录总预算；正文与图片顺序；Claude 端到端（工具结果的图挂宿主）+ seq 契约
final class CodingSessionImageTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    private let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    func testSevenShapesDecodeOnlyOnTranscriptPath() throws {
        let url = CodingSessionAdapterTests.fixtures.appendingPathComponent("image_content_shapes.json")
        let fixtures = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(fixtures.count, 7)
        for fixture in fixtures {
            let name = fixture["name"] as? String ?? "?"
            let indexed = CodingParse.contentParts(fixture["content"])
            XCTAssertEqual(indexed.text, CodingLimits.imagePlaceholder, name)
            XCTAssertTrue(indexed.images.isEmpty, name)
            XCTAssertEqual(indexed.imageCount, 1, name)

            let transcript = CodingImageBudget.decoding { CodingParse.contentParts(fixture["content"]) }
            XCTAssertEqual(transcript.text, "", name)
            XCTAssertEqual(transcript.imageCount, 1, name)
            XCTAssertEqual(transcript.images.count, 1, name)
            XCTAssertEqual(transcript.images.first?.mediaType, "image/png", name)
            XCTAssertEqual(transcript.images.first.map { [UInt8]($0.data.prefix(8)) }, pngMagic, name)
        }
    }

    func testRemoteURLsAndNonImagesAreNeverDecoded() {
        let remote: [String: Any] = ["type": "image", "image_url": "https://example.com/private.png"]
        let parsed = CodingImageBudget.decoding { CodingParse.contentParts(remote) }
        XCTAssertEqual(parsed.text, CodingLimits.imagePlaceholder)
        XCTAssertTrue(parsed.images.isEmpty)

        let pdf: [String: Any] = ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": "AA=="]]
        XCTAssertFalse(CodingParse.isImagePart(pdf))
        let document = CodingImageBudget.decoding { CodingParse.contentParts(pdf) }
        XCTAssertTrue(document.text.isEmpty)
        XCTAssertTrue(document.images.isEmpty)

        let oversized = "data:image/png;base64," + String(repeating: "A", count: CodingImageDecoder.maxBase64 + 1)
        XCTAssertNil(CodingImageDecoder.dataURI(oversized, budget: CodingImageBudget()))
        XCTAssertNil(CodingImageDecoder.dataURI("data:text/plain;base64,\(png)", budget: CodingImageBudget()), "只收 image MIME")
        XCTAssertNil(CodingImageDecoder.dataURI("data:image/png,\(png)", budget: CodingImageBudget()), "只收 base64")
    }

    func testLocalPathsAreNeverRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mp-secret-\(UUID().uuidString).png")
        try XCTUnwrap(Data(base64Encoded: png)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for key in ["path", "url", "uri", "fileUri", "image_url"] {
            for value in [file.path, file.absoluteString] {
                let content: [String: Any] = ["type": "image", "media_type": "image/png", key: value]
                let parsed = CodingImageBudget.decoding { CodingParse.contentParts(content) }
                XCTAssertEqual(parsed.text, CodingLimits.imagePlaceholder, "\(key)=\(value)")
                XCTAssertTrue(parsed.images.isEmpty, "\(key)=\(value)")
            }
        }
    }

    func testTranscriptBudgetIsAggregateAndScoped() {
        let image: [String: Any] = ["type": "image", "media_type": "image/png", "data": png]
        CodingImageBudget.decoding(limit: 100) {
            XCTAssertEqual(CodingParse.contentParts(image).images.count, 1)
            let rejected = CodingParse.contentParts(image)
            XCTAssertTrue(rejected.images.isEmpty, "超预算退回占位")
            XCTAssertEqual(rejected.text, CodingLimits.imagePlaceholder)
            XCTAssertTrue(CodingImageBudget.decoding { CodingParse.contentParts(image) }.images.isEmpty, "嵌套沿用外层预算")
        }
        XCTAssertEqual(CodingImageBudget.decoding { CodingParse.contentParts(image) }.images.count, 1, "离开范围预算恢复")
        XCTAssertTrue(CodingParse.contentParts(image).images.isEmpty, "范围外 = 索引路径，不解码")
    }

    func testWrappersMimelessBytesAndSniffing() throws {
        let wrapped: [String: Any] = ["content": ["type": "image", "data": png]]
        XCTAssertEqual(CodingImageBudget.decoding { CodingParse.contentParts(wrapped) }.images.first?.mediaType, "image/png", "无 MIME 按魔数认")

        let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: png)))
        let array: [String: Any] = ["type": "image", "data": bytes.map { Int($0) }]
        XCTAssertEqual(CodingImageBudget.decoding { CodingParse.contentParts(array) }.images.first?.data, Data(bytes), "字节数组")

        let spaced: [String: Any] = ["type": "image", "media_type": "image/png; charset=binary",
                                     "data": String(png.prefix(20)) + "\n  " + String(png.dropFirst(20))]
        XCTAssertEqual(CodingImageBudget.decoding { CodingParse.contentParts(spaced) }.images.first?.mediaType, "image/png", "容忍空白、MIME 去参数")

        XCTAssertEqual(CodingImageDecoder.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(CodingImageDecoder.sniff(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(CodingImageDecoder.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "image/webp")
        XCTAssertEqual(CodingImageDecoder.sniff(Data("BM".utf8)), "image/bmp")
        XCTAssertEqual(CodingImageDecoder.sniff(Data([0x49, 0x49, 0x2A, 0x00])), "image/tiff")
        XCTAssertEqual(CodingImageDecoder.sniff(Data("<?xml version=\"1.0\"?><svg xmlns=\"x\"/>".utf8)), "image/svg+xml")
        XCTAssertNil(CodingImageDecoder.sniff(Data("hello".utf8)))
        let unknown: [String: Any] = ["type": "image", "data": Data("hello world!".utf8).base64EncodedString()]
        XCTAssertTrue(CodingImageBudget.decoding { CodingParse.contentParts(unknown) }.images.isEmpty, "认不出类型不收")
    }

    func testTextImageOrderAndClaudeTranscriptKeepsSeqContract() throws {
        let content: [Any] = [["type": "text", "text": "前面的说明"], ["type": "image", "media_type": "image/png", "data": png],
                              ["type": "text", "text": "后面的说明"]]
        let parsed = CodingImageBudget.decoding { CodingParse.contentParts(content) }
        XCTAssertEqual(parsed.text, "前面的说明\n\n后面的说明")
        XCTAssertEqual(parsed.images.count, 1)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-tmp-img")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let id = "12121212-aaaa-bbbb-cccc-000000000012"
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png]]
        func row(_ type: String, _ uuid: String, _ second: Int, _ message: [String: Any]) -> [String: Any] {
            ["type": type, "uuid": uuid, "sessionId": id, "cwd": "/tmp/img", "timestamp": "2026-09-01T10:00:0\(second).000Z", "message": message]
        }
        let rows = [
            row("user", "u1", 0, ["role": "user", "content": [image]]),
            row("user", "u2", 1, ["role": "user", "content": [["type": "text", "text": "看这张"], image]]),
            row("assistant", "a1", 2, ["id": "m1", "role": "assistant", "model": "claude-x",
                                       "content": [["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/tmp/x.png"]]]]),
            row("user", "u3", 3, ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": [image]]]]),
        ]
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let file = projectDir.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(root: root)
        let ref = try XCTUnwrap(adapter.fileRef(file))
        let transcript = try adapter.parseTranscript(ref).mainline
        XCTAssertEqual(transcript.count, 3)
        XCTAssertEqual(transcript[0].text, "", "纯图消息不留占位")
        XCTAssertEqual(transcript[0].images.count, 1)
        XCTAssertEqual(transcript[1].text, "看这张")
        XCTAssertEqual(transcript[1].images.count, 1)
        XCTAssertEqual(transcript[2].toolCalls.count, 1)
        XCTAssertEqual(transcript[2].images.count, 1, "工具结果里的图挂到宿主消息")

        let indexed = try ClaudeCodeAdapter.parse(file, includeSidechain: false).messages
        XCTAssertEqual(indexed.map(\.seq), transcript.map(\.seq), "seq 契约：索引与详情同一套序号")
        XCTAssertTrue(indexed.allSatisfy { $0.images.isEmpty }, "索引路径不解码")
        XCTAssertEqual(indexed[0].text, CodingLimits.imagePlaceholder)
    }
}
#endif
