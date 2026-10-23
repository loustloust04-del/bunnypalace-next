import Foundation

/// txt 章节正文 → 阅读器可渲染的 HTML 字符串。
///
/// 设计：
/// - 段落按空行切，每段一个 `<p>`
/// - 章节标题作 `<h2>`
/// - 内联 CSS 用 MP 主题色（暖奶白 #FFFBF6 + 浅灰薄荷 #E7EEEC），暗色模式自动
/// - 不引外网资源（无 web font / 无 CDN），严格 file:// 安全
/// - 用 `prefers-color-scheme` 跟随系统暗色
///
/// JS 桥（生成的 HTML 自带一段 inline script）：
/// - 滚动节流（200ms）→ `bookReader.postMessage({type:"scroll", ratio: 0-1})`
/// - selectionchange → `bookReader.postMessage({type:"select", text, start, end})`
/// - `ready` 事件首次加载完通知 Swift
enum ChapterHTMLRenderer {

    /// 字体大小档位（pt），对应阅读器设置面板的滑块刻度
    enum FontSize: Int, CaseIterable, Codable {
        case xs = 14
        case sm = 16
        case md = 18   // 默认
        case lg = 20
        case xl = 22
        case xxl = 24

        var label: String {
            switch self {
            case .xs: return "极小"; case .sm: return "小"; case .md: return "中"
            case .lg: return "大"; case .xl: return "大"; case .xxl: return "极大"
            }
        }
    }

    struct Style {
        var fontSize: FontSize = .md
        var lineHeight: Double = 1.8        // 中文阅读舒适区
        var paragraphSpacing: Double = 0.6  // em
    }

    /// 一段需要在原文上着色的标注。M3 用：高亮 / AI 划线。
    /// 用章节内字符 offset 锚定（跟 selection 报上来的 start/end 同口径——纯文本字符序）。
    struct Annotation {
        enum Kind { case highlight, aiUnderline, note }
        /// CR-1 双色：笔迹主人（Note.role 映射）。
        enum Author { case user, ai }
        let id: String
        let kind: Kind
        let start: Int   // 章节内纯文本 offset
        let end: Int
        var author: Author = .user
        /// 选段原文快照（失锚检测用；空 = 跳过校验）。
        var anchorText: String = ""
        /// P2 笔画颜色 `#RRGGBB`；空 = 按 author（自己薄荷、AI 玫瑰）
        var colorHex: String = ""
        var style: HighlightStyle = .fill
    }

    /// 渲染一章。
    /// - parameter title: 章节标题（h2 显示）
    /// - parameter text: 章节正文纯文本
    /// - parameter style: 排版风格
    /// - parameter chapterNo: 当前章号（透传给 JS bridge）
    /// - parameter totalChapters: 总章数
    /// - parameter annotations: 该章节已有的高亮/AI 划线/笔记锚点（M3）
    static func render(
        title: String,
        text: String,
        style: Style = Style(),
        chapterNo: Int,
        totalChapters: Int,
        annotations: [Annotation] = [],
        vocabWords: [String] = []
    ) -> String {
        let paragraphs = splitParagraphs(text)

        // 算每段在「全章纯文本流」里的起止 offset——必须跟 JS selection 报上来的 offset 同口径。
        // JS 那边用 `range.setEnd(article)` 取 toString().length，等价于 article.textContent
        // 字符序——会把 h2 的标题也算进去。所以这里也要把 title 的长度算进 base。
        // 注意：JS 端 article.textContent 是 "<h2>title</h2><p>...</p>..." 拼起来去标签后的串，
        // 没有标签间的空白。我们这边各段直接 join 不带分隔，base offset 就是 title.count + 前面段总长。
        let titleLen = title.count
        var paragraphRanges: [(start: Int, end: Int)] = []
        var cursor = titleLen
        for p in paragraphs {
            let len = p.count
            paragraphRanges.append((cursor, cursor + len))
            cursor += len
        }

        let layers = underlineLayers(annotations)
        let bodyHTML = paragraphs.enumerated().map { (idx, p) -> String in
            let (pStart, pEnd) = paragraphRanges[idx]
            let inner = applyAnnotationsToParagraph(
                text: p,
                paragraphStart: pStart,
                paragraphEnd: pEnd,
                annotations: annotations,
                underlineLayers: layers
            )
            return "<p data-pi=\"\(idx)\" data-ps=\"\(pStart)\">\(inner)</p>"
        }.joined(separator: "\n")

        let css = stylesheet(style: style)
        let js = bridgeScript(chapterNo: chapterNo, totalChapters: totalChapters, vocabWords: vocabWords)

        return """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <title>\(escape(title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <article id="chapter">
        <h2>\(escape(title))</h2>
        \(bodyHTML)
        </article>
        <script>\(js)</script>
        </body>
        </html>
        """
    }

