/* 记忆花园 · 聊天（css自定义）runtime
   职责：键盘避让 / DOM 渲染 / 与 Swift 的双向桥。
   ⚠️ 皮肤包不许带 JS——这个文件是 app 自带的，皮肤只能改 CSS。 */
(function () {
  'use strict';

  var PROTO_V = 1;

  var el = {
    chat:     document.querySelector('.mp-chat'),
    messages: document.getElementById('mp-messages'),
    toBottom: document.getElementById('mp-to-bottom'),
    chips:    document.getElementById('mp-chips'),
    field:    document.getElementById('mp-field'),
    send:     document.getElementById('mp-send'),
    attach:   document.getElementById('mp-attach'),
    skin:     document.getElementById('mp-skin'),
    base:     document.getElementById('mp-base'),
    tpl:      document.getElementById('mp-msg-template')
  };

  /* ---------------- 与 Swift 的桥 ---------------- */
  function post(type, payload) {
    var msg = payload || {};
    msg.type = type; msg.v = PROTO_V;
    try { window.webkit.messageHandlers.mpChat.postMessage(msg); } catch (e) {}
  }

  /* ---------------- 键盘避让 ----------------
     P0 实测结论（iOS 26.4）：键盘弹起时 visualViewport.height 和 window.innerHeight
     **都会**缩（804→576），offsetTop 变 228（WebKit 滚了页面）。
     ⚠️ 不许基于「innerHeight 不变」推理——那条社区共识在 iOS 26 上是错的。
     配方：top = vv.offsetTop（补偿 WebKit 的滚动），height = vv.height。不用 transform。 */
  var vv = window.visualViewport;

  // 没键盘时的最大高度。键盘起来后输入栏贴着键盘，不该再让 home indicator 的安全区（.kb 去掉那截）
  var fullHeight = 0;

  function relayout() {
    if (!vv) return;
    var stick = isNearBottom();
    fullHeight = Math.max(fullHeight, vv.height);
    el.chat.classList.toggle('kb', vv.height < fullHeight - 120);
    el.chat.style.top = vv.offsetTop + 'px';
    el.chat.style.height = vv.height + 'px';
    if (stick) scrollToBottom();
  }

  if (vv) {
    vv.addEventListener('resize', relayout);
    vv.addEventListener('scroll', relayout);
  }
  window.addEventListener('orientationchange', function () { fullHeight = 0; setTimeout(relayout, 250); });
  // 收键盘后 visualViewport 偶发不还原（iOS 26 有报告，P0 没复现）——blur 后补两拍兜底
  el.field.addEventListener('blur', function () {
    setTimeout(relayout, 60);
    setTimeout(relayout, 350);
  });

  /* ---------------- 滚动 ---------------- */
  var NEAR_BOTTOM = 60;
  function isNearBottom() {
    var m = el.messages;
    return m.scrollHeight - m.scrollTop - m.clientHeight < NEAR_BOTTOM;
  }
  function scrollToBottom() { el.messages.scrollTop = el.messages.scrollHeight; }

  el.messages.addEventListener('scroll', function () {
    var atBottom = isNearBottom();
    el.toBottom.hidden = atBottom;
    post('scrolled', { atBottom: atBottom });
  }, { passive: true });

  el.toBottom.addEventListener('click', scrollToBottom);

  // P0 挖出：点消息区要收键盘（原生聊天就是这行为）。点在正文里不收——那是要选字。
  el.messages.addEventListener('click', function (ev) {
    if (ev.target.closest('.mp-body, .mp-more, .mp-branches, .mp-attachments, .mp-thinking')) return;
    if (document.activeElement === el.field) el.field.blur();
  });

  /* ---------------- 渲染 ---------------- */
  var nodeIndex = Object.create(null);   // nodeId -> <article>

  function buildMessage(dto) {
    var frag = el.tpl.content.cloneNode(true);
    var art = frag.querySelector('.mp-msg');
    applyMessage(art, dto);
    return art;
  }

  function applyMessage(art, dto) {
    art.dataset.nodeId   = dto.id;
    art.dataset.role     = dto.role || 'assistant';
    art.dataset.streaming = dto.streaming ? '1' : '0';
    art.dataset.favorite = dto.isFavorite ? '1' : '0';
    art.dataset.pinned   = dto.isPinned ? '1' : '0';
    if (dto.kind) art.dataset.kind = dto.kind;   // heartvoice 等，v1 只标记不特殊渲染

    var avatar = art.querySelector('.mp-avatar');
    if (dto.avatarURL) avatar.src = dto.avatarURL; else avatar.removeAttribute('src');

    art.querySelector('.mp-name').textContent = dto.name || '';
    art.querySelector('.mp-time').textContent = dto.time || '';

    var quote = art.querySelector('.mp-quote');
    quote.hidden = !dto.quoted;
    if (dto.quoted) quote.textContent = dto.quoted;

    var think = art.querySelector('.mp-thinking');
    think.hidden = !dto.thinking;
    if (dto.thinking) art.querySelector('.mp-thinking-body').textContent = dto.thinking;

    renderAttachments(art.querySelector('.mp-attachments'), dto.attachments);

    // P1：纯文本。P2 接 Markdown 后这里换成 innerHTML = 渲染结果。
    // ⑦：带 HTML 段的消息按段 keyed 渲染（文本段仍是 textContent），正文没变的 iframe 不重建
    var body = art.querySelector('.mp-body');
    if (dto.segments && dto.segments.length) {
      renderSegments(body, dto);
    } else {
      if (body.dataset.segmented) { destroySegments(body); delete body.dataset.segmented; }
      if (body.textContent !== (dto.text || '')) body.textContent = dto.text || '';
    }

    var nav = art.querySelector('.mp-branches');
    var branched = !!(dto.branch && dto.branch.total > 1);
    if (branched) {
      nav.querySelector('.mp-branch-count').textContent = (dto.branch.index + 1) + '/' + dto.branch.total;
    }
    // 卡库第二批：被卡里的网页改过 → 分支行后「edited」（没分支时这一行只放它）
    ['.mp-branch-prev', '.mp-branch-count', '.mp-branch-next'].forEach(function (s) { nav.querySelector(s).hidden = !branched; });
    renderEdited(nav, dto.edited);
    nav.hidden = !branched && !dto.edited;
  }

  var PEN = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13.5 6.5l4 4"/></svg>';
  function renderEdited(nav, info) {
    var btn = nav.querySelector('.mp-edited'), pop = nav.querySelector('.mp-edited-pop');
    if (!info) { if (btn) btn.remove(); if (pop) pop.remove(); return; }
    if (!btn) {
      btn = document.createElement('button'); btn.type = 'button'; btn.className = 'mp-edited';
      btn.setAttribute('aria-label', '网页改过，点开看说明');
      btn.innerHTML = PEN; btn.appendChild(document.createTextNode('edited'));
      pop = document.createElement('div'); pop.className = 'mp-edited-pop'; pop.hidden = true; pop.setAttribute('role', 'note');
      pop.appendChild(document.createElement('b')); pop.appendChild(document.createElement('p'));
      nav.appendChild(btn); nav.appendChild(pop);
    }
    pop.querySelector('b').textContent = info.title || '';
    pop.querySelector('p').textContent = info.note || '';
  }

  function renderAttachments(box, list) {
    box.textContent = '';
    if (!list || !list.length) { box.hidden = true; return; }
    box.hidden = false;
    list.forEach(function (a) {
      var fig = document.createElement('figure');
      fig.className = 'mp-att';
      fig.dataset.type = a.kind === 'image' ? 'image' : 'file';
      if (a.kind === 'image' && a.url) {   // 没 url 就退化成文件名，不显示破图
        var img = document.createElement('img');
        img.src = a.url; img.alt = a.name || '';
        fig.appendChild(img);
      } else {
        var span = document.createElement('span');
        span.className = 'mp-att-name';
        span.textContent = a.name || '文件';
        fig.appendChild(span);
      }
      box.appendChild(fig);
    });
  }

  /* ---------------- HTML 段（卡库 ⑦） ----------------
     一段 HTML = 一个 iframe，文档由原生 mp-card:// 发（带独立 CSP），这里只管挂 / 摘：
     - 静态 / 交互都是 sandbox="allow-scripts"（静态靠子文档 CSP nonce 只放原生量高度脚本），永不 allow-same-origin
     - 每个宿主最多 MAX_STATIC 个可见静态实例，超额保高度占位；交互全应用一个，由原生调度
     - 离屏（IntersectionObserver）即销毁并通知原生注销 token；交互不自动恢复
     - 子文档只能 postMessage ready / error / openLink，按来源 window + token 校验后转原生
     - 第二批 B3：交互实例另有 call（助手 API，原生校验链）；两种模式都有 resize（自动高度，原生夹 120–2000）
       / cspReport；原生的 result / event / snapshotUpdate 经 htmlDeliver 只投给 token 对得上的那个 iframe */
  var MAX_STATIC = 2, FRAME_H = 360, FRAME_H_EXPANDED = 720;
  var htmlRecs = Object.create(null);   // nodeId|segId -> rec

  var htmlObserver = ('IntersectionObserver' in window) ? new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      var rec = en.target.__mpRec;
      if (!rec) return;
      rec.visible = en.isIntersecting;
      if (!rec.visible && (rec.iframe || rec.pending)) unmountFrame(rec, true);
    });
    scheduleStatic();
  }, { root: el.messages, rootMargin: '0px', threshold: 0 }) : null;

  function recKey(nodeId, segId) { return nodeId + '|' + segId; }

  function renderSegments(body, dto) {
    if (!body.dataset.segmented) { body.textContent = ''; body.dataset.segmented = '1'; }
    var want = Object.create(null);
    dto.segments.forEach(function (seg) { want[seg.id] = seg; });
    // 先删（没了的段 / 类型或内容变了的 HTML 段），再按序补：保证留下的节点不被挪动
    Array.prototype.slice.call(body.children).forEach(function (child) {
      var seg = want[child.dataset.segId];
      if (!seg || child.dataset.segKind !== seg.kind || (seg.kind === 'html' && child.dataset.key !== seg.key)) {
        destroySegment(child); child.remove();
      }
    });
    var cursor = body.firstElementChild;
    dto.segments.forEach(function (seg) {
      var node = null;
      Array.prototype.some.call(body.children, function (c) {
        if (c.dataset.segId === seg.id) { node = c; return true; }
        return false;
      });
      if (!node) node = seg.kind === 'html' ? buildHTMLSegment(dto.id, seg) : buildTextSegment(seg);
      else if (seg.kind === 'text') { if (node.textContent !== (seg.text || '')) node.textContent = seg.text || ''; }
      else node.querySelector('.mp-html-title').textContent = seg.title || '网页';
      // 位置对就不动：挪动带 iframe 的节点会让它重新加载
      if (node === cursor) cursor = cursor.nextElementSibling;
      else body.insertBefore(node, cursor);
    });
    scheduleStatic();
  }

  function buildTextSegment(seg) {
    var d = document.createElement('div');
    d.className = 'mp-seg-text';
    d.dataset.segId = seg.id; d.dataset.segKind = 'text';
    d.textContent = seg.text || '';
    return d;
  }

  function buildHTMLSegment(nodeId, seg) {
    var box = document.createElement('div');
    box.className = 'mp-html';
    box.dataset.segId = seg.id; box.dataset.segKind = 'html'; box.dataset.key = seg.key || '';
    box.dataset.mode = 'static';
    var bar = document.createElement('div'); bar.className = 'mp-html-bar';
    var title = document.createElement('span'); title.className = 'mp-html-title'; title.textContent = seg.title || '网页';
    var expand = document.createElement('button'); expand.type = 'button'; expand.className = 'mp-html-expand'; expand.textContent = '展开';
    var run = document.createElement('button'); run.type = 'button'; run.className = 'mp-html-run'; run.textContent = '运行';
    bar.appendChild(title); bar.appendChild(expand); bar.appendChild(run);
    var note = document.createElement('div'); note.className = 'mp-html-note'; note.hidden = true;
    var frame = document.createElement('div'); frame.className = 'mp-html-frame';
    frame.style.height = FRAME_H + 'px';
    var ph = document.createElement('div'); ph.className = 'mp-html-placeholder'; ph.textContent = '滚到这里显示';
    frame.appendChild(ph);
    box.appendChild(bar); box.appendChild(note); box.appendChild(frame);
    var rec = { nodeId: nodeId, segId: seg.id, box: box, frame: frame, placeholder: ph, run: run, note: note,
                iframe: null, token: null, mode: 'static', pending: false, visible: false };
    box.__mpRec = rec;
    htmlRecs[recKey(nodeId, seg.id)] = rec;
    if (htmlObserver) htmlObserver.observe(box);
    return box;
  }

  function destroySegment(node) {
    var rec = node.__mpRec;
    if (!rec) return;
    if (htmlObserver) htmlObserver.unobserve(node);
    unmountFrame(rec, true);
    if (htmlRecs[recKey(rec.nodeId, rec.segId)] === rec) delete htmlRecs[recKey(rec.nodeId, rec.segId)];
    node.__mpRec = null;
  }

  function destroySegments(root) {
    Array.prototype.forEach.call(root.querySelectorAll('.mp-html'), destroySegment);
  }

  /** 摘 iframe：notify=true 时告诉原生注销 token（原生自己发起的摘除不用回报） */
  function unmountFrame(rec, notify) {
    if (rec.iframe) {
      rec.iframe.remove();
      if (notify && rec.token) post('htmlRelease', { nodeId: rec.nodeId, segmentId: rec.segId, token: rec.token });
    }
    rec.iframe = null; rec.token = null; rec.pending = false; rec.reportedH = 0; rec.cspCount = 0;
    if (rec.mode === 'interactive') setMode(rec, 'static');
    rec.placeholder.hidden = false;
  }

  function setMode(rec, mode) {
    rec.mode = mode;
    rec.box.dataset.mode = mode;
    rec.run.textContent = mode === 'interactive' ? '收起' : '运行';
    rec.note.hidden = mode !== 'interactive';
    if (mode === 'interactive') rec.note.textContent = '交互还不完整：生成、世界书等酒馆助手功能暂不支持';
  }

  /** 可见的静态段按文档顺序挂，最多 MAX_STATIC 个（含在路上的请求） */
  function scheduleStatic() {
    var used = 0, waiting = [];
    Object.keys(htmlRecs).forEach(function (k) {
      var r = htmlRecs[k];
      if (r.mode !== 'static' || r.blocked) return;
      if (r.iframe || r.pending) used++;
      else if (r.visible) waiting.push(r);
    });
    waiting.sort(function (a, b) {
      return (a.box.compareDocumentPosition(b.box) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1;
    });
    waiting.forEach(function (r) {
      if (used >= MAX_STATIC) return;
      used++;
      r.pending = true;
      post('htmlMount', { nodeId: r.nodeId, segmentId: r.segId });
    });
  }

  el.messages.addEventListener('click', function (ev) {
    var box = ev.target.closest('.mp-html');
    if (!box || !box.__mpRec) return;
    var rec = box.__mpRec;
    if (ev.target.closest('.mp-html-run')) {
      post(rec.mode === 'interactive' ? 'htmlStop' : 'htmlRun', { nodeId: rec.nodeId, segmentId: rec.segId });
    } else if (ev.target.closest('.mp-html-blocked-btn')) {
      var list = box.querySelector('.mp-html-blocked-list');
      if (list) list.hidden = !list.hidden;
    } else if (ev.target.closest('.mp-html-expand')) {
      var expanded = box.dataset.expanded === '1';
      box.dataset.expanded = expanded ? '0' : '1';
      rec.frame.style.height = (expanded ? FRAME_H : FRAME_H_EXPANDED) + 'px';
      ev.target.textContent = expanded ? '展开' : '收拢';
    }
  });

  /* 子文档 → 父：只认登记过的 iframe window + 它自己的 token。
     静态：resize / cspReport；交互：再加 ready / error / openLink / call。nodeId / segmentId 由这里按来源 iframe 填，子页报的不算 */
  var ARGS_LIMIT = 256 * 1024;
  function utf8Bytes(s) { try { return unescape(encodeURIComponent(s)).length; } catch (_) { return s.length * 3; } }
  window.addEventListener('message', function (ev) {
    var rec = null;
    Object.keys(htmlRecs).some(function (k) {
      var r = htmlRecs[k];
      if (r.iframe && r.iframe.contentWindow === ev.source) { rec = r; return true; }
      return false;
    });
    var d = ev.data;
    if (!rec || !d || typeof d !== 'object' || d.__mpCard !== rec.token) return;
    var base = { token: rec.token, nodeId: rec.nodeId, segmentId: rec.segId };
    if (d.type === 'resize') {
      var h = Number(d.height);
      if (!isFinite(h) || h <= 0 || Math.abs(h - (rec.reportedH || 0)) < 1) return;
      rec.reportedH = h;
      base.height = h;
      post('htmlResize', base);
      return;
    }
    if (d.type === 'cspReport') {
      if ((rec.cspCount = (rec.cspCount || 0) + 1) > 60) return;
      base.kind = d.kind === 'unsupported' ? 'unsupported' : 'csp';
      base.text = String(d.text || '').slice(0, 300);
      post('htmlCSP', base);
      return;
    }
    if (rec.mode !== 'interactive') return;
    if (d.type === 'call') {
      var args;
      try { args = JSON.stringify(d.args === undefined ? {} : d.args); } catch (e) { return; }
      if (typeof d.id !== 'string' || d.id.length > 64 || typeof d.method !== 'string' || d.method.length > 64) return;
      if (utf8Bytes(args) > ARGS_LIMIT) {
        deliverTo(rec, { type: 'result', id: d.id, ok: false, error: '参数超过 256KB' });
        return;
      }
      base.callId = d.id; base.method = d.method; base.args = args;
      post('htmlCall', base);
      return;
    }
    if (d.type !== 'ready' && d.type !== 'error' && d.type !== 'openLink') return;
    var text = d.type === 'error' ? String(d.message || '') : (d.type === 'openLink' ? String(d.href || '') : '');
    if (text.length > 2048) return;
    base.kind = d.type; base.text = text;
    post('htmlChild', base);
  });

  function deliverTo(rec, payload) {
    if (!rec.iframe || !rec.iframe.contentWindow) return;
    payload.__mpHost = rec.token;
    try { rec.iframe.contentWindow.postMessage(payload, '*'); } catch (_) {}
  }

  /* ---------------- 交互 → Swift ---------------- */
  el.messages.addEventListener('click', function (ev) {
    // 「edited」浮层：点记号开合，点别处收起
    Array.prototype.forEach.call(el.messages.querySelectorAll('.mp-edited-pop:not([hidden])'), function (p) {
      if (!p.parentNode.contains(ev.target)) p.hidden = true;
    });
    var art = ev.target.closest('.mp-msg');
    if (!art) return;
    var id = art.dataset.nodeId;
    var edited = ev.target.closest('.mp-edited');
    if (edited) { var pop = edited.parentNode.querySelector('.mp-edited-pop'); if (pop) pop.hidden = !pop.hidden; return; }
    if (ev.target.closest('.mp-more'))        post('action', { name: 'menu', nodeId: id });
    else if (ev.target.closest('.mp-branch-prev')) post('switchBranch', { nodeId: id, delta: -1 });
    else if (ev.target.closest('.mp-branch-next')) post('switchBranch', { nodeId: id, delta: 1 });
  });

  el.send.addEventListener('click', doSend);
  el.attach.addEventListener('click', function () { post('pickAttachment', {}); });

  function doSend() {
    var text = el.field.innerText.replace(/ /g, ' ').trim();
    if (!text && !pendingAttachments.length) return;
    post('send', { text: text, attachmentIds: pendingAttachments.map(function (a) { return a.id; }) });
    el.field.textContent = '';
    updateSendState();   // chips 等 Swift 侧 setChips 推回来，别本地清（单一真相源）
  }

  el.field.addEventListener('input', updateSendState);
  function updateSendState() {
    var empty = !el.field.innerText.trim() && !pendingAttachments.length;
    el.send.disabled = empty;
  }

  /* ---------------- 附件 chips ---------------- */
  var pendingAttachments = [];
  function renderChips() {
    el.chips.textContent = '';
    pendingAttachments.forEach(function (a) {
      var chip = document.createElement('span');
      chip.className = 'mp-chip';
      var label = document.createElement('span');
      label.textContent = a.name || '附件';
      var x = document.createElement('button');
      x.type = 'button'; x.textContent = '×';
      x.addEventListener('click', function () {
        pendingAttachments = pendingAttachments.filter(function (p) { return p.id !== a.id; });
        renderChips(); updateSendState();
        post('removeAttachment', { id: a.id });   // VM 那边也得删，不然发送时又回来了
      });
      chip.appendChild(label); chip.appendChild(x);
      el.chips.appendChild(chip);
    });
  }

  /* ---------------- Swift → web（mp.*） ---------------- */
  window.mp = {
    /** 全量渲染：首屏 / 切对话 / 结构变化（分支切换、删除） */
    render: function (payload) {
      // ⑦：按消息 ID keyed 对账——已有的气泡原地更新、不挪位置（挪带 iframe 的节点会重载），
      // 只增删差异；追加 / 收藏 / 置顶别的消息时，正文没变的 HTML 段不重建
      var list = payload.messages || [];
      var next = Object.create(null);
      list.forEach(function (dto) {
        var art = nodeIndex[dto.id];
        if (art) applyMessage(art, dto); else art = buildMessage(dto);
        next[dto.id] = art;
      });
      Array.prototype.slice.call(el.messages.children).forEach(function (child) {
        if (next[child.dataset.nodeId] !== child) { destroySegments(child); child.remove(); }
      });
      nodeIndex = next;
      var cursor = el.messages.firstElementChild;
      list.forEach(function (dto) {
        var art = next[dto.id];
        if (art === cursor) cursor = cursor.nextElementSibling;
        else el.messages.insertBefore(art, cursor);
      });
      if (payload.theme) document.documentElement.dataset.theme = payload.theme;
      if (payload.placeholder) el.field.dataset.placeholder = payload.placeholder;
      // 刚插完 DOM 还没布局，直接滚会差一截 —— 等一帧
      requestAnimationFrame(function () { scrollToBottom(); el.toBottom.hidden = true; });
      updateSendState();
    },

    /** 内容变化（编辑 / 收藏 / 置顶） */
    patchNode: function (dto) {
      var art = nodeIndex[dto.id];
      if (art) applyMessage(art, dto);
    },

    removeNode: function (nodeId) {
      var art = nodeIndex[nodeId];
      if (art) { destroySegments(art); art.remove(); delete nodeIndex[nodeId]; }
    },

    /** 流式增量：只改一个节点的文本，不重渲列表 */
    appendDelta: function (nodeId, delta) {
      var art = nodeIndex[nodeId];
      if (!art) return;
      var stick = isNearBottom();
      art.dataset.streaming = '1';
      var body = art.querySelector('.mp-body');
      if (body.dataset.segmented) {
        // 分段正文不整块改写（会毁掉 iframe）：增量接到末尾文本段，下一次 patch 按段对账
        var last = body.lastElementChild;
        if (!last || last.dataset.segKind !== 'text') {
          last = document.createElement('div'); last.className = 'mp-seg-text'; body.appendChild(last);
        }
        last.textContent += delta;
      } else {
        body.textContent += delta;
      }
      if (stick) scrollToBottom();
    },

    /** 流式收尾：P2 起这里会把整块 Markdown 化 */
    endStream: function (nodeId, finalText) {
      var art = nodeIndex[nodeId];
      if (!art) return;
      art.dataset.streaming = '0';
      var body = art.querySelector('.mp-body');
      // 分段正文的终稿由随后的 patch（带 segments）对账，这里不整块覆盖
      if (typeof finalText === 'string' && !body.dataset.segmented) body.textContent = finalText;
    },

    /** 编辑消息：把原文回填输入框 */
    fillInput: function (text) {
      el.field.textContent = text || '';
      el.field.focus();
      updateSendState();
    },

    /** 原生 picker 选完 → 回填 chip（增量） */
    attachmentAdded: function (att) {
      pendingAttachments.push(att);
      renderChips(); updateSendState();
    },

    /** 全量同步待发送附件（Swift 侧 selectedAttachments 变化时推过来） */
    setChips: function (list) {
      pendingAttachments = list || [];
      renderChips(); updateSendState();
    },

    /** 换皮肤，不重载页面 */
    applySkin: function (cssText) { el.skin.textContent = cssText || ''; },

    applyBase: function (cssText) { el.base.textContent = cssText || ''; },

    setTheme: function (theme) { document.documentElement.dataset.theme = theme; },

    scrollToNode: function (nodeId) {
      var art = nodeIndex[nodeId];
      if (art) art.scrollIntoView({ block: 'center' });
    },

    /** ⑦ 原生发了 token：挂 iframe。段已不在 / 静态段已离屏 → 立刻退回 token */
    htmlAttach: function (nodeId, segId, spec) {
      var rec = htmlRecs[recKey(nodeId, segId)];
      var stale = !rec || !spec || (spec.mode === 'static' && (!rec.visible || rec.mode !== 'static'));
      if (stale) {
        if (rec) rec.pending = false;
        if (spec && spec.token) post('htmlRelease', { nodeId: nodeId, segmentId: segId, token: spec.token });
        scheduleStatic();
        return;
      }
      if (rec.iframe) unmountFrame(rec, true);
      if (spec.mode === 'interactive') setMode(rec, 'interactive');
      var f = document.createElement('iframe');
      // sandbox 先于 src 设好；永不 allow-same-origin。
      // B3：静态也给 allow-scripts，只为量高度——静态文档 CSP 是 script-src 'nonce-…'，只有原生注的那段能跑，正文脚本仍不执行
      f.setAttribute('sandbox', 'allow-scripts');
      f.setAttribute('referrerpolicy', 'no-referrer');
      f.className = 'mp-html-iframe';
      f.src = spec.src;
      rec.placeholder.hidden = true;
      rec.frame.appendChild(f);
      rec.iframe = f; rec.token = spec.token; rec.pending = false;
      scheduleStatic();
    },

    /** B3 原生 → 子页（result / event / snapshotUpdate）：只投给 token 对得上、还挂着的那个 iframe */
    htmlDeliver: function (nodeId, segId, token, payload) {
      var rec = htmlRecs[recKey(nodeId, segId)];
      if (!rec || rec.token !== token || !payload || typeof payload !== 'object') return;
      deliverTo(rec, payload);
    },

    /** B3 自动高度：原生已夹到 120–2000；有了实测高度就不再用固定高度 / 展开钮 */
    htmlResize: function (nodeId, segId, token, height) {
      var rec = htmlRecs[recKey(nodeId, segId)];
      if (!rec || rec.token !== token || !isFinite(height)) return;
      rec.frame.style.height = Math.round(height) + 'px';
      rec.box.dataset.autoHeight = '1';
      var ex = rec.box.querySelector('.mp-html-expand');
      if (ex) ex.hidden = true;
    },

    /** ⑦ 原生收回交互（收起 / 别处开了新的 / 撤权）：摘掉，退回静态排队 */
    htmlDetach: function (nodeId, segId) {
      var rec = htmlRecs[recKey(nodeId, segId)];
      if (!rec) return;
      unmountFrame(rec, false);
      setMode(rec, 'static');
      scheduleStatic();
    },

    /** ⑦ 给某段一行提示（没权限运行 / 太大）。blocked = 这段永远挂不上（太大），不再占名额、不再请求 */
    htmlNotice: function (nodeId, segId, text, blocked) {
      var rec = htmlRecs[recKey(nodeId, segId)];
      if (!rec) return;
      if (blocked) { rec.blocked = true; rec.pending = false; scheduleStatic(); }
      rec.note.hidden = false;
      rec.note.textContent = text || '';
    },

    /** B2 被挡的外部资源：卡片下沿右侧「挡掉了 N 个外部资源」，点开列域名 + 类型（数据来自原生 runtimeReports，按地址去重） */
    htmlBlocked: function (nodeId, segId, info) {
      var rec = htmlRecs[recKey(nodeId, segId)];
      if (!rec || !info) return;
      var wrap = rec.box.querySelector('.mp-html-blocked');
      if (!(info.count > 0)) { if (wrap) wrap.remove(); return; }   // 联网档位变了：原生清零重数
      if (!wrap) {
        wrap = document.createElement('div'); wrap.className = 'mp-html-blocked';
        var btn = document.createElement('button'); btn.type = 'button'; btn.className = 'mp-html-blocked-btn';
        var list = document.createElement('div'); list.className = 'mp-html-blocked-list'; list.hidden = true;
        wrap.appendChild(btn); wrap.appendChild(list);
        rec.box.appendChild(wrap);
      }
      var label = '挡掉了 ' + info.count + ' 个外部资源';
      var b = wrap.querySelector('.mp-html-blocked-btn');
      b.textContent = label;
      b.insertAdjacentHTML('afterbegin', '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l7 3v5c0 4.5-3 8.3-7 9.5-4-1.2-7-5-7-9.5V6z"/></svg>');
      var l = wrap.querySelector('.mp-html-blocked-list');
      l.textContent = '';
      var head = document.createElement('b'); head.textContent = label; l.appendChild(head);
      var rows = document.createElement('div'); rows.className = 'mp-html-blocked-rows';
      (info.rows || []).forEach(function (r) {
        var row = document.createElement('div');
        var code = document.createElement('code'); code.textContent = String(r.host || '');
        var tag = document.createElement('span'); tag.textContent = String(r.kind || '');
        row.appendChild(code); row.appendChild(tag); rows.appendChild(row);
      });
      l.appendChild(rows);
      [info.note, info.footnote].forEach(function (t) {
        if (!t) return;
        var p = document.createElement('p'); p.textContent = t; l.appendChild(p);
      });
    },

    /** ⑦ 后台 / 进程重启：全部摘掉（原生已注销全部 token，不回报） */
    htmlSuspend: function () {
      Object.keys(htmlRecs).forEach(function (k) { unmountFrame(htmlRecs[k], false); });
    },

    /** ⑦ 回前台：重新观察一遍，按可见性重新排队 */
    htmlResume: function () {
      if (!htmlObserver) return;
      Object.keys(htmlRecs).forEach(function (k) {
        var r = htmlRecs[k];
        htmlObserver.unobserve(r.box); htmlObserver.observe(r.box);
      });
    },

    /** ⑦ 自检用：某段当前 iframe 的状态（harness / 探针读，不改东西） */
    htmlState: function () {
      return Object.keys(htmlRecs).map(function (k) {
        var r = htmlRecs[k];
        return { key: k, mode: r.mode, visible: r.visible, mounted: !!r.iframe, pending: r.pending,
                 sandbox: r.iframe ? r.iframe.getAttribute('sandbox') : null, height: r.frame.style.height,
                 blocked: (r.box.querySelector('.mp-html-blocked-btn') || {}).textContent || null };
      });
    },

    /** 卡库第二批 B5：轻提示（/echo、被拒、降级成填输入框），输入栏上方停 2.6 秒 */
    toast: function (text) {
      var t = document.createElement('div');
      t.className = 'mp-toast'; t.setAttribute('role', 'status');
      t.textContent = String(text || '').slice(0, 300);
      var form = document.getElementById('mp-input');
      t.style.bottom = ((form ? form.offsetHeight : 64) + 12) + 'px';
      el.chat.appendChild(t);
      requestAnimationFrame(function () { t.classList.add('show'); });
      setTimeout(function () { t.classList.remove('show'); setTimeout(function () { t.remove(); }, 300); }, 2600);
    },

    error: function (code, message) { post('errorAck', { code: code, message: message }); },

    /** 调试用：spike 期的探针，Swift 侧按需调 */
    probe: function () {
      post('probe', {
        vv: vv ? Math.round(vv.height) : -1,
        offTop: vv ? Math.round(vv.offsetTop) : -1,
        win: window.innerHeight,
        atBottom: isNearBottom()
      });
    }
  };

  relayout();
  updateSendState();

  /* 没有 Swift 桥 = 在普通浏览器里直接打开这个文件（皮肤作者调 CSS 用）。
     自渲一份覆盖全部元素的假数据，双击 chat.html 就能看效果、改 chat-base.css 实时刷新。 */
  if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.mpChat) {
    // 假头像（SVG data URI）：--mp-avatar-size 设成 >0 才看得见
    var DEMO_AVATAR_AI = 'data:image/svg+xml,' + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">' +
      '<rect width="40" height="40" fill="#C9DCD2"/>' +
      '<circle cx="20" cy="16" r="7" fill="#FFF"/>' +
      '<path d="M6 40c0-8 6-13 14-13s14 5 14 13z" fill="#FFF"/></svg>');
    var DEMO_AVATAR_USER = 'data:image/svg+xml,' + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">' +
      '<rect width="40" height="40" fill="#E8D9A8"/>' +
      '<circle cx="20" cy="16" r="7" fill="#FFF"/>' +
      '<path d="M6 40c0-8 6-13 14-13s14 5 14 13z" fill="#FFF"/></svg>');
    var demo = [];
    for (var i = 1; i <= 8; i++) {
      demo.push({
        id: 'd' + i, role: i % 2 ? 'assistant' : 'user',
        text: i % 2
          ? '第 ' + i + ' 条：这条稍微长一点，用来撑出换行，顺便看看行距和段距在你的变量下是什么样子。'
          : '第 ' + i + ' 条：短的。',
        time: '10:0' + i, name: i % 2 ? '助手' : '你',
        avatarURL: i % 2 ? DEMO_AVATAR_AI : DEMO_AVATAR_USER
      });
    }
    demo.push({ id: 'dq', role: 'user', text: '带引用条的一条。', time: '10:09', name: '你',
                quoted: '被引用的原文片段…' });
    demo.push({ id: 'dt', role: 'assistant', text: '带思考折叠块的一条。', time: '10:10', name: '助手',
                thinking: '这里是思考过程，默认折叠。' });
    demo.push({ id: 'da', role: 'user', text: '带附件的一条。', time: '10:11', name: '你',
                attachments: [{ id: 'a1', kind: 'file', name: '报告.pdf' }] });
    demo.push({ id: 'db', role: 'assistant', text: '带分支指示器的一条。', time: '10:12', name: '助手',
                branch: { index: 1, total: 3 } });
    demo.push({ id: 'ds', role: 'assistant', text: '流式中的一条（末尾有光标）。', time: '10:13',
                name: '助手', streaming: true });
    demo.forEach(function (d) {
      if (!d.avatarURL) d.avatarURL = d.role === 'user' ? DEMO_AVATAR_USER : DEMO_AVATAR_AI;
    });
    mp.render({ messages: demo, theme: 'light', placeholder: '说点什么…' });
    // 浏览器里试皮肤：chat.html?skin=terminal / ?skin=paper（app 里走 mp.applySkin）
    var skin = (location.search.match(/skin=([\w-]+)/) || [])[1];
    if (skin) {
      var link = document.createElement('link');
      link.rel = 'stylesheet'; link.href = 'skins/' + skin + '.css';
      document.head.appendChild(link);
    }
    return;
  }

  post('ready', { capabilities: ['render', 'stream', 'branches', 'attachments', 'skin', 'html-segments'] });
})();
