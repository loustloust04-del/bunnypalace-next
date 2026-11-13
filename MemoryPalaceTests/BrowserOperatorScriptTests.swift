import XCTest
@testable import 记忆花园

/// plan-ai-browser-operate D1：页面清单解析、给模型的清单、写动作认字、JS 字符串转义
final class BrowserOperatorScriptTests: XCTestCase {
    func testParseSnapshotAndList() throws {
        let json = """
        {"title":"维基","url":"https://zh.wikipedia.org/","text":"正文",
         "items":[{"ref":1,"kind":"input:search","label":"搜索维基百科","x":10,"y":20,"w":200,"h":36},
                  {"ref":2,"kind":"button","label":"搜索","x":220,"y":20,"w":60,"h":36},
                  {"ref":3,"kind":"link","label":"","x":0,"y":80,"w":40,"h":20}]}
        """
        let snap = try XCTUnwrap(BrowserOperatorScript.parseSnapshot(json))
        XCTAssertEqual(snap.title, "维基")
        XCTAssertEqual(snap.items.count, 3)
        XCTAssertEqual(snap.items[0].rect, CGRect(x: 10, y: 20, width: 200, height: 36))
        XCTAssertEqual(BrowserOperatorScript.itemList(snap.items),
                       "[1] 搜索框「搜索维基百科」\n[2] 按钮「搜索」\n[3] 链接「（无文字）」")
        XCTAssertNil(BrowserOperatorScript.parseSnapshot("不是 json"))
    }

    func testParseRect() {
        XCTAssertEqual(BrowserOperatorScript.parseRect("{\"x\":1,\"y\":2,\"w\":3,\"h\":4}"), CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertNil(BrowserOperatorScript.parseRect("{\"error\":\"missing\"}"))
    }

    func testWriteActionWords() {
        for label in ["发布", "立即购买", "删除这条", "Post", "Like", "提交订单", "回复"] {
            XCTAssertTrue(BrowserOperatorScript.isWriteAction(label), label)
        }
        for label in ["搜索", "下一页", "咖啡", "Likely story", "登录", "", "这是一段很长很长很长很长的正文其中提到了发布会但不是按钮"] {
            XCTAssertFalse(BrowserOperatorScript.isWriteAction(label), label)
        }
    }

    func testJSStringEscapes() {
        XCTAssertEqual(BrowserOperatorScript.jsString("a\"b'c\n</script>"), "\"a\\\"b'c\\n<\\/script>\"")
    }

    func testPasswordFieldsNeverListed() {
        XCTAssertTrue(BrowserOperatorScript.snapshotJS.contains("['password','hidden']"))
        XCTAssertTrue(BrowserOperatorScript.typeJS(1, text: "x", submit: false).contains("return 'password'"))
    }
}
