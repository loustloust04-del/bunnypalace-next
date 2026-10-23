import Foundation

// 卡库第二批 B3：注进 mp-card 子文档 prelude 的脚本。
// - 两种模式都有：CSP 违规上报（cspReport）、自动高度（resize，原生夹 120–2000pt）
// - 交互模式另有：⑦ 的 ready / error / 外链窄消息 + 酒馆助手垫片（TavernHelper 与同名全局函数、事件常量、
//   内存版 storage、toastr、工具函数）；同步读查原生预置的快照，写走 call → 原生校验链 → result
// 子页里的一切都不可信：真正的闸全在原生（CardScriptGate / CardScriptPlanner），这里只是让卡照常写代码
enum CardScriptShim {
    /// 静态模式：只量高度 + 报被挡的资源（脚本只这一段带 nonce，正文里的脚本 CSP 不放）
    static func staticScript(token: String) -> String {
        common.replacingOccurrences(of: "__MP_TOKEN__", with: jsString(token))
            .replacingOccurrences(of: "__MP_INTERACTIVE__", with: "false")
    }

    /// 交互模式：通道 + 垫片。bridgeJSON = {"seg":n,"snapshot":{…}}（已做 script 安全转义）
    static func interactiveScript(token: String, bridgeJSON: String) -> String {
        common.replacingOccurrences(of: "__MP_TOKEN__", with: jsString(token))
            .replacingOccurrences(of: "__MP_INTERACTIVE__", with: "true")
            + "\n" + helpers + "\n"
            + shim.replacingOccurrences(of: "__MP_TOKEN__", with: jsString(token))
            .replacingOccurrences(of: "__MP_BRIDGE__", with: bridgeJSON)
    }