    // MARK: - 段落标注切片（P2 多层笔画）

    /// 下划线笔画的层号：全章按起点排、贪心取「和它重叠的下划线都没用的最小层」。
    /// 层号跟着笔画走（跨段 / 跨行不变），同一道线不会这一行在上、下一行在下。
    static func underlineLayers(_ annotations: [Annotation]) -> [String: Int] {
        let uls = annotations.enumerated()
            .filter { $0.element.kind != .aiUnderline && $0.element.style == .underline && $0.element.start < $0.element.end }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        var placed: [(end: Int, start: Int, layer: Int)] = []
        var out: [String: Int] = [:]
        for a in uls {
            let busy = Set(placed.filter { $0.start < a.end && a.start < $0.end }.map(\.layer))
            var k = 0
            while busy.contains(k) { k += 1 }
            placed.append((a.end, a.start, k))
            out[a.id] = k
        }
        return out
    }

    /// 按所有笔画的起止点把段落切成片，每片带「盖在它上面的笔画」（按传入顺序 = 划的先后）：
    /// - 底色 / 彩笔 / 下划线都画成这一片的背景层，文字 DOM 只有一份，不加左右内边距（不挪字）
    /// - 底色半透明层层叠，后划的在上；下划线按层号往下错开，用垂直内边距腾出位置（行内元素垂直内边距不影响排版）
    /// - AI 虚线（aiUnderline）单独一层，仍是 `.ai-ul`
    /// - data-ids = 这一片命中的所有笔画 id（点了弹就地小窗）
    static func applyAnnotationsToParagraph(
        text: String,
        paragraphStart: Int,
        paragraphEnd: Int,
        annotations: [Annotation],
        underlineLayers: [String: Int]? = nil
    ) -> String {
        let chars = Array(text)
        guard !chars.isEmpty else { return "" }

        let clipped: [(ann: Annotation, s: Int, e: Int)] = annotations.compactMap { a in
            let s = max(0, max(a.start, paragraphStart) - paragraphStart)
            let e = min(chars.count, min(a.end, paragraphEnd) - paragraphStart)
            return s < e ? (a, s, e) : nil
        }
        if clipped.isEmpty { return escape(text) }
        let layers = underlineLayers ?? Self.underlineLayers(annotations)

        var cuts = Set([0, chars.count])
        for c in clipped { cuts.insert(c.s); cuts.insert(c.e) }
        let points = cuts.sorted()

        var out = ""
        var pending: (html: String, attrs: String)? = nil
        func flush() {
            guard let p = pending else { return }
            out += p.attrs.isEmpty ? p.html : "<span\(p.attrs)>\(p.html)</span>"
            pending = nil
        }
        for k in 0..<(points.count - 1) {
            let a = points[k], b = points[k + 1]
            let covering = clipped.filter { $0.s <= a && b <= $0.e }.map(\.ann)
            let attrs = segmentAttributes(covering, layers: layers)
            let html = escape(String(chars[a..<b]))
            // 相邻片笔画一样就并成一个 span（切点来自别的段外笔画时常见）
            if let p = pending, p.attrs == attrs {
                pending = (p.html + html, attrs)
            } else {
                flush()
                pending = (html, attrs)
            }
        }
        flush()
        return out
    }

