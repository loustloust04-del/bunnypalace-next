import CoreGraphics
import Foundation

/// AI 在花园浏览器里动手（docs/plan-ai-browser-operate.md D1）：注入页面的脚本 + 结果解析 + 写动作认字。
/// 脚本自己写（Pocket 只借了思路）：只读取元素和派发点击 / 输入，不拦请求、不改页面样式。
enum BrowserOperatorScript {
    /// 一个能点 / 能填的东西。x/y/w/h 是网页视口坐标（CSS px = 点）
    struct Item: Equatable {
        let ref: Int
        let kind: String
        let label: String
        let rect: CGRect
    }

    struct Snapshot: Equatable {
        let title: String
        let url: String
        let text: String
        let items: [Item]
    }

    static let textLimit = 8000
    static let itemLimit = 120

    /// 取正文 + 元素清单，给每个元素打 data-mp-ref。密码框、看不见的、iframe 里的都不进清单
    static let snapshotJS = """
    (() => {
      document.querySelectorAll('[data-mp-ref]').forEach(e => e.removeAttribute('data-mp-ref'));
      const sel = 'a[href],button,input,textarea,select,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[contenteditable=true],[onclick]';
      const out = [];
      let n = 0;
      for (const el of document.querySelectorAll(sel)) {
        if (out.length >= \(itemLimit)) break;
        if (el.tagName === 'INPUT' && ['password','hidden'].includes((el.type || '').toLowerCase())) continue;
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) continue;
        const st = getComputedStyle(el);
        if (st.visibility === 'hidden' || st.display === 'none' || parseFloat(st.opacity) === 0) continue;
        if (r.bottom < -innerHeight || r.top > innerHeight * 3) continue;
        const raw = el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || el.alt || el.name || '';
        const label = raw.replace(/\\s+/g, ' ').trim().slice(0, 60);
        let kind = el.tagName.toLowerCase();
        if (kind === 'input') kind = 'input:' + (el.type || 'text').toLowerCase();
        if (kind === 'a') kind = 'link';
        if (!label && !kind.startsWith('input') && kind !== 'textarea' && kind !== 'select') continue;
        n += 1;
        el.setAttribute('data-mp-ref', String(n));
        out.push({ ref: n, kind, label, x: r.left, y: r.top, w: r.width, h: r.height });
      }
      const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, \(textLimit));
      return JSON.stringify({ title: document.title || '', url: location.href, text, items: out });
    })()
    """

    /// 把第 ref 个滚到屏幕中间，回它现在的视口位置
    static func revealJS(_ ref: Int) -> String {
        """
        (() => {
          const el = document.querySelector('[data-mp-ref="\(ref)"]');
          if (!el) return JSON.stringify({ error: 'missing' });
          el.scrollIntoView({ block: 'center', inline: 'center' });
          const r = el.getBoundingClientRect();
          return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height });
        })()
        """
    }

    static func clickJS(_ ref: Int) -> String {
        """
        (() => {
          const el = document.querySelector('[data-mp-ref="\(ref)"]');
          if (!el) return 'missing';
          if (el.target === '_blank') el.target = '_self';
          el.focus && el.focus();
          el.click();
          return 'ok';
        })()
        """
    }

    /// 填字：原生 setter + input / change 事件（React 这类框架才认）；submit = 提交所在表单，没有表单就派回车
    static func typeJS(_ ref: Int, text: String, submit: Bool) -> String {
        let quoted = jsString(text)
        return """
        (() => {
          const el = document.querySelector('[data-mp-ref="\(ref)"]');
          if (!el) return 'missing';
          if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'password') return 'password';
          el.focus && el.focus();
          if (el.isContentEditable) {
            el.innerText = \(quoted);
          } else {
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value');
            if (setter && setter.set) setter.set.call(el, \(quoted)); else el.value = \(quoted);
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          // 填完收键盘：AI 在填，不该弹键盘挡住网页（11-11 模拟器实测）
          if (!\(submit ? "true" : "false")) { el.blur && el.blur(); }
          if (\(submit ? "true" : "false")) {
            const form = el.form || el.closest('form');
            if (form && form.requestSubmit) { form.requestSubmit(); }
            else {
              const opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true };
              el.dispatchEvent(new KeyboardEvent('keydown', opts));
              el.dispatchEvent(new KeyboardEvent('keyup', opts));
            }
          }
          return 'ok';
        })()
        """
    }

    static func scrollJS(down: Bool) -> String {
        "(() => { window.scrollBy(0, \(down ? "" : "-")Math.round(innerHeight * 0.8)); return String(Math.round(scrollY)); })()"
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }

    static func parseSnapshot(_ json: String) -> Snapshot? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        let items: [Item] = (obj["items"] as? [[String: Any]] ?? []).compactMap { d in
            guard let ref = d["ref"] as? Int, let kind = d["kind"] as? String else { return nil }
            func num(_ k: String) -> CGFloat { CGFloat((d[k] as? NSNumber)?.doubleValue ?? 0) }
            return Item(ref: ref, kind: kind, label: d["label"] as? String ?? "",
                        rect: CGRect(x: num("x"), y: num("y"), width: num("w"), height: num("h")))
        }
        return Snapshot(title: obj["title"] as? String ?? "", url: obj["url"] as? String ?? "",
                        text: obj["text"] as? String ?? "", items: items)
    }

    static func parseRect(_ json: String) -> CGRect? {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], d["error"] == nil,
              let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
              let w = (d["w"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 给模型看的清单：一行一个「[3] 按钮「登录」」
    static func itemList(_ items: [Item]) -> String {
        items.map { "[\($0.ref)] \(kindName($0.kind))「\($0.label.isEmpty ? "（无文字）" : $0.label)」" }.joined(separator: "\n")
    }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "link": return "链接"
        case "button": return "按钮"
        case "textarea": return "多行输入框"
        case "select": return "下拉框"
        case "input:checkbox": return "勾选框"
        case "input:radio": return "单选"
        case "input:submit", "input:button": return "按钮"
        case "input:search": return "搜索框"
        default: return kind.hasPrefix("input") ? "输入框" : "可点的"
        }
    }

    /// 写动作认字（粟粟 11-11「弹（可授权）」）：按钮 / 链接文字像发布、点赞、购买、删除…… 先问。按动作文字认，不按站点
    static let writeWords = [
        "发布", "发送", "发帖", "发表", "评论", "回复", "转发", "点赞", "赞", "关注", "收藏", "购买", "下单", "支付", "付款",
        "删除", "提交", "确认", "注销", "退出登录",
        "post", "send", "tweet", "reply", "comment", "like", "follow", "buy", "order", "pay", "checkout", "delete", "remove", "submit", "publish",
    ]

    static func isWriteAction(_ label: String) -> Bool {
        let l = label.lowercased()
        guard !l.isEmpty, l.count <= 20 else { return false }
        return writeWords.contains { word in
            word.allSatisfy(\.isASCII) ? l.split(whereSeparator: { !$0.isLetter }).contains(Substring(word)) : l.contains(word)
        }
    }
}