    private static func jsString(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    static func bridgeJSON(segmentId: String, snapshot: String?) -> String {
        let seg = Int(segmentId.dropFirst()) ?? 0
        return "{\"seg\":\(seg),\"snapshot\":\(snapshot ?? "null")}"
    }

    private static let common = #"""
    (function () {
      var T = __MP_TOKEN__;
      var P = window.parent;
      function send(p) { try { p.__mpCard = T; P.postMessage(p, "*"); } catch (_) {} }
      var cspCount = 0;
      document.addEventListener("securitypolicyviolation", function (e) {
        if (++cspCount > 50) return;
        send({ type: "cspReport", kind: "csp", text: (String(e.violatedDirective || "") + " " + String(e.blockedURI || "")).slice(0, 300) });
      });
      var lastH = 0, lastOver = null, queued = false;
      function px(el, k) { return parseFloat(getComputedStyle(el)[k]) || 0; }
      // 量内容本身（body 子内容的包围盒），不量 body：怪异模式 / 100vh 的 body 跟着 iframe 高度走，会越量越高
      function measure() {
        queued = false;
        var b = document.body;
        if (!b) return;
        var r = document.createRange();
        r.selectNodeContents(b);
        var box = r.getBoundingClientRect();
        var last = b.lastElementChild;
        var h = Math.ceil((box.height > 0 ? box.bottom + (window.scrollY || 0) : px(b, "marginTop") + px(b, "paddingTop"))
          + (last ? px(last, "marginBottom") : 0) + px(b, "paddingBottom") + px(b, "borderBottomWidth") + px(b, "marginBottom"));
        if (!isFinite(h) || h <= 0 || Math.abs(h - lastH) < 1) return;
        // 跟着视口长（内容用了 vh）：超出视口的量不变还在长 → 停在这里
        var over = h - window.innerHeight;
        if (h > lastH && over > 0 && lastOver !== null && Math.abs(over - lastOver) < 1) return;
        lastOver = over;
        lastH = h;
        send({ type: "resize", height: h });
      }
      function schedule() {
        if (queued) return;
        queued = true;
        (window.requestAnimationFrame || window.setTimeout)(measure);
      }
      function watch() {
        schedule();
        if (window.ResizeObserver && document.body) {
          var ro = new ResizeObserver(schedule);
          ro.observe(document.body);
          ro.observe(document.documentElement);
        }
      }
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch); else watch();
      window.addEventListener("load", schedule);
      if (!__MP_INTERACTIVE__) return;
      window.addEventListener("error", function (e) { send({ type: "error", message: String(e.message || "脚本错误").slice(0, 300) }); });
      window.addEventListener("unhandledrejection", function (e) {
        var r = e.reason; send({ type: "error", message: String((r && r.message) || r || "Promise 未处理拒绝").slice(0, 300) });
      });
      window.addEventListener("load", function () { send({ type: "ready" }); });
      document.addEventListener("click", function (e) {
        var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
        if (!a) return;
        var h = a.getAttribute("href") || "";
        if (h.charAt(0) === "#") return;
        e.preventDefault();
        send({ type: "openLink", href: String(a.href).slice(0, 2048) });
      }, true);
    })();
    """#

    /// 纯函数（单测用 JavaScriptCore 直接跑这一段）：范围解析照酒馆助手 string_to_range（含钳位）、
    /// 合并照 `_.mergeWith(…, 数组整体替换)`、路径删除照 `_.unset`
    static let helpers = #"""
    var __mpTH = (function () {
      function isPlain(v) { return v !== null && typeof v === "object" && Object.prototype.toString.call(v) === "[object Object]"; }
      function clamp(v, min, max) { v = v < 0 ? max + v + 1 : v; return Math.max(Math.min(v, max), min); }
      function stringToRange(input, min, max) {
        var start, end, m;
        input = String(input);
        if (/^(-?\d+)$/.test(input)) {
          start = end = clamp(Number(input), min, max);
        } else {
          m = input.match(/^(-?\d+)-(-?\d+)$/);
          if (!m) return null;
          var a = clamp(Number(m[1]), min, max), b = clamp(Number(m[2]), min, max);
          start = Math.min(a, b); end = Math.max(a, b);
        }
        if (isNaN(start) || isNaN(end)) return null;
        return { start: start, end: end };
      }
      function merge(target, source) {
        if (!isPlain(source)) return target;
        Object.keys(source).forEach(function (k) {
          var sv = source[k], tv = target[k];
          if (Array.isArray(sv)) target[k] = sv;
          else if (isPlain(sv)) target[k] = merge(tv !== null && typeof tv === "object" ? tv : {}, sv);
          else if (sv !== undefined || !(k in target)) target[k] = sv;
        });
        return target;
      }
      var rePropName = /[^.[\]]+|\[(?:(-?\d+(?:\.\d+)?)|(["'])((?:(?!\2)[^\\]|\\.)*?)\2)\]|(?=(?:\.|\[\])(?:\.|\[\]|$))/g;
      function toPath(path) {
        if (Array.isArray(path)) return path.map(String);
        var out = [];
        path = String(path);
        if (path.charCodeAt(0) === 46) out.push("");
        path.replace(rePropName, function (match, number, quote, sub) {
          out.push(quote ? sub.replace(/\\(\\)?/g, "$1") : (number || match));
        });
        return out;
      }
      function unset(obj, path) {
        var simple = typeof path === "number" || (typeof path === "string" && (/^\w*$/.test(path) ||
          !/\.|\[(?:[^[\]]*|(["'])(?:(?!\1)[^\\]|\\.)*?\1)\]/.test(path) || (obj != null && path in Object(obj))));
        var keys = simple ? [String(path)] : toPath(path);
        var cur = obj;
        for (var i = 0; i < keys.length - 1; i++) { if (cur == null) return true; cur = cur[keys[i]]; }
        return cur == null || delete cur[keys[keys.length - 1]];
      }
      function utf8Bytes(s) { return unescape(encodeURIComponent(String(s))).length; }
      function substitute(text, ctx) {
        return String(text).replace(/\{\{char\}\}/gi, function () { return String(ctx.char || ""); })
          .replace(/\{\{user\}\}/gi, function () { return String(ctx.user || ""); });
      }
      return { isPlain: isPlain, stringToRange: stringToRange, merge: merge, toPath: toPath, unset: unset, utf8Bytes: utf8Bytes, substitute: substitute };
    })();
    """#

    private static let shim = #"""
    (function () {
      "use strict";
      var T = __MP_TOKEN__;
      var P = window.parent;
      var H = __mpTH;
      var B = __MP_BRIDGE__ || {};
      var SEG = B.seg || 0;
      var VAR_LIMIT = 256 * 1024, ARGS_LIMIT = 256 * 1024;
      var S, IDX;
      function setSnapshot(s) {
        S = s || { messages: [], firstId: 0, lastId: -1, currentId: -1, chat: {}, char: "", user: "" };
        IDX = {};
        (S.messages || []).forEach(function (m) { IDX[m.message_id] = m; });
      }
      setSnapshot(B.snapshot);
      function send(p) { try { p.__mpCard = T; P.postMessage(p, "*"); } catch (_) {} }
      function clone(v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); }
      var reported = {};
      function report(name) {
        if (reported[name]) return;
        reported[name] = 1;
        send({ type: "cspReport", kind: "unsupported", text: String(name).slice(0, 120) });
      }
      function unsupported(name) { report(name); return new Error("记忆花园暂不支持 " + name); }

      /* ---- 原生调用（写）：call → result；写期间收到的快照先压着，写完再换 ---- */
      var seq = 0, pending = {}, writesOut = 0, buffered = null;
      function flush() { if (writesOut === 0 && buffered) { setSnapshot(buffered); buffered = null; } }
      /* slow = 要等你在原生确认框里点（B5 triggerSlash）：不压快照、等 10 分钟 */
      function callNative(method, args, slow) {
        return new Promise(function (resolve, reject) {
          var json;
          try { json = JSON.stringify(args); } catch (e) { reject(new Error("参数不能序列化")); return; }
          if (H.utf8Bytes(json) > ARGS_LIMIT) { reject(new Error("参数超过 256KB")); return; }
          var id = "c" + (++seq);
          var counted = !slow;
          if (counted) writesOut++;
          var timer = setTimeout(function () {
            if (!pending[id]) return;
            delete pending[id]; if (counted) writesOut--; flush();
            reject(new Error("记忆花园没有回应 " + method));
          }, slow ? 600000 : 30000);
          pending[id] = { resolve: resolve, reject: reject, timer: timer, counted: counted };
          send({ type: "call", id: id, method: method, args: JSON.parse(json) });
        });
      }

      /* ---- 事件（子页内维护；原生推来的和 eventEmit 走同一条） ---- */
      var L = {};
      function lst(t) { return L[t] || (L[t] = []); }
      function idx(t, fn) { var a = lst(t); for (var i = 0; i < a.length; i++) if (a[i].fn === fn) return i; return -1; }
      function eventRemoveListener(t, fn) { var i = idx(t, fn); if (i >= 0) lst(t).splice(i, 1); }
      function put(t, fn, first, once) {
        if (typeof fn !== "function") throw new Error("listener 必须是函数");
        var a = lst(t), i = idx(t, fn);
        var rec = i >= 0 ? a.splice(i, 1)[0] : { fn: fn, once: !!once };
        if (first) a.unshift(rec); else a.push(rec);
        return { stop: function () { eventRemoveListener(t, fn); } };
      }
      function eventOn(t, fn) { return idx(t, fn) >= 0 ? { stop: function () { eventRemoveListener(t, fn); } } : put(t, fn, false, false); }
      function eventOnce(t, fn) { return put(t, fn, false, true); }
      function eventMakeFirst(t, fn) { return put(t, fn, true, false); }
      function eventMakeLast(t, fn) { return put(t, fn, false, false); }
      function eventClearEvent(t) { L[t] = []; }
      function eventClearListener(fn) { Object.keys(L).forEach(function (t) { eventRemoveListener(t, fn); }); }
      function eventClearAll() { L = {}; }
      var MSG_ID_EVENTS = { message_swiped: 1, message_sent: 1, message_received: 1, message_edited: 1, message_updated: 1,
                            user_message_rendered: 1, character_message_rendered: 1 };
      function dispatch(t, args) {
        args = (args || []).slice();
        if (MSG_ID_EVENTS[t]) { args[0] = parseInt(args[0]); if (isNaN(args[0])) return Promise.resolve(); }
        return lst(t).slice().reduce(function (p, rec) {
          return p.then(function () {
            if (idx(t, rec.fn) < 0) return;
            if (rec.once) eventRemoveListener(t, rec.fn);
            try { return Promise.resolve(rec.fn.apply(null, args)).catch(function (e) { console.error(e); }); }
            catch (e) { console.error(e); }
          });
        }, Promise.resolve());
      }
      function eventEmit(t) { return dispatch(String(t), Array.prototype.slice.call(arguments, 1)); }
      function eventEmitAndWait(t) {
        var args = Array.prototype.slice.call(arguments, 1);
        lst(t).slice().forEach(function (rec) {
          if (rec.once) eventRemoveListener(t, rec.fn);
          try { rec.fn.apply(null, args); } catch (e) { console.error(e); }
        });
      }

      window.addEventListener("message", function (ev) {
        if (ev.source !== P) return;
        var d = ev.data;
        if (!d || typeof d !== "object" || d.__mpHost !== T) return;
        if (d.type === "result") {
          var p = pending[d.id];
          if (!p) return;
          delete pending[d.id]; clearTimeout(p.timer); if (p.counted) writesOut--; flush();
          if (d.ok) p.resolve(d.value); else p.reject(new Error(String(d.error || "调用失败")));
        } else if (d.type === "event") {
          dispatch(String(d.name), Array.isArray(d.args) ? d.args : []);
        } else if (d.type === "snapshotUpdate") {
          buffered = d.snapshot; flush();
        }
      });

      /* ---- 读消息 ---- */
      function getChatMessages(range, option) {
        option = option || {};
        var role = option.role || "all", hide = option.hide_state || "all", withSwipes = !!option.include_swipes;
        var text = H.substitute(String(range).replace(/\{\{lastMessageId\}\}/gi, String(S.lastId)), S);
        var r = H.stringToRange(text, 0, S.lastId);
        if (!r) return [];
        if (r.start < S.firstId) console.warn("[记忆花园] 快照只带了 " + S.firstId + " 楼之后的消息");
        var out = [];
        for (var i = r.start; i <= r.end; i++) {
          var m = IDX[i];
          if (!m) continue;
          if (role !== "all" && m.role !== role) continue;
          if (hide !== "all" && (hide === "hidden") !== !!m.is_hidden) continue;
          if (withSwipes) {
            out.push({ message_id: m.message_id, name: m.name, role: m.role, is_hidden: !!m.is_hidden, swipe_id: m.swipe_id,
                       swipes: m.swipes, swipes_data: m.swipes_data, swipes_info: (m.swipes || []).map(function () { return {}; }) });
          } else {
            out.push({ message_id: m.message_id, name: m.name, role: m.role, is_hidden: !!m.is_hidden, message: m.message,
                       data: m.data, extra: {}, swipe_id: m.swipe_id, swipes: m.swipes, swipes_data: m.swipes_data });
          }
        }
        return clone(out);
      }
      function getLastMessageId() { return S.lastId; }
      function getCurrentMessageId() { return S.currentId; }
      function getIframeName() { return "TH-message--" + S.currentId + "--" + SEG; }
      function getMessageId(name) {
        var m = String(name).match(/^TH-message--(\d+)--\d+(_\d+)?$/);
        if (!m) throw new Error("获取 " + name + " 所在楼层 id 时出错: 不要对全局脚本 iframe 调用 getMessageId!");
        return parseInt(m[1], 10);
      }

      /* ---- 写消息 ---- */
      var UNSUPPORTED_MSG_KEYS = ["swipes", "swipes_data", "swipes_info", "name", "role", "is_hidden", "extra"];
      function setChatMessages(list, option) {
        try {
          if (!Array.isArray(list)) throw new Error("setChatMessages 需要数组");
          var refresh = (option && option.refresh) || "affected";
          var count = S.lastId + 1;
          var msgs = list.map(function (m) {
            if (!m || typeof m.message_id !== "number") throw new Error("每条都要有 message_id");
            UNSUPPORTED_MSG_KEYS.forEach(function (k) { if (m[k] !== undefined) throw unsupported("setChatMessages 的 " + k); });
            var o = { message_id: m.message_id < 0 ? count + m.message_id : m.message_id };
            if (m.message !== undefined) o.message = String(m.message);
            if (m.data !== undefined) o.data = m.data;
            if (m.swipe_id !== undefined) o.swipe_id = m.swipe_id;
            return o;
          });
          return callNative("setChatMessages", { messages: msgs, option: { refresh: refresh } }).then(function () {});
        } catch (e) { return Promise.reject(e); }
      }
      function setChatMessage(fields, messageId, option) {
        option = option || {};
        fields = typeof fields === "string" ? { message: fields } : (fields || {});
        var swipe = option.swipe_id === undefined ? "current" : option.swipe_id;
        var refresh = option.refresh || "display_and_render_current";
        var map = { none: "none", display_current: "affected", display_and_render_current: "affected", all: "all" };
        if (typeof swipe !== "number" && swipe !== "current") return Promise.reject(new Error("提供的 swipe_id 无效, 请提供 'current' 或序号, 你提供的是: " + swipe));
        if (!map[refresh]) return Promise.reject(new Error("提供的 refresh 无效, 你提供的是: " + refresh));
        var id = messageId < 0 ? S.lastId + 1 + messageId : messageId;
        var m = IDX[id];
        if (!m) return Promise.resolve();
        var first = Promise.resolve();
        if (swipe !== "current" && swipe !== m.swipe_id) {
          if (swipe < 0 || swipe >= (m.swipes || []).length) return Promise.reject(unsupported("setChatMessage 新增消息页"));
          if (refresh === "none") return Promise.reject(unsupported("setChatMessage 改没显示的消息页"));
          first = setChatMessages([{ message_id: id, swipe_id: swipe }], { refresh: map[refresh] });
        }
        var w = { message_id: id };
        if (fields.message !== undefined) w.message = fields.message;
        if (fields.data !== undefined) w.data = fields.data;
        if (w.message === undefined && w.data === undefined) return first;
        return first.then(function () { return setChatMessages([w], { refresh: map[refresh] }); });
      }

      /* ---- 变量：只 message / chat；同步读写本地快照，整表 replace 回原生 ---- */
      function resolveId(id) {
        var count = S.lastId + 1;
        var n = (id === undefined || id === "latest") ? -1 : id;
        if (typeof n !== "number" || !(n >= -count && n < count)) {
          throw new Error("提供的消息楼层号 '" + id + "' 超出了范围 [" + (-count) + ", " + count + ")");
        }
        return n < 0 ? count + n : n;
      }
      function scopeOf(option) {
        var type = (option && option.type) || "chat";
        if (type === "chat") return { type: "chat" };
        if (type === "message") return { type: "message", id: resolveId(option.message_id) };
        throw unsupported(type + " 作用域的变量");
      }
      function readScope(sc) {
        if (sc.type === "chat") return S.chat || {};
        var m = IDX[sc.id];
        return m ? (m.data || {}) : {};
      }
      function getVariables(option) { return clone(readScope(scopeOf(option))); }
      function replaceVariables(variables, option) {
        var sc = scopeOf(option);
        if (!H.isPlain(variables)) throw new Error("variables 必须是对象");
        var json = JSON.stringify(variables);
        if (H.utf8Bytes(json) > VAR_LIMIT) throw new Error("变量表超过 256KB，没有保存");
        var copy = JSON.parse(json);
        if (sc.type === "chat") S.chat = copy;
        else {
          var m = IDX[sc.id];
          if (m) { m.data = copy; if (m.swipes_data) m.swipes_data[m.swipe_id || 0] = clone(copy); }
        }
        callNative("replaceVariables", { variables: copy, option: sc.type === "chat" ? { type: "chat" } : { type: "message", message_id: sc.id } })
          .catch(function (e) { console.error("[记忆花园] 变量没存上：" + (e && e.message)); });
      }
      function updateVariablesWith(updater, option) {
        var vars = getVariables(option);
        var result = updater(vars);
        if (result && typeof result.then === "function") {
          return result.then(function (r) { replaceVariables(r, option); return r; });
        }
        replaceVariables(result, option);
        return result;
      }
      function insertOrAssignVariables(variables, option) {
        return updateVariablesWith(function (old) { return H.merge(old, clone(variables)); }, option);
      }
      function insertVariables(variables, option) {
        return updateVariablesWith(function (old) { return H.merge(H.merge({}, clone(variables)), old); }, option);
      }
      function deleteVariable(path, option) {
        var occurred = false;
        var v = updateVariablesWith(function (old) { occurred = H.unset(old, path); return old; }, option);
        return { variables: v, delete_occurred: occurred };
      }
      function getAllVariables() {
        var out = H.merge({}, clone(S.chat || {}));
        for (var i = 0; i <= S.currentId; i++) { var m = IDX[i]; if (m && m.data) Object.assign(out, clone(m.data)); }
        return out;
      }

      /* ---- B5 替你发消息：/send /trigger /echo /setinput（解析、许可、防护全在原生）---- */
      function triggerSlash(command) {
        return callNative("triggerSlash", { command: String(command) }, true).then(function (v) { return v === undefined || v === null ? "" : String(v); });
      }

      /* ---- 工具 ---- */
      function toast(kind) {
        return function (msg, title) {
          (kind === "error" ? console.error : console.log)("[toastr." + kind + "] " + (title ? title + "：" : "") + String(msg));
          return {};
        };
      }
      var toastr = { info: toast("info"), success: toast("success"), warning: toast("warning"), error: toast("error"),
                     clear: function () {}, remove: function () {}, options: {} };
      function errorCatched(fn) {
        function onError(e) {
          toastr.error(e && e.stack ? e.stack : String(e && e.message || e), "[" + getIframeName() + "] " + (e && e.name || "Error"));
          throw e;
        }
        return function () {
          try {
            var r = fn.apply(this, arguments);
            if (r && typeof r.then === "function") return r.then(undefined, function (e) { onError(e); });
            return r;
          } catch (e) { return onError(e); }
        };
      }
      function substitudeMacros(text) { return H.substitute(text, S); }
      function reloadIframe() { window.location.reload(); }
      function MemStorage() {
        var d = Object.create(null), used = 0;
        var s = {
          getItem: function (k) { k = String(k); return k in d ? d[k] : null; },
          setItem: function (k, v) {
            k = String(k); v = String(v);
            var next = used - (k in d ? k.length + d[k].length : 0) + k.length + v.length;
            if (next > 5000000) throw new Error("QuotaExceededError");
            d[k] = v; used = next;
          },
          removeItem: function (k) { k = String(k); if (k in d) { used -= k.length + d[k].length; delete d[k]; } },
          clear: function () { d = Object.create(null); used = 0; },
          key: function (i) { var ks = Object.keys(d); return i >= 0 && i < ks.length ? ks[i] : null; }
        };
        Object.defineProperty(s, "length", { get: function () { return Object.keys(d).length; } });
        return s;
      }
      ["localStorage", "sessionStorage"].forEach(function (k) {
        try { Object.defineProperty(window, k, { value: MemStorage(), configurable: true, enumerable: true }); } catch (_) {}
      });

      var tavern_events = {
        APP_READY: "app_ready", EXTRAS_CONNECTED: "extras_connected", MESSAGE_SWIPED: "message_swiped", MESSAGE_SENT: "message_sent",
        MESSAGE_RECEIVED: "message_received", MESSAGE_EDITED: "message_edited", MESSAGE_DELETED: "message_deleted",
        MESSAGE_UPDATED: "message_updated", MESSAGE_FILE_EMBEDDED: "message_file_embedded",
        MESSAGE_REASONING_EDITED: "message_reasoning_edited", MESSAGE_REASONING_DELETED: "message_reasoning_deleted",
        MESSAGE_SWIPE_DELETED: "message_swipe_deleted", MORE_MESSAGES_LOADED: "more_messages_loaded",
        IMPERSONATE_READY: "impersonate_ready", CHAT_CHANGED: "chat_id_changed", GENERATION_AFTER_COMMANDS: "GENERATION_AFTER_COMMANDS",
        GENERATION_STARTED: "generation_started", GENERATION_STOPPED: "generation_stopped", GENERATION_ENDED: "generation_ended",
        SD_PROMPT_PROCESSING: "sd_prompt_processing", EXTENSIONS_FIRST_LOAD: "extensions_first_load",
        EXTENSION_SETTINGS_LOADED: "extension_settings_loaded", SETTINGS_LOADED: "settings_loaded", SETTINGS_UPDATED: "settings_updated",
        MOVABLE_PANELS_RESET: "movable_panels_reset", SETTINGS_LOADED_BEFORE: "settings_loaded_before",
        SETTINGS_LOADED_AFTER: "settings_loaded_after", CHATCOMPLETION_SOURCE_CHANGED: "chatcompletion_source_changed",
        CHATCOMPLETION_MODEL_CHANGED: "chatcompletion_model_changed", OAI_PRESET_CHANGED_BEFORE: "oai_preset_changed_before",
        OAI_PRESET_CHANGED_AFTER: "oai_preset_changed_after", OAI_PRESET_EXPORT_READY: "oai_preset_export_ready",
        OAI_PRESET_IMPORT_READY: "oai_preset_import_ready", WORLDINFO_SETTINGS_UPDATED: "worldinfo_settings_updated",
        WORLDINFO_UPDATED: "worldinfo_updated", CHARACTER_EDITOR_OPENED: "character_editor_opened", CHARACTER_EDITED: "character_edited",
        CHARACTER_PAGE_LOADED: "character_page_loaded", USER_MESSAGE_RENDERED: "user_message_rendered",
        CHARACTER_MESSAGE_RENDERED: "character_message_rendered", FORCE_SET_BACKGROUND: "force_set_background",
        CHAT_DELETED: "chat_deleted", CHAT_CREATED: "chat_created", GENERATE_BEFORE_COMBINE_PROMPTS: "generate_before_combine_prompts",
        GENERATE_AFTER_COMBINE_PROMPTS: "generate_after_combine_prompts", GENERATE_AFTER_DATA: "generate_after_data",
        WORLD_INFO_ACTIVATED: "world_info_activated", TEXT_COMPLETION_SETTINGS_READY: "text_completion_settings_ready",
        CHAT_COMPLETION_SETTINGS_READY: "chat_completion_settings_ready", CHAT_COMPLETION_PROMPT_READY: "chat_completion_prompt_ready",
        CHARACTER_FIRST_MESSAGE_SELECTED: "character_first_message_selected", CHARACTER_DELETED: "characterDeleted",
        CHARACTER_DUPLICATED: "character_duplicated", CHARACTER_RENAMED: "character_renamed",
        CHARACTER_RENAMED_IN_PAST_CHAT: "character_renamed_in_past_chat", SMOOTH_STREAM_TOKEN_RECEIVED: "stream_token_received",
        STREAM_TOKEN_RECEIVED: "stream_token_received", STREAM_REASONING_DONE: "stream_reasoning_done",
        FILE_ATTACHMENT_DELETED: "file_attachment_deleted", WORLDINFO_FORCE_ACTIVATE: "worldinfo_force_activate",
        OPEN_CHARACTER_LIBRARY: "open_character_library", ONLINE_STATUS_CHANGED: "online_status_changed", IMAGE_SWIPED: "image_swiped",
        CONNECTION_PROFILE_LOADED: "connection_profile_loaded", CONNECTION_PROFILE_CREATED: "connection_profile_created",
        CONNECTION_PROFILE_DELETED: "connection_profile_deleted", CONNECTION_PROFILE_UPDATED: "connection_profile_updated",
        TOOL_CALLS_PERFORMED: "tool_calls_performed", TOOL_CALLS_RENDERED: "tool_calls_rendered",
        CHARACTER_MANAGEMENT_DROPDOWN: "charManagementDropdown", SECRET_WRITTEN: "secret_written", SECRET_DELETED: "secret_deleted",
        SECRET_ROTATED: "secret_rotated", SECRET_EDITED: "secret_edited", PRESET_CHANGED: "preset_changed",
        PRESET_DELETED: "preset_deleted", PRESET_RENAMED: "preset_renamed", PRESET_RENAMED_BEFORE: "preset_renamed_before",
        MAIN_API_CHANGED: "main_api_changed", WORLDINFO_ENTRIES_LOADED: "worldinfo_entries_loaded",
        WORLDINFO_SCAN_DONE: "worldinfo_scan_done", MEDIA_ATTACHMENT_DELETED: "media_attachment_deleted"
      };
      var iframe_events = {
        MESSAGE_IFRAME_RENDER_STARTED: "message_iframe_render_started", MESSAGE_IFRAME_RENDER_ENDED: "message_iframe_render_ended",
        GENERATION_REQUESTED: "js_generation_requested", GENERATION_STARTED: "js_generation_started",
        STREAM_TOKEN_RECEIVED_FULLY: "js_stream_token_received_fully",
        STREAM_TOKEN_RECEIVED_INCREMENTALLY: "js_stream_token_received_incrementally",
        REASONING_TOKEN_RECEIVED_FULLY: "js_reasoning_token_received_fully",
        REASONING_TOKEN_RECEIVED_INCREMENTALLY: "js_reasoning_token_received_incrementally",
        GENERATION_ENDED: "js_generation_ended"
      };

      var supported = {
        getChatMessages: getChatMessages, setChatMessages: setChatMessages, setChatMessage: setChatMessage,
        getLastMessageId: getLastMessageId, getCurrentMessageId: getCurrentMessageId, getMessageId: getMessageId,
        getIframeName: getIframeName, getVariables: getVariables, getAllVariables: getAllVariables,
        replaceVariables: replaceVariables, updateVariablesWith: updateVariablesWith,
        insertOrAssignVariables: insertOrAssignVariables, insertVariables: insertVariables, deleteVariable: deleteVariable,
        eventOn: eventOn, eventOnce: eventOnce, eventMakeFirst: eventMakeFirst, eventMakeLast: eventMakeLast,
        eventEmit: eventEmit, eventEmitAndWait: eventEmitAndWait, eventRemoveListener: eventRemoveListener,
        eventClearEvent: eventClearEvent, eventClearListener: eventClearListener, eventClearAll: eventClearAll,
        errorCatched: errorCatched, substitudeMacros: substitudeMacros, reloadIframe: reloadIframe,
        triggerSlash: triggerSlash, triggerSlashWithResult: triggerSlash
      };
      var unsupportedNames = ("audioEnable audioImport audioMode audioPlay audioSelect playAudio pauseAudio getAudioList replaceAudioList " +
        "appendAudioList getAudioSettings setAudioSettings getCurrentAudio getCharacterNames getCharacterIds getCurrentCharacterName " +
        "getCurrentCharacterId createCharacter createOrReplaceCharacter deleteCharacter getCharacter replaceCharacter updateCharacterWith " +
        "createChatMessages deleteChatMessages rotateChatMessages formatAsDisplayedMessage retrieveDisplayedMessage refreshOneMessage " +
        "isAdmin getTavernHelperExtensionId getExtensionType getExtensionStatus isInstalledExtension installExtension uninstallExtension " +
        "reinstallExtension updateExtension importRawCharacter importRawPreset importRawChat importRawWorldbook importRawTavernRegex " +
        "injectPrompts uninjectPrompts getModelList getProxyPresetNames generate generateRaw stopGenerationById stopAllGeneration " +
        "initializeGlobal waitGlobalInitialized getLorebookEntries replaceLorebookEntries updateLorebookEntriesWith setLorebookEntries " +
        "createLorebookEntries createLorebookEntry deleteLorebookEntries deleteLorebookEntry getLorebookSettings setLorebookSettings " +
        "getCharLorebooks setCurrentCharLorebooks getLorebooks deleteLorebook createLorebook getCurrentCharPrimaryLorebook " +
        "getChatLorebook setChatLorebook getOrCreateChatLorebook isPresetNormalPrompt isPresetSystemPrompt isPresetPlaceholderPrompt " +
        "getPresetNames getLoadedPresetName loadPreset createPreset createOrReplacePreset deletePreset renamePreset getPreset " +
        "replacePreset updatePresetWith setPreset getPersonaNames getPersonaIds getCurrentPersonaName getCurrentPersonaId " +
        "getPersonaAvatarPath createPersona createOrReplacePersona deletePersona getPersona replacePersona updatePersonaWith " +
        "RawCharacter getCharData getCharAvatarPath getChatHistoryBrief getChatHistoryDetail registerMacroLike unregisterMacroLike " +
        "getAllEnabledScriptButtons getScriptTrees replaceScriptTrees updateScriptTreesWith " +
        "formatAsTavernRegexedString isCharacterTavernRegexesEnabled getTavernRegexes replaceTavernRegexes updateTavernRegexesWith " +
        "registerVariableSchema getTavernHelperVersion getFrontendVersion updateTavernHelper updateFrontendVersion getTavernVersion " +
        "getWorldbookNames getGlobalWorldbookNames rebindGlobalWorldbooks getCharWorldbookNames rebindCharWorldbooks " +
        "getChatWorldbookName rebindChatWorldbook getOrCreateChatWorldbook createWorldbook createOrReplaceWorldbook deleteWorldbook " +
        "getWorldbook replaceWorldbook updateWorldbookWith createWorldbookEntries deleteWorldbookEntries " +
        "eventOnButton getButtonEvent getScriptButtons replaceScriptButtons updateScriptButtonsWith appendInexistentScriptButtons " +
        "getScriptName getScriptInfo replaceScriptInfo getScriptId").split(" ");
      function unsupportedFn(name) { return function () { throw unsupported(name); }; }
      function unsupportedObject(name) {
        return new Proxy(function () {}, {
          get: function (_, k) {
            if (typeof k === "symbol" || k === "then" || k === "toJSON") return undefined;
            throw unsupported(name + "." + String(k));
          },
          apply: function () { throw unsupported(name); },
          construct: function () { throw unsupported(name); }
        });
      }

      var TH = { tavern_events: tavern_events, iframe_events: iframe_events, _bind: {} };
      Object.keys(supported).forEach(function (k) { TH[k] = supported[k]; TH._bind["_" + k] = supported[k]; window[k] = supported[k]; });
      unsupportedNames.forEach(function (k) { var f = unsupportedFn(k); TH[k] = f; window[k] = f; });
      ["builtin", "default_preset", "builtin_prompt_default_order"].forEach(function (k) { TH[k] = unsupportedObject(k); window[k] = TH[k]; });
      window.TavernHelper = TH;
      window.tavern_events = tavern_events;
      window.iframe_events = iframe_events;
      window.toastr = toastr;
      ["SillyTavern", "EjsTemplate", "YAML", "showdown", "z"].forEach(function (k) {
        if (window[k] === undefined) window[k] = unsupportedObject(k);
      });
      window.addEventListener("pagehide", function () { eventClearAll(); });

      /* ---- B8：卡里常见的「往酒馆输入框塞字 / 点发送」DOM 写法（window.parent.document 里的 #send_textarea / #send_but）。
         父页跨源本来就碰不到；换成只认这两个元素的假 parent：填字 + input 事件走 /setinput，点发送走 /send…|/trigger
         （同一条原生许可链：第一次确认 / 3 秒 / 生成中）。假 parent 别的属性一律 undefined，postMessage 照转真父页 ---- */
      var draft = "";
      function slashText(t) { return String(t).replace(/\|/g, "\\|"); }
      function noop() {}
      var sendTextarea = { tagName: "TEXTAREA", id: "send_textarea", focus: noop, blur: noop, addEventListener: noop, removeEventListener: noop,
        get value() { return draft; }, set value(v) { draft = v == null ? "" : String(v); },
        dispatchEvent: function () { triggerSlash("/setinput " + slashText(draft)).catch(noop); return true; } };
      var sendButton = { tagName: "DIV", id: "send_but", addEventListener: noop, removeEventListener: noop,
        click: function () { var t = draft; draft = ""; if (t.trim()) triggerSlash("/send " + slashText(t) + "|/trigger").catch(noop); },
        dispatchEvent: function (e) { if (e && e.type === "click") sendButton.click(); return true; } };
      function hostElement(sel) {
        sel = String(sel).trim().replace(/^(textarea|div)(?=#)/i, "");
        return sel === "#send_textarea" ? sendTextarea : sel === "#send_but" ? sendButton : null;
      }
      var hostDocument = { querySelector: hostElement, getElementById: function (id) { return hostElement("#" + id); } };
      var fakeParent = new Proxy({}, { get: function (_, k) {
        if (k === "document") return hostDocument;
        if (k === "postMessage") return function () { return P.postMessage.apply(P, arguments); };
        return undefined;
      } });
      try { Object.defineProperty(window, "parent", { configurable: true, get: function () { return fakeParent; } }); } catch (_) {}
    })();
    """#
}
