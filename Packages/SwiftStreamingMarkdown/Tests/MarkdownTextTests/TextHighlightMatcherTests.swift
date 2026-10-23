// MP fork: 划线 quote 在单个文字视图里的匹配（H1：存储不改，跨段 quote 按 \n 拆截、边缘锚定）。纯函数，两端共用。
import Foundation
@testable import SwiftStreamingMarkdown
import Testing

@Suite("Text highlight matcher")
struct TextHighlightMatcherTests {
  /// 改动前两端 reapplyHighlights 里的扫描，逐字照抄：单段 quote 的结果必须和它逐区间相同
  private func legacy(_ quote: String, _ text: NSString) -> [NSRange] {
    var out: [NSRange] = []
    var search = NSRange(location: 0, length: text.length)
    while true {
      let found = text.range(of: quote, options: [], range: search)
      guard found.location != NSNotFound, found.length > 0 else { break }
      out.append(found)
      let next = NSMaxRange(found)
      guard next < text.length else { break }
      search = NSRange(location: next, length: text.length - next)
    }
    return out
  }

  private func painted(_ quote: String, _ text: String) -> [String] {
    let ns = text as NSString
    return TextHighlightMatcher.ranges(of: quote, in: ns).map { ns.substring(with: $0) }
  }

  @Test("single-paragraph quotes: identical to the old scan")
  func singleParagraphUnchanged() {
    let cases: [(String, String)] = [
      ("薄荷", "窗台上的薄荷长得很好，薄荷分盆以后三盆都活着。"),
      ("aa", "aaaa a aa"),
      ("不存在", "窗台上的薄荷长得很好"),
      ("👍🏽", "好的👍🏽 再来👍🏽"),
      ("e\u{301}", "café cafe\u{301}"),
      ("尾", "尾"),
      ("x", ""),
    ]
    for (quote, text) in cases {
      #expect(TextHighlightMatcher.ranges(of: quote, in: text as NSString) == legacy(quote, text as NSString), "\(quote) in \(text)")
    }
    #expect(TextHighlightMatcher.ranges(of: "", in: "abc").isEmpty)
  }

  @Test("whole cross-paragraph quote inside one view (merged run): one range, newlines included")
  func wholeQuoteInMergedRun() {
    let run = "第一段说到这里结果跟理论完全一致\n2012年又有人重复了实验\n第三段开头这样写"
    #expect(painted("结果跟理论完全一致\n2012年又有人重复了实验\n第三段开头", run) == ["结果跟理论完全一致\n2012年又有人重复了实验\n第三段开头"])
  }

  @Test("across two paragraphs: head piece = end of first view, tail piece = start of second")
  func acrossTwo() {
    let quote = "结果跟理论完全一致\n2012年又有人"
    #expect(painted(quote, "第一段说到这里结果跟理论完全一致") == ["结果跟理论完全一致"])
    #expect(painted(quote, "2012年又有人重复了实验") == ["2012年又有人"])
    // 首截不在段尾 / 末截不在段首：不画
    #expect(painted(quote, "结果跟理论完全一致，后面还有字") == [])
    #expect(painted(quote, "前面有字2012年又有人重复了实验") == [])
    #expect(painted(quote, "完全无关的一段") == [])
  }

  @Test("across three paragraphs: inner piece needs the whole view to be equal")
  func acrossThree() {
    let quote = "段尾半句\n中间这一整段\n下一段的开头"
    #expect(painted(quote, "第一段的段尾半句") == ["段尾半句"])
    #expect(painted(quote, "中间这一整段") == ["中间这一整段"])
    #expect(painted(quote, "中间这一整段多一个字") == [])
    #expect(painted(quote, "多一个字中间这一整段") == [])
    #expect(painted(quote, "下一段的开头和后文") == ["下一段的开头"])
  }

  @Test("a view holding several pieces (soft break inside one paragraph)")
  func severalPiecesInOneView() {
    let quote = "A的结尾\nB第一行\nB第二行\nC的开头"
    // B 段本身带软换行：B 整段 = 中间两截
    #expect(painted(quote, "B第一行\nB第二行") == ["B第一行\nB第二行"])
    // 首段带软换行，引文从它第二行中间开始
    #expect(painted("第二行的尾巴\n下一段", "第一行\n第二行的尾巴") == ["第二行的尾巴"])
    // 一个视图里同时是开头几截
    #expect(painted(quote, "前文A的结尾\nB第一行") == ["A的结尾\nB第一行"])
    // 末尾几截
    #expect(painted(quote, "B第二行\nC的开头之后") == ["B第二行\nC的开头"])
  }

  @Test("emoji and composed characters stay whole")
  func emoji() {
    let quote = "收尾🎉👍🏽\n🇨🇳开头"
    #expect(painted(quote, "这一段收尾🎉👍🏽") == ["收尾🎉👍🏽"])
    #expect(painted(quote, "🇨🇳开头之后") == ["🇨🇳开头"])
    #expect(painted(quote, "👍🏽") == [])
  }

  @Test("CRLF in the stored quote matches \\n-separated paragraphs")
  func crlf() {
    let quote = "段尾\r\n段首"
    #expect(painted(quote, "前文段尾") == ["段尾"])
    #expect(painted(quote, "段首后文") == ["段首"])
    #expect(painted(quote, "前文段尾\n段首后文") == ["段尾\n段首"])
  }

  @Test("whitespace is literal")
  func whitespace() {
    #expect(painted("abc \ndef", "xx abc ") == ["abc "])
    #expect(painted("abc\ndef", "xx abc ") == [])
    #expect(painted("abc\n\ndef", "def ghi") == ["def"])
    #expect(painted("abc\n\ndef", "xx abc") == ["abc"])
  }

  /// T15：列表并进段落簇后，跨列表项选出来的 quote 只有各项的字（序号 / 圆点不在文字里），
  /// 合并开时整串在簇里命中；合并关（气泡模式 / 流式，一项一个视图）时按截在各项视图里画
  @Test("quotes across list items carry no markers and paint in both the run and per-item views")
  func acrossListItems() throws {
    let merged = MarkdownParserImpl.renderables(for: "前面一段\n\n- 第一项的后半句\n- 第二项\n\n1. 甲项\n2. 乙项\n\n后面一段",
                                                config: MarkdownRenderConfig(mergesTextRuns: true))
    guard case .textRun(_, let run)? = merged.first else { Issue.record("\(merged)"); return }
    let text = run.string as NSString
    // 从第一项中间选到有序第二项中间：系统选区拿到的就是这段子串
    let start = text.range(of: "后半句").location
    let end = NSMaxRange(text.range(of: "乙"))
    let quote = text.substring(with: NSRange(location: start, length: end - start))
    #expect(quote == "后半句\n第二项\n甲项\n乙")
    for marker in ["•", "◦", "1.", "2."] {
      #expect(!quote.contains(marker))
    }
    #expect(painted(quote, run.string) == [quote])
    // 合并关：各项自己一个视图
    #expect(painted(quote, "第一项的后半句") == ["后半句"])
    #expect(painted(quote, "第二项") == ["第二项"])
    #expect(painted(quote, "甲项") == ["甲项"])
    #expect(painted(quote, "乙项") == ["乙"])
    #expect(painted(quote, "前面一段") == [])
  }
}