    /// 一片文字的 span 属性（class / data-ids / style）；没有笔画返回空串。
    private static func segmentAttributes(_ covering: [Annotation], layers: [String: Int]) -> String {
        guard !covering.isEmpty else { return "" }
        let marks = covering.filter { $0.kind != .aiUnderline }
        let hasAIUnderline = covering.contains { $0.kind == .aiUnderline }

        var classes: [String] = []
        if !marks.isEmpty { classes.append("mk") }
        if hasAIUnderline { classes.append("ai-ul") }

        var bgLayers: [String] = []
        var style = ""
        if !marks.isEmpty {
            let maxLayer = marks.compactMap { $0.style == .underline ? layers[$0.id] : nil }.max()
            let pad = maxLayer.map { 3 * $0 + 4 } ?? 0
            let contentSize = pad > 0 ? "100% calc(100% - \(pad)px)" : "100% 100%"
            // CSS 背景层第一层在最上：后划的笔画排前面
            for m in marks.reversed() {
                let rgb = rgbTriplet(m)
                switch m.style {
                case .fill:
                    let c = "rgba(\(rgb),0.30)"
                    bgLayers.append("linear-gradient(\(c),\(c)) 0 0/\(contentSize) no-repeat")
                case .underline:
                    let k = layers[m.id] ?? 0
                    let c = "rgba(\(rgb),0.9)"
                    bgLayers.append("linear-gradient(\(c),\(c)) 0 calc(100% - \(pad - 3 - 3 * k)px)/100% 2px no-repeat")
                case .pen:
                    bgLayers.append("url(\(penStroke(id: m.id, rgb: rgb))) 0 0/\(contentSize) no-repeat")
                }
            }
            style = "background:\(bgLayers.joined(separator: ","))" + (pad > 0 ? ";padding-bottom:\(pad)px" : "")
        }
        let ids = covering.map(\.id).sorted().joined(separator: ",")
        return " class=\"\(classes.joined(separator: " "))\" data-ids=\"\(escape(ids))\""
            + (style.isEmpty ? "" : " style=\"\(escape(style))\"")
    }

    private static func rgbTriplet(_ a: Annotation) -> String {
        let fallback: UInt = a.author == .ai ? 0xC98A8A : 0x8EBD9F
        let v = HighlightPalette.hexValue(a.colorHex) ?? fallback
        return "\((v >> 16) & 0xFF),\((v >> 8) & 0xFF),\(v & 0xFF)"
    }

    /// 彩笔：马克笔笔道（压在字的下半截、上下边缘有点抖）。形状由笔画 id 决定，每次渲染一样。
    static func penStroke(id: String, rgb: String) -> String {
        var h: UInt64 = 1469598103934665603
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        func j(_ base: Double, _ spread: Double) -> String {
            h = h &* 6364136223846793005 &+ 1442695040888963407
            let r = Double(h >> 33) / Double(1 << 31)
            return String(format: "%.1f", base + (r - 0.5) * spread)
        }
        let path = "M0,\(j(9, 2)) Q25,\(j(8, 2.5)) 50,\(j(9, 2)) T100,\(j(8.5, 2)) L100,\(j(18.5, 1.5)) Q75,\(j(19.5, 1.5)) 50,\(j(18.5, 1.5)) T0,\(j(19, 1.5)) Z"
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 20' preserveAspectRatio='none'><path d='\(path)' fill='rgba(\(rgb),0.45)'/></svg>"
        let encoded = svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "data:image/svg+xml,\(encoded)"
    }

    // MARK: - 失锚检测（CR-1）

    /// 章内文本流切片（title+段落 join 口径，与 annotation offset 同域）。
    /// 高亮融合时重建合并区间的 anchorText 用。越界返回 nil。
    static func flowSlice(title: String, text: String, start: Int, end: Int) -> String? {
        let flow = title + splitParagraphs(text).joined()
        let chars = Array(flow)
        guard start >= 0, end <= chars.count, start < end else { return nil }
        return String(chars[start..<end])
    }

