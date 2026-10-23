// Mermaid 渲染宿主脚本（mermaid.html 用，plan-mermaid §2）。
// 渲染模式：window.mpRender(code, opts) -> {svg, width, height, displayWidth, displayHeight, type} / {error}
// 查看模式（#view）：window.mpShow(svg, background)
(function () {
  'use strict';

  var viewMode = location.hash === '#view';
  var loading = null;
  var seq = 0;

  // 经典脚本（非 module）动态插入：file:// 下不走 CORS。查看模式不载这 5.5MB
  function loadMermaid() {
    if (loading) return loading;
    loading = new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = 'mermaid.min.js';
      s.onload = function () {
        if (window.mermaid) resolve(window.mermaid);
        else reject(new Error('mermaid 未加载'));
      };
      s.onerror = function () { reject(new Error('mermaid.min.js 加载失败')); };
      document.head.appendChild(s);
    });
    return loading;
  }
  if (!viewMode) loadMermaid();

  function stage() { return document.getElementById('stage'); }

  // mermaid 出错时会在 body 上留临时节点（d<id> 容器 / i<id> iframe），清掉免得越积越多
  function cleanup(id) {
    ['d' + id, 'i' + id].forEach(function (x) {
      var el = document.getElementById(x);
      if (el && el.parentNode) el.parentNode.removeChild(el);
    });
  }

  function errorText(e) {
    if (!e) return '未知错误';
    if (typeof e === 'string') return e;
    return String(e.message || e.str || e);
  }

  // ---- 甘特图刻度：mermaid 默认按天出刻度，跨度一长底部日期全挤在一起 ----
  // 从代码粗估时间跨度（dateFormat + 各任务起止 / after 链），按跨度给 tickInterval + axisFormat。
  // 用户自己写了 tickInterval / axisFormat 的不覆盖；估不出就不管。
  var DAY = 86400000;
  var DURATION_MS = { ms: 1, s: 1000, m: 60000, h: 3600000, d: DAY, w: 7 * DAY, M: 30 * DAY, y: 365 * DAY };
  var GANTT_KEYWORDS = /^(?:(?:title|dateformat|axisformat|tickinterval|excludes|includes|todaymarker|section|weekday|weekend|inclusiveenddates|topaxis|displaymode|acctitle|accdescr|click)(?:\s|:|\{|$)|%%)/i;
  var GANTT_TAGS = { active: 1, done: 1, crit: 1, milestone: 1, vert: 1 };

  function ganttConfig(code, layoutWidth) {
    var conf = { useWidth: layoutWidth };
    var ticks = ganttTicks(code);
    if (ticks) {
      conf.tickInterval = ticks.tickInterval;
      conf.axisFormat = ticks.axisFormat;
    }
    return conf;
  }

  function ganttTicks(code) {
    var lines = String(code || '').split(/\r?\n/).map(function (l) { return l.trim(); });
    var first = lines.filter(function (l) { return l && l.indexOf('%%') !== 0; })[0] || '';
    if (!/^gantt\b/i.test(first)) return null;
    if (lines.some(function (l) { return /^(tickInterval|axisFormat)\b/i.test(l); })) return null;
    var days = ganttSpanDays(lines);
    if (days === null || !(days > 0)) return null;
    if (days <= 14) return { tickInterval: '1day', axisFormat: '%m-%d' };
    if (days <= 92) return { tickInterval: '1week', axisFormat: '%m-%d' };
    if (days <= 731) return { tickInterval: '1month', axisFormat: '%Y-%m' };
    return { tickInterval: '3month', axisFormat: '%Y-%m' };
  }

  // dayjs 风格格式串 → 正则（只认常见记号；认不出返回 null，交给 Date.parse 兜底）
  function dateParser(format) {
    var order = [];
    var re = '';
    var i = 0;
    var tokens = ['YYYY', 'YY', 'MM', 'M', 'DD', 'D', 'HH', 'H', 'mm', 'ss', 'SSS'];
    while (i < format.length) {
      var hit = null;
      for (var t = 0; t < tokens.length; t++) {
        if (format.substr(i, tokens[t].length) === tokens[t]) { hit = tokens[t]; break; }
      }
      if (hit) {
        order.push(hit);
        re += hit === 'YYYY' ? '(\\d{4})' : hit === 'SSS' ? '(\\d{1,3})' : '(\\d{1,2})';
        i += hit.length;
      } else {
        re += format[i].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        i += 1;
      }
    }
    if (order.indexOf('YYYY') < 0 && order.indexOf('YY') < 0) return null;
    var matcher = new RegExp('^' + re + '$');
    return function (text) {
      var m = matcher.exec(text);
      if (!m) return null;
      var p = { YYYY: 1970, M: 1, D: 1, H: 0, mm: 0, ss: 0, SSS: 0 };
      order.forEach(function (tok, k) {
        var v = parseInt(m[k + 1], 10);
        if (tok === 'YYYY') p.YYYY = v;
        else if (tok === 'YY') p.YYYY = 2000 + v;
        else if (tok === 'MM' || tok === 'M') p.M = v;
        else if (tok === 'DD' || tok === 'D') p.D = v;
        else if (tok === 'HH' || tok === 'H') p.H = v;
        else p[tok] = v;
      });
      return Date.UTC(p.YYYY, p.M - 1, p.D, p.H, p.mm, p.ss, p.SSS);
    };
  }

  function ganttSpanDays(lines) {
    var format = 'YYYY-MM-DD';
    lines.forEach(function (l) {
      var m = /^dateFormat\s+(.+)$/i.exec(l);
      if (m) format = m[1].trim();
    });
    var parseWithFormat = dateParser(format);
    function parseDate(text) {
      var v = parseWithFormat ? parseWithFormat(text) : null;
      if (v === null) {
        var d = Date.parse(text);
        v = isNaN(d) ? null : d;
      }
      return v;
    }
    function parseDuration(text) {
      var m = /^(\d+(?:\.\d+)?)(ms|[smhdwMy])$/.exec(text);
      return m ? parseFloat(m[1]) * DURATION_MS[m[2]] : null;
    }

    var ends = {}, starts = {};
    var lastEnd = null, minStart = null, maxEnd = null, autoId = 0;
    lines.forEach(function (line) {
      if (!line || GANTT_KEYWORDS.test(line) || /^gantt\b/i.test(line)) return;
      var colon = line.indexOf(':');
      if (colon < 0) return;
      var parts = line.slice(colon + 1).split(',').map(function (x) { return x.trim(); })
        .filter(function (x) { return x && !GANTT_TAGS[x.toLowerCase()]; });
      if (!parts.length) return;
      var id = 'auto' + (++autoId), startText = null, endText;
      if (parts.length === 1) { endText = parts[0]; }
      else if (parts.length === 2) { startText = parts[0]; endText = parts[1]; }
      else { id = parts[0]; startText = parts[1]; endText = parts[2]; }

      var start = null;
      if (startText === null) start = lastEnd;
      else if (/^after\s+/i.test(startText)) {
        startText.replace(/^after\s+/i, '').split(/\s+/).forEach(function (ref) {
          if (ends[ref] !== undefined && (start === null || ends[ref] > start)) start = ends[ref];
        });
      } else start = parseDate(startText);
      if (start === null) return;

      var end = null;
      var dur = parseDuration(endText);
      if (dur !== null) end = start + dur;
      else if (/^until\s+/i.test(endText)) {
        var ref = endText.replace(/^until\s+/i, '').split(/\s+/)[0];
        end = starts[ref] !== undefined ? starts[ref] : null;
      } else end = parseDate(endText);
      if (end === null) end = start;

      starts[id] = start;
      ends[id] = end;
      lastEnd = end;
      if (minStart === null || start < minStart) minStart = start;
      if (maxEnd === null || end > maxEnd) maxEnd = end;
    });
    if (minStart === null || maxEnd === null) return null;
    return (maxEnd - minStart) / DAY;
  }

  // 预热 / 探活：mermaid 已加载即返回 true
  window.mpReady = function () {
    return loadMermaid().then(function () { return true; });
  };

  window.mpRender = async function (code, opts) {
    opts = opts || {};
    var mermaid;
    try {
      mermaid = await loadMermaid();
    } catch (e) {
      return { error: errorText(e), fatal: true };
    }
    var box = stage();
    box.innerHTML = '';
    // 甘特图 / 旅程图等按父容器宽排版：渲染时给舞台一个固定排版宽，量完再放开
    var layoutWidth = opts.layoutWidth || 720;
    box.style.display = 'block';
    box.style.width = layoutWidth + 'px';
    document.body.style.background = opts.background || 'transparent';
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: 'base',
      themeVariables: opts.themeVariables || {},
      fontFamily: opts.fontFamily || undefined,
      htmlLabels: false,
      flowchart: { htmlLabels: false },
      class: { htmlLabels: false },
      gantt: ganttConfig(code, layoutWidth),
      maxTextSize: 50000,
      deterministicIds: true
    });
    var id = 'mpm' + (++seq);
    var result;
    try {
      result = await mermaid.render(id, code);
    } catch (e) {
      cleanup(id);
      box.innerHTML = '';
      box.style.display = '';
      box.style.width = '';
      return { error: errorText(e) };
    }
    cleanup(id);
    box.innerHTML = result.svg;
    var svg = box.querySelector('svg');
    if (!svg) return { error: '没有生成图' };

    var w = 0, h = 0;
    var vb = svg.viewBox && svg.viewBox.baseVal;
    if (vb && vb.width > 0 && vb.height > 0) { w = vb.width; h = vb.height; }
    else { var r = svg.getBoundingClientRect(); w = r.width; h = r.height; }
    if (!(w > 0 && h > 0)) return { error: '图的尺寸为 0' };

    var type = svg.getAttribute('aria-roledescription') || '';
    box.style.display = '';
    box.style.width = '';

    // 存盘版：去掉定死像素，全屏按容器宽等比缩放
    var copy = svg.cloneNode(true);
    copy.removeAttribute('width');
    copy.removeAttribute('height');
    copy.style.maxWidth = '';
    var svgText = new XMLSerializer().serializeToString(copy);

    // 截图版：按自然尺寸摆（超宽等比缩到 maxWidth，超高只截上面 maxHeight）
    var maxW = opts.maxWidth || 1600, maxH = opts.maxHeight || 4000;
    var scale = Math.min(1, maxW / w);
    var dw = Math.max(1, Math.ceil(w * scale)), dh = Math.max(1, Math.ceil(h * scale));
    svg.setAttribute('width', String(dw));
    svg.setAttribute('height', String(dh));
    svg.style.maxWidth = 'none';

    return {
      svg: svgText,
      width: w,
      height: h,
      displayWidth: dw,
      displayHeight: Math.min(dh, maxH),
      type: type
    };
  };

  // 截图前等两帧，确保按新尺寸排好版（离屏被遮住时 rAF 可能不跑，120ms 兜底）
  window.mpSettle = function () {
    return new Promise(function (resolve) {
      var done = false;
      function finish() { if (!done) { done = true; resolve(true); } }
      requestAnimationFrame(function () { requestAnimationFrame(finish); });
      setTimeout(finish, 120);
    });
  };

  // 每张图之间清掉上一张的 DOM
  window.mpClear = function () {
    var box = stage();
    if (box) box.innerHTML = '';
    return true;
  };

  window.mpShow = function (svgText, background) {
    document.body.classList.add('view');
    document.body.style.background = background || 'transparent';
    stage().innerHTML = svgText;
    return true;
  };
})();
