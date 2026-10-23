import XCTest
@testable import 记忆花园

/// plan-study-zero-engine：学堂模板标记行 / 四态判定 / 宏 / 笔记路径 / 第一条消息 / 补丁规矩
final class StudyTemplateTests: XCTestCase {

    func testMarkerParsesVersionAndKnownHash() throws {
        let parsed = try XCTUnwrap(StudyTemplate.parse(instructions: StudyTemplate.current))
        XCTAssertEqual(parsed.version, StudyTemplate.version)
        XCTAssertEqual(StudyTemplate.knownBodies[StudyTemplate.version], parsed.bodyHash)
        XCTAssertTrue(StudyTemplate.current.hasPrefix("【学堂模板 v1 · "))
    }

    func testPlainFolderIsNotStudy() {
        XCTAssertNil(StudyTemplate.parse(instructions: "这里都是写代码的对话"))
        XCTAssertNil(StudyTemplate.parse(instructions: ""))
        XCTAssertNil(StudyTemplate.status(of: "第二行才是 \n【学堂模板 v1 · x】"))
    }

    func testStatusStates() {
        let current = StudyTemplate.current
        XCTAssertEqual(StudyTemplate.status(of: current), .current)
        // 正文首尾空白不算改过（FolderEditSheet 存盘会 trim）
        XCTAssertEqual(StudyTemplate.status(of: current + "\n\n"), .current)
        XCTAssertEqual(StudyTemplate.status(of: current + "多一个字"), .currentModified)
        let v0 = current.replacingOccurrences(of: "【学堂模板 v1", with: "【学堂模板 v0")
        XCTAssertEqual(StudyTemplate.status(of: v0), .outdatedModified)
    }

    func testTemplateMacrosAreCacheSafe() throws {
        let text = StudyTemplate.current
        XCTAssertFalse(text.contains("{{date}}"))
        XCTAssertFalse(text.contains("{{time}}"))
        let regex = try NSRegularExpression(pattern: #"\{\{[^}]*\}\}"#)
        let ns = text as NSString
        let macros = Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        XCTAssertEqual(macros, ["{{char}}", "{{user}}"])
        XCTAssertFalse(text.contains("⟪{目标主题}⟫"))
    }

    func testTemplatePatchRules() {
        let text = StudyTemplate.current
        XCTAssertTrue(text.contains("禁止整份重写"))
        XCTAssertTrue(text.contains("<!-- learn:end -->"))
        XCTAssertTrue(text.contains("结束标记"))
        XCTAssertTrue(text.contains("fs_edit"))
        XCTAssertTrue(text.contains("（课堂笔记：……）"))
    }

    func testNotePathCleansTopic() {
        XCTAssertEqual(StudyTemplate.notePath(topic: "  为什么天是蓝的  ") { _ in false }, "学堂/为什么天是蓝的/课堂笔记.html")
        XCTAssertEqual(StudyTemplate.notePath(topic: "TCP/IP 协议") { _ in false }, "学堂/TCPIP 协议/课堂笔记.html")
        XCTAssertEqual(StudyTemplate.notePath(topic: "第一行\n第二行") { _ in false }, "学堂/第一行 第二行/课堂笔记.html")
        XCTAssertEqual(StudyTemplate.courseName(topic: String(repeating: "长", count: 40)).count, 20)
        XCTAssertEqual(StudyTemplate.courseName(topic: " / "), "未命名课程")
        XCTAssertEqual(StudyTemplate.courseName(topic: "../x"), "x")
    }

    func testNotePathAddsSequenceWhenTaken() {
        let taken: Set<String> = ["学堂/为什么天是蓝的", "学堂/为什么天是蓝的 2"]
        XCTAssertEqual(StudyTemplate.notePath(topic: "为什么天是蓝的") { taken.contains($0) }, "学堂/为什么天是蓝的 3/课堂笔记.html")
    }

    func testFirstMessageRoundTrip() {
        let path = "学堂/为什么天是蓝的/课堂笔记.html"
        let message = StudyTemplate.firstMessage(topic: "为什么天是蓝的", notePath: path)
        XCTAssertEqual(message, "我想系统学：为什么天是蓝的\n（课堂笔记：学堂/为什么天是蓝的/课堂笔记.html）")
        XCTAssertEqual(StudyTemplate.notePath(fromFirstMessage: message), path)
        XCTAssertNil(StudyTemplate.notePath(fromFirstMessage: "我想系统学：光"))
        XCTAssertNil(StudyTemplate.notePath(fromFirstMessage: "（课堂笔记：）"))
    }

    func testUniqueFolderName() {
        XCTAssertEqual(StudyTemplate.uniqueName("学堂", taken: []), "学堂")
        XCTAssertEqual(StudyTemplate.uniqueName("学堂", taken: ["学堂"]), "学堂 2")
        XCTAssertEqual(StudyTemplate.uniqueName("学堂", taken: ["学堂", "学堂 2"]), "学堂 3")
    }

    func testChangedAnchorPrefersInsertedElement() {
        let old = "<section id=\"learn\">\n<details id=\"A1\">\n<summary id=\"A1-s\">A₁</summary>\n<!-- A1:end --></details>\n<!-- learn:end -->\n</section>"
        let inserted = old.replacingOccurrences(of: "<!-- learn:end -->", with: "<details id=\"A2\">\n<!-- A2:end --></details>\n<!-- learn:end -->")
        XCTAssertEqual(StudyNotePane.changedAnchor(old: old, new: inserted), "A2")
        let row = "<tr id=\"L-A2\"><td>A₂</td><td>尚未探索</td></tr>"
        XCTAssertEqual(StudyNotePane.changedAnchor(old: row, new: row.replacingOccurrences(of: "尚未探索", with: "检查通过")), "L-A2")
    }

    // MARK: - P5 S1：Claude Code 上课

    func testCCSessionNameIsHubSafe() throws {
        let name = StudyTemplate.ccSessionName(conversationId: "3F2A9C1B-7D4E-4A2B-9C3D-1E2F3A4B5C6D")
        XCTAssertEqual(name, "mp-cc-study-3f2a9c1b")
        let regex = try NSRegularExpression(pattern: #"^[A-Za-z0-9_.-]{1,32}$"#)
        XCTAssertNotNil(regex.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)))
        XCTAssertNotEqual(name, ConversationViewModel.deriveCCSession("3F2A9C1B-7D4E-4A2B-9C3D-1E2F3A4B5C6D"))
    }