    /// 整章比对：annotation 的 offset 切片 vs anchorText 快照。
    /// **宽容模式**：去空白归一化后比对（跨段换行/段内折叠差异免疫，只有真实文字变化才判失锚）；
    /// anchorText 空跳过。失锚不影响渲染（照常上色），只供抽屉标「原文已变」——零视觉回归。
    static func brokenAnchorIds(title: String, text: String, annotations: [Annotation]) -> Set<String> {
        let flow = title + splitParagraphs(text).joined()
        let chars = Array(flow)
        var broken: Set<String> = []
        for a in annotations where !a.anchorText.isEmpty {
            guard a.start >= 0, a.end <= chars.count, a.start < a.end else {
                broken.insert(a.id)
                continue
            }
            let slice = String(chars[a.start..<a.end])
            if normalizeAnchor(slice) != normalizeAnchor(a.anchorText) {
                broken.insert(a.id)
            }
        }
        return broken
    }

    private static func normalizeAnchor(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }

    // MARK: - 段落切分

    /// txt 段落识别：
    /// 1. 标准排版（段间空行）→ 按 `\n\n` 切，段内单 `\n` 折叠成空格
    /// 2. 紧凑排版（每段一行，没空行）→ fallback 按单 `\n` 切
    ///
    /// 触发紧凑分支的条件：`\n\n` 切出 ≤ 1 段，但章里有多个 `\n` 行。
    /// 网文抓取的 txt 常见"每段一行"格式，老逻辑会把整章压成一坨——这条 fallback 是修这个。
    static func splitParagraphs(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                              .replacingOccurrences(of: "\r", with: "\n")

        // trim 必须含换行：奇数连 \n（如 \n\n\n）切完剩单个 \n 粘在段首，
        // 标准路径会把它折成前导空格（5fdfda1d 回归，testSplitParagraphsByBlankLine 抓的）
        let byDouble = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if byDouble.count <= 1 {
            let bySingle = normalized.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if bySingle.count > byDouble.count {
                return bySingle
            }
        }

        // 标准路径：段内单 \n 折叠成空格（避免硬换行打散）
        return byDouble.map { $0.replacingOccurrences(of: "\n", with: " ") }
    }

    // MARK: - HTML 转义

    /// 防 XSS：用户书内容里可能有 `<` `>` `&` `"` `'`
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - 样式

    /// 内联 CSS。MP 主题色：暖奶白 #FFFBF6 + 浅灰薄荷 #E7EEEC + 薄荷强调 #8EBD9F。
    /// 暗色模式：跟随系统 `prefers-color-scheme`。
    private static func stylesheet(style: Style) -> String {
        """
        :root {
          --bg: #FFFBF6;
          --bg-card: #FAF6F0;
          --text: #2C2A28;
          --text-muted: #8A8682;
          --accent: #E7EEEC;
          --mint: #8EBD9F;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1E1D1B;
            --bg-card: #25241F;
            --text: #E8E5DF;
            --text-muted: #9A958E;
            --accent: #2F3B36;
            --mint: #6FA383;
          }
        }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--bg);
          color: var(--text);
          -webkit-text-size-adjust: 100%;
          -webkit-font-smoothing: antialiased;
          font-family: -apple-system, "PingFang SC", "Hiragino Sans GB",
                       "Microsoft YaHei", "Songti SC", "STSong", serif;
        }
        article#chapter {
          /* iOS Notch / 圆角 / home indicator 全避开；左右至少 20px */
          padding-top: max(24px, env(safe-area-inset-top));
          padding-right: max(20px, env(safe-area-inset-right));
          padding-bottom: max(80px, env(safe-area-inset-bottom));
          padding-left: max(20px, env(safe-area-inset-left));
          max-width: 720px;
          margin: 0 auto;
          box-sizing: border-box;
          font-size: \(style.fontSize.rawValue)px;
          line-height: \(style.lineHeight);
        }
        h2 {
          font-size: 1.4em;
          margin: 0 0 1.5em;
          padding-bottom: 0.5em;
          border-bottom: 1px solid var(--accent);
          color: var(--mint);
          font-weight: 600;
        }
        p {
          margin: 0 0 \(style.paragraphSpacing)em;
          text-indent: 2em;
          text-align: justify;
        }
        /* P2 笔画：颜色 / 样式都在每片的 inline background 里；clone = 折行后每行各画一份（彩笔不会被拉长） */
        .mk {
          -webkit-box-decoration-break: clone;
          box-decoration-break: clone;
        }
        .ai-ul {
          border-bottom: 1px dashed var(--mint);
          padding-bottom: 1px;
        }
        /* CR-3：已收生词——点状下划线（与 AI 虚线区分），点击弹词卡 */
        .vocab-ul {
          border-bottom: 1.5px dotted rgba(142, 142, 142, 0.65);
          padding-bottom: 1px;
        }
        ::selection {
          background: rgba(142, 189, 159, 0.4);
        }
        """
    }

