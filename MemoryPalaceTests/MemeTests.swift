import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import 记忆花园

/// 气泡发表情包（plan-bubble-sticker-send）：记号、给模型的文字 / 当轮附图、标题不漏编号、看图起名解析
final class MemeTests: XCTestCase {

    func testTokenRoundTrip() {
        let id = UUID()
        XCTAssertEqual(MemeToken.match(MemeToken.make(id)), id)
        XCTAssertEqual(MemeToken.match("  \(MemeToken.make(id))\n"), id)
    }

    func testTokenOnlyWhenWholeMessage() {
        let id = UUID()
        XCTAssertNil(MemeToken.match("哈哈 \(MemeToken.make(id))"))
        XCTAssertNil(MemeToken.match("[meme:不是编号]"))
        XCTAssertNil(MemeToken.match("[sticker:\(id.uuidString)]"))
    }

    func testPromptText() {
        XCTAssertEqual(MemeToken.promptText(name: "馋了", detail: "眯眼舔嘴"), "〖表情包：馋了——眯眼舔嘴〗")
        XCTAssertEqual(MemeToken.promptText(name: "馋了", detail: ""), "〖表情包：馋了〗")
        XCTAssertEqual(MemeToken.promptText(name: nil, detail: nil), "〖表情包〗")
    }

    func testTitlerHidesToken() {
        XCTAssertEqual(ConversationTitler.plainText(MemeToken.make(UUID())), "[表情包]")
        XCTAssertEqual(ConversationTitler.sanitizedFallback(firstUser: MemeToken.make(UUID())), "[表情包]")
    }

    func testPromptPartsTextStableAndImageOnlyWhenAsked() throws {
        let pid = "meme-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: MemeStore.directory(profileId: pid).deletingLastPathComponent()) }
        let id = UUID()
        let saved = try MemeStore.save(Self.png(), id: id, profileId: pid)
        XCTAssertEqual(saved.mimeType, "image/png")
        let meme = ChatMeme(id: id, name: "开心", detail: "转圈", fileName: saved.fileName, mimeType: saved.mimeType, profileId: pid)

        let latest = MemeStore.promptParts(for: meme, attachImage: true)
        let older = MemeStore.promptParts(for: meme, attachImage: false)
        XCTAssertEqual(latest.text, older.text)
        XCTAssertEqual(latest.text, "〖表情包：开心——转圈〗")
        XCTAssertNotNil(latest.image)
        XCTAssertEqual(latest.image?.mimeType, "image/png")
        XCTAssertNil(older.image)

        XCTAssertEqual(MemeStore.promptParts(for: nil, attachImage: true).text, "〖表情包〗")
        XCTAssertNil(MemeStore.promptParts(for: nil, attachImage: true).image)
    }

    func testRejectsNonImageAndOversize() {
        XCTAssertThrowsError(try MemeStore.save(Data("hello".utf8), id: UUID(), profileId: "meme-test-x"))
        XCTAssertThrowsError(try MemeStore.save(Data(count: MemeStore.maxBytes + 1), id: UUID(), profileId: "meme-test-x"))
    }

    func testAutoNameParse() {
        let r = MemeAutoNamer.parse("名字：「馋了」\n描述：黄色圆脸眯眼舔嘴，表示想吃")
        XCTAssertEqual(r.name, "馋了")
        XCTAssertEqual(r.detail, "黄色圆脸眯眼舔嘴，表示想吃")
        XCTAssertEqual(MemeAutoNamer.parse("胡说八道").name, "")
    }

    private static func png() -> Data {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