    func testCCInstructionsExpandMacrosAndKeepBody() {
        let text = StudyTemplate.ccInstructions(userName: "禾禾", charName: "小克")
        XCTAssertFalse(text.contains("{{"))
        XCTAssertTrue(text.hasPrefix("# 写在课程说明前面（Claude Code 版）"))
        XCTAssertTrue(text.contains("你在通过「记忆花园」app 的 Claude Code 桥给 禾禾 上课"))
        XCTAssertTrue(text.contains("```html"))
        XCTAssertTrue(text.hasSuffix(MacroExpander.expand(StudyTemplate.body, userName: "禾禾", charName: "小克")))
        XCTAssertTrue(text.contains("你仍然是 小克，保持和 禾禾 之间原有的称呼与关系"))
        // 内置正文没动：标记行哈希仍是 v1 已知值
        XCTAssertEqual(StudyTemplate.status(of: StudyTemplate.current), .current)
    }

    func testCCInstructionsFollowFolderBody() {
        // 没改过的学堂：去掉标记行就是内置正文
        XCTAssertEqual(StudyTemplate.teachingBody(of: StudyTemplate.current), StudyTemplate.body)
        // 她改过：附件跟着改过的那份走（和 API 卡走 system 的内容一致）
        let edited = StudyTemplate.markerLine + "\n\n我改过的说明：叫我 {{user}}\n"
        let body = StudyTemplate.teachingBody(of: edited)
        XCTAssertEqual(body, "我改过的说明：叫我 {{user}}")
        let text = StudyTemplate.ccInstructions(body: body, userName: "禾禾", charName: "小克")
        XCTAssertTrue(text.hasPrefix("# 写在课程说明前面（Claude Code 版）"))
        XCTAssertTrue(text.hasSuffix("我改过的说明：叫我 禾禾"))
        XCTAssertFalse(text.contains("螺旋逼近教学系统 v2.2（学堂版）"))
        // 没有标记行（不该发生）：原文照用
        XCTAssertEqual(StudyTemplate.teachingBody(of: "  随便一段\n"), "随便一段")
    }