    // MARK: - JS Bridge

    private static func bridgeScript(chapterNo: Int, totalChapters: Int, vocabWords: [String] = []) -> String {
        // 词表 JSON 化进脚本（收词后 rerender 走既有管线，与 annotations 同生命周期）
        let vocabJSON = (try? String(data: JSONEncoder().encode(vocabWords), encoding: .utf8)) ?? "[]"
        return """
        (function(){
          const post = (msg) => {
            try { window.webkit.messageHandlers.bookReader.postMessage(msg); } catch(_) {}
          };

          // CR-3：已收生词 → 文本节点内 whole-word 包 .vocab-ul（JS 后处理不动
          // textContent 字符序，selection/annotation offset 口径不受影响；学 tasogare
          // 但补词边界：ASCII 词用 \\b，含 CJK 的词组直接精确串匹配）
          const MP_VOCAB = \(vocabJSON);
          const escRe = (s) => s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
          function mpApplyVocab() {
            if (!MP_VOCAB.length) return;
            const pats = MP_VOCAB.map(w => {
              const e = escRe(w);
              return /^[\\x00-\\x7F]+$/.test(w) ? '\\\\b' + e + '\\\\b' : e;
            });
            const re = new RegExp('(' + pats.join('|') + ')', 'gi');
            const article = document.getElementById('chapter');
            if (!article) return;
            const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
              acceptNode: (n) => n.parentElement && n.parentElement.closest('.vocab-ul')
                ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
            });
            const targets = [];
            let node;
            while ((node = walker.nextNode())) {
              if (re.test(node.nodeValue)) targets.push(node);
              re.lastIndex = 0;
            }
            for (const t of targets) {
              const frag = document.createDocumentFragment();
              let last = 0;
              const s = t.nodeValue;
              s.replace(re, (m, _g, off) => {
                frag.appendChild(document.createTextNode(s.slice(last, off)));
                const span = document.createElement('span');
                span.className = 'vocab-ul';
                span.setAttribute('data-word', m.toLowerCase());
                span.textContent = m;
                frag.appendChild(span);
                last = off + m.length;
                return m;
              });
              frag.appendChild(document.createTextNode(s.slice(last)));
              t.parentNode.replaceChild(frag, t);
            }
          }

          // 选区 → {text, start, end}。offset 按「字」数（grapheme），和 Swift 的 String.count 同口径：
          // emoji / 生僻字在 JS 里占两个 UTF-16 单位，直接用 .length 会让后面的划线整体错位。
          const glen = (s) => {
            if (window.Intl && Intl.Segmenter) { let n = 0; for (const _ of new Intl.Segmenter().segment(s)) n++; return n; }
            return Array.from(s).length;
          };
          window.mpSelection = function() {
            const sel = window.getSelection();
            if (!sel || sel.isCollapsed || !sel.toString().trim()) return null;
            const article = document.getElementById('chapter');
            if (!article) return null;
            const range = sel.getRangeAt(0);
            const pre = document.createRange();
            pre.selectNodeContents(article);
            pre.setEnd(range.startContainer, range.startOffset);
            const upto = document.createRange();
            upto.selectNodeContents(article);
            upto.setEnd(range.endContainer, range.endOffset);
            return {text: sel.toString(), start: glen(pre.toString()), end: glen(upto.toString())};
          };
          const selecting = () => {
            const sel = window.getSelection();
            return !!(sel && !sel.isCollapsed && sel.toString().trim());
          };

          window.mpApplyVocab = mpApplyVocab;   // 原地换正文（改划线颜色）后重新包生词

          // 点击生词 → 词卡；生词正好在划线里 → 弹批注小窗，小窗里再给「查生词」入口（两个都能到）
          document.addEventListener('click', (e) => {
            const v = e.target.closest('.vocab-ul');
            if (!v) return;
            const w = v.getAttribute('data-word');
            if (!w) return;
            const mark = selecting() ? null : v.closest('[data-ids]');
            if (mark) {
              const ids = (mark.getAttribute('data-ids') || '').split(',').filter(Boolean);
              if (ids.length) { post({type: 'noteTap', noteIds: ids, word: w, chapter: \(chapterNo)}); return; }
            }
            post({type: 'vocabTap', word: w, chapter: \(chapterNo)});
          }, {passive: true});

          // ready
          window.addEventListener('load', () => {
            mpApplyVocab();
            post({type: 'ready', chapter: \(chapterNo), total: \(totalChapters)});
          });

          // scroll 节流（rAF + 200ms 节流）
          let scrollTicking = false;
          let lastScrollTs = 0;
          window.addEventListener('scroll', () => {
            const now = Date.now();
            if (scrollTicking || now - lastScrollTs < 200) return;
            scrollTicking = true;
            requestAnimationFrame(() => {
              const docH = document.documentElement.scrollHeight - window.innerHeight;
              const ratio = docH > 0 ? Math.min(1, Math.max(0, window.scrollY / docH)) : 0;
              post({type: 'scroll', ratio: ratio, chapter: \(chapterNo)});
              lastScrollTs = Date.now();
              scrollTicking = false;
            });
          }, {passive: true});

          // R4：点任何批注划线（高亮/AI色/双色/虚线）→ 就地小窗（Swift 弹 NoteQuickLook）。
          // 生词虚线（.vocab-ul）另有 handler 且在文本节点更内层，closest 先命中它——保持优先。
          document.addEventListener('click', (e) => {
            if (e.target.closest('.vocab-ul')) return;
            if (selecting()) return;   // 正在选字：不弹批注
            const span = e.target.closest('[data-ids]');
            if (!span) return;
            const ids = (span.getAttribute('data-ids') || '').split(',').filter(Boolean);
            if (!ids.length) return;
            post({type: 'noteTap', noteIds: ids, chapter: \(chapterNo)});
          }, {passive: true});

          // 单击正文空白 → 阅读器浮出 / 收起控件。点到生词、批注、链接，或正选着字，都不算。
          document.addEventListener('click', (e) => {
            if (e.target.closest('.vocab-ul, [data-ids], a, button')) return;
            const sel = window.getSelection();
            if (sel && !sel.isCollapsed && sel.toString().trim()) return;
            post({type: 'tap'});
          }, {passive: true});

          // 选段（mouseup/touchend 后取 selection）
          const reportSelection = () => {
            const r = window.mpSelection();
            if (!r) return;
            post({type: 'select', text: r.text, start: r.start, end: r.end, chapter: \(chapterNo)});
          };
          document.addEventListener('mouseup', () => setTimeout(reportSelection, 10));
          document.addEventListener('touchend', () => setTimeout(reportSelection, 10));
        })();
        """
    }

    // MARK: - 恢复滚动位置（Swift → JS）

    /// 生成一段 JS 让 webView 滚到指定 ratio（0-1），Swift 端 evaluateJavaScript 调用。
    static func scrollToRatioScript(_ ratio: Double) -> String {
        let r = max(0, min(1, ratio))
        return """
        (function(){
          const docH = document.documentElement.scrollHeight - window.innerHeight;
          window.scrollTo({top: docH * \(r), behavior: 'instant'});
        })();
        """
    }
}
