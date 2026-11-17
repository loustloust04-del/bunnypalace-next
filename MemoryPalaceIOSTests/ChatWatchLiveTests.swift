import UIKit
import XCTest
@testable import 记忆花园

/// 11-12 iOS 真机 live（一起看 #00751：发消息带「一起看」文字 + 画面、新工具 browser_video = 请求内容变了，10-17 规矩的 😷 真跑）：
/// 合成的一起看小包（虚构片名 / 字幕 + 一张画了数字的画面）→ anthropic-official Haiku 真发，看请求里图在、模型答得出只有字幕 / 画面才有的事；
/// 再带 browser_video 的定义问「倒回去 10 秒」，看模型按 schema 调工具。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头。
@MainActor
final class ChatWatchLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?
    private var model: ProviderModel?

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "ChatWatchLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()

        let manager = ProviderManager()
        let id = "xctest-chatwatch-live-ios-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        manager.addCredential(APICredential(
            id: id, name: "ChatWatch Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        self.manager = manager
        self.model = model
        credentialId = id
    }

    override func tearDown() async throws {
        CatalogLiveAuthProtocol.onOutgoingBody = nil
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        model = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    /// 虚构片子的一起看小包：字幕里有「雾三点散」，画面上画了一个大大的 7
    private func watchPack() throws -> (note: PendingChatAttachment, frame: PendingChatAttachment) {
        let probe = ChatWatchPerception.Probe(hasVideo: true, title: "雾湾灯塔纪录片", time: 42, duration: 300, paused: true, cue: "", rect: .zero)
        let captions = [
            ChatWatchPerception.CaptionLine(time: 31, text: "守灯人贝洛·栖川说：今晚的雾会在凌晨三点散开"),
            ChatWatchPerception.CaptionLine(time: 38, text: "他把第七盏备用灯挂上了北边的窗"),
        ]
        let text = ChatWatchPerception.note(title: "雾湾灯塔纪录片", url: "https://example.invalid/watch/fog-bay",
                                            probe: probe, captions: captions, imageTimes: [40])
        let note = PendingChatAttachment.text(name: "一起看 0:42", typeDescription: "一起看", extractedText: text, byteCount: text.utf8.count)
        let frame = try PendingChatAttachment.image(name: "画面 0:40.jpg", typeDescription: "一起看画面", mimeType: "image/jpeg",
                                                    data: try XCTUnwrap(Self.syntheticFrame()))
        return (note, frame)
    }

    /// 512×288 深蓝底，中间白色大字「7」
    private static func syntheticFrame() -> Data? {
        let size = CGSize(width: 512, height: 288)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 200, weight: .bold), .foregroundColor: UIColor.white]
            let text = NSAttributedString(string: "7", attributes: attrs)
            let bounds = text.size()
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    func testLiveHaikuAnswersFromWatchNoteAndFrameOnDevice() async throws {
        let manager = try XCTUnwrap(manager), model = try XCTUnwrap(model)
        let pack = try watchPack()
        let question = "刚才字幕里说雾几点散？画面上那个大数字是几？用一句话回答。"
        let modelInput = ChatAttachmentPromptBuilder.modelInput(text: question, attachments: [pack.note])
        XCTAssertTrue(modelInput.contains("〔一起看〕你们正在一起看：雾湾灯塔纪录片"))
        XCTAssertTrue(modelInput.contains("[0:31] 守灯人贝洛·栖川说"))

        var bodies: [Data] = []
        CatalogLiveAuthProtocol.onOutgoingBody = { bodies.append($0) }
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("chatwatch-live-ios-\(UUID().uuidString).jsonl"))
        var content = ""
        var failure: String?
        let done = expectation(description: "chat")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: modelInput)],
            systemPrompt: nil,
            providerManager: manager,
            samplingParams: SamplingParams(),
            imageMap: [modelInput: [pack.frame]],
            onToken: { _ in },
            onComplete: { text, _ in content = text; done.fulfill() },
            onError: { message in failure = message; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)
        print("[CHATWATCH-LIVE-IOS] chat: chars=\(content.count) outcome=\(router.lastReplyOutcome.rawValue) answer=\(content.prefix(60))")
        if let failure { XCTFail("真发失败：\(CatalogLiveAuthProtocol.redacted(failure))") }
        let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("\"type\":\"image\""), "请求里要带上画面")
        XCTAssertTrue(content.contains("三") || content.contains("3"), "要从字幕答出三点")
        XCTAssertTrue(content.contains("7") || content.contains("七"), "要从画面答出数字 7")
        XCTAssertEqual(router.lastReplyOutcome, .normal)
    }

    /// v2 V7 陪看一拍：规矩 + 拼图 + 字幕真发，回的要么是沉默标记、要么是一两句（不复述剧情）
    func testLiveHaikuCompanionBeatIsSilentOrShortOnDevice() async throws {
        let manager = try XCTUnwrap(manager), model = try XCTUnwrap(model)
        let frame = try XCTUnwrap(Self.syntheticFrame())
        let collage = try XCTUnwrap(ChatWatchCollage.render([(30, frame), (38, frame)]))
        let text = ChatWatchPerception.beatText(index: 3, from: 30, to: 42, captions: [
            .init(time: 31, text: "守灯人贝洛·栖川说：今晚的雾会在凌晨三点散开"),
            .init(time: 38, text: "他把第七盏备用灯挂上了北边的窗"),
        ], hasImage: true)
        let image = try PendingChatAttachment.image(name: "陪看 第3拍.jpg", typeDescription: "一起看画面", mimeType: "image/jpeg", data: collage)
        var bodies: [Data] = []
        CatalogLiveAuthProtocol.onOutgoingBody = { bodies.append($0) }
        let router = ProviderRouter(usageContext: UsageContext(kind: .watchAlong))
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("chatwatch-beat-\(UUID().uuidString).jsonl"))
        var reply = ""
        var failure: String?
        let done = expectation(description: "beat")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "我们一起看这个吧"), (role: "assistant", content: "好呀，开始吧"), (role: "user", content: text)],
            systemPrompt: "你是她的朋友小岚。\n\n" + ChatWatchPerception.companionRules(title: "雾湾灯塔纪录片"),
            providerManager: manager, samplingParams: SamplingParams(), imageMap: [text: [image]],
            onToken: { _ in },
            onComplete: { r, _ in reply = r; done.fulfill() },
            onError: { failure = $0; done.fulfill() })
        await fulfillment(of: [done], timeout: 120)
        print("[CHATWATCH-LIVE-IOS] beat: silent=\(ChatWatchPerception.isSilence(reply)) chars=\(reply.count) reply=\(reply.prefix(60))")
        if let failure { XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
        let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("\"type\":\"image\""), "一拍要带拼图")
        XCTAssertTrue(ChatWatchPerception.isSilence(reply) || reply.count <= 120, "要么不说话，要么一两句")
        XCTAssertEqual(router.lastReplyOutcome, .normal)
    }

    func testLiveHaikuCallsBrowserVideoOnDevice() async throws {
        let manager = try XCTUnwrap(manager), model = try XCTUnwrap(model)
        let pack = try watchPack()
        let modelInput = ChatAttachmentPromptBuilder.modelInput(text: "倒回去 10 秒，我没听清。", attachments: [pack.note])

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("chatwatch-live-ios-tool-\(UUID().uuidString).jsonl"))
        var calls: [ToolCallBlock] = []
        var failure: String?
        let done = expectation(description: "tool")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: modelInput)],
            systemPrompt: "你们在一起看视频。她让你控制视频时，调用 browser_video。",
            providerManager: manager,
            samplingParams: SamplingParams(),
            tools: [ToolSchemaRenderer.anthropic(BrowserOperateTools.videoDefinition)],
            onToken: { _ in },
            onComplete: { _, _ in failure = "模型没调工具，直接回话了"; done.fulfill() },
            onError: { message in failure = message; done.fulfill() },
            onToolCalls: { blocks, _ in calls = blocks; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)
        if let failure { XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
        let call = try XCTUnwrap(calls.first)
        print("[CHATWATCH-LIVE-IOS] tool: name=\(call.name) args=\(call.argumentsJSON)")
        XCTAssertEqual(call.name, BrowserOperateTools.videoName)
        let args = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(args["action"] as? String, "back")
        XCTAssertEqual((args["seconds"] as? NSNumber)?.doubleValue ?? 10, 10, accuracy: 0.01)
        // 模型给的参数过得了 app 自己的校验
        XCTAssertNotNil(ChatWatchPerception.controlArgs(action: "back", seconds: (args["seconds"] as? NSNumber)?.doubleValue, rate: nil))
    }
}