    func testCCFirstMessageAndAttachmentRideTheSendFrame() throws {
        let first = StudyTemplate.ccFirstMessage(topic: "为什么天是蓝的")
        XCTAssertEqual(first, "我想系统学：为什么天是蓝的\n先 Read 附件里的课程说明（学堂课程说明.md），严格照它给我上课；之后忘了规则就重新 Read 那个文件。")
        let attachment = StudyTemplate.ccAttachment(userName: "禾禾", charName: "小克")
        XCTAssertTrue(attachment.isFile)
        XCTAssertEqual(attachment.mimeType, "text/markdown")
        let instructions = StudyTemplate.ccInstructions(userName: "禾禾", charName: "小克")
        XCTAssertEqual(attachment.fileData, Data(instructions.utf8))

        // 节点正文：说明不进正文，也不会被认成笔记路径
        let parts = ChatAttachmentPromptBuilder.userMessage(displayBase: first, attachments: [attachment])
        XCTAssertLessThan(parts.modelText.count, 300)
        XCTAssertNil(StudyTemplate.notePath(fromFirstMessage: parts.modelText))
        // CVM.prepareRouterPayload 在「[附件：」处砍掉附件壳，发给 CC 的正文 = 第一条消息原文
        let marker = try XCTUnwrap(parts.modelText.range(of: "[附件："))
        XCTAssertEqual(String(parts.modelText[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), first)
        // 节点存 .fileData 段；buildAPIMessages 把它还原成带原始字节的附件交给 CC
        let segments = try XCTUnwrap(parts.segments)
        guard case .fileData(let name, let mime, let data) = try XCTUnwrap(segments.last) else {
            return XCTFail("附件段应为 .fileData")
        }
        XCTAssertEqual(name, StudyTemplate.ccAttachmentName)
        XCTAssertEqual(mime, "text/markdown")
        let rebuilt = PendingChatAttachment.text(name: name, typeDescription: name, extractedText: "",
                                                 byteCount: data.count, fileData: data, fileMime: mime)

        let frame = CCBridgeWebSocketClient.sendFrame(
            chatId: "chat", messageId: "msg", content: first, user: "禾禾",
            session: StudyTemplate.ccSessionName(conversationId: "3f2a9c1b-0000"), replyTo: nil, attachments: [rebuilt])
        XCTAssertEqual(frame["session_name"] as? String, "mp-cc-study-3f2a9c1b")
        XCTAssertEqual(frame["content"] as? String, first)
        XCTAssertFalse((frame["content"] as? String ?? "").contains("螺旋逼近"))
        XCTAssertNil(frame["images"])
        let files = try XCTUnwrap(frame["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["name"] as? String, "学堂课程说明.md")
        XCTAssertEqual(files[0]["mime"] as? String, "text/markdown")
        let b64 = try XCTUnwrap(files[0]["b64"] as? String)
        XCTAssertEqual(Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }, instructions)
        // 发送层真正做的是 JSONSerialization → 字符串帧
        let json = try JSONSerialization.data(withJSONObject: frame)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(decoded["type"] as? String, "send")
        XCTAssertEqual((decoded["files"] as? [[String: Any]])?.first?["name"] as? String, "学堂课程说明.md")
    }

    func testLastHTMLBlock() {
        XCTAssertNil(StudyNotePane.lastHTMLBlock(in: "没有代码块"))
        XCTAssertNil(StudyNotePane.lastHTMLBlock(in: "```swift\nlet a = 1\n```"))
        XCTAssertNil(StudyNotePane.lastHTMLBlock(in: "```html\n<p>还没写完"))
        let text = "第一圈\n```html\n<p>旧</p>\n```\n中间\n```HTML\n<html><body>新</body></html>\n```\n📒 账本快照\n```\n表\n```"
        XCTAssertEqual(StudyNotePane.lastHTMLBlock(in: text), "<html><body>新</body></html>")
        // 外层四个反引号包住内层 ``` 不被提前关掉
        let nested = "````html\n<pre>\n```js\nx\n```\n</pre>\n````"
        XCTAssertEqual(StudyNotePane.lastHTMLBlock(in: nested), "<pre>\n```js\nx\n```\n</pre>")
    }
}
