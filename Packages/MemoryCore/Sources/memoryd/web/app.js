'use strict';

const state = {
  tab: 'bench',
  sets: [],
  currentSetId: null,
  currentSet: null,
  run: null,
  previous: null,
  wikiTrail: [],
  benchBusy: false,
  trial: {},
  review: null,
  reviewSets: [],
  reviewName: null,
  lab: { loaded: false, conversations: [], filter: '', picked: null, experiment: null, timer: null },
};

const $ = (id) => document.getElementById(id);

function esc(text) {
  return String(text == null ? '' : text)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function pct(value) {
  return value == null ? '—' : Math.round(value * 100) + '%';
}

function when(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function encodePath(path) {
  return path.split('/').map(encodeURIComponent).join('/');
}

async function api(path, options) {
  const response = await fetch(path, options);
  const text = await response.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch (_) { body = { error: text }; }
  if (!response.ok) throw new Error((body && body.error) || ('HTTP ' + response.status));
  return body;
}

function setStatus(text, isError) {
  const el = $('status');
  el.textContent = text || '';
  el.className = isError ? 'error' : 'muted';
  el.style.color = isError ? 'var(--bad)' : '';
}

function switchTab(tab) {
  state.tab = tab;
  $('tab-bench').classList.toggle('on', tab === 'bench');
  $('tab-wiki').classList.toggle('on', tab === 'wiki');
  $('page-bench').hidden = tab !== 'bench';
  $('page-wiki').hidden = tab !== 'wiki';
  $('tab-lab').classList.toggle('on', tab === 'lab');
  $('page-lab').hidden = tab !== 'lab';
  if (tab === 'lab' && !state.lab.loaded) loadLab();
  $('tab-review').classList.toggle('on', tab === 'review');
  $('page-review').hidden = tab !== 'review';
  if (tab === 'review') loadReview();
  if (tab === 'wiki' && state.wikiTrail.length === 0) loadWikiIndex();
}

/* ---------------- 测试台 ---------------- */

async function loadSets() {
  setStatus('读题集…');
  try {
    const body = await api('/api/bench/sets');
    state.sets = body.sets || [];
    setStatus('');
    renderSets();
  } catch (error) {
    setStatus('题集读取失败：' + error.message, true);
  }
}

function renderSets() {
  const page = $('page-bench');
  let html = '<div class="card"><h2>测试台</h2>'
    + '<div class="muted">跑一次 = 用例 × 配方 × 模型。<code>wiki</code> / <code>recall</code> 写手离线跑；<code>c2</code> / <code>a2</code> 写手要调模型（启动时加 <code>--model</code>，key 走环境变量），可以在下面贴一版提示词和「现行」并排跑。</div>'
    + '</div>';
  if (state.sets.length === 0) {
    html += '<div class="card muted">没有题集。</div>';
  }
  for (const set of state.sets) {
    const tag = set.runnable ? '<span class="tag">可跑</span>' : `<span class="tag off">${set.needsModel ? '没接模型' : '不可测'}</span>`;
    const trial = set.needsModel && set.runnable
      ? `<div style="margin-top:8px"><textarea data-trial="${esc(set.id)}" rows="6" style="width:100%;box-sizing:border-box;font:inherit" placeholder="试一版提示词（system）。留空 = 只跑现行。变量见题集详情：C2 有 {{称呼}} {{我的名字}} {{日期}}；A2 有 {{人设块}} {{任务说明}} {{称呼}}">${esc(state.trial[set.id] || '')}</textarea></div>`
      : '';
    html += `<div class="set"><div>
      <div><strong>${esc(set.name)}</strong>${tag}</div>
      <div class="muted">${esc(set.id)} · 写手 ${esc(set.writer)} · ${set.caseCount} 题</div>${trial}
    </div><div><button class="primary" data-run="${esc(set.id)}" ${state.benchBusy ? 'disabled' : ''}>跑一次</button></div></div>`;
  }
  if (state.benchBusy) html += '<div class="card"><span class="spinner"></span>跑中…</div>';
  page.innerHTML = html;
  page.querySelectorAll('[data-run]').forEach((button) => {
    button.addEventListener('click', () => runSet(button.dataset.run));
  });
  page.querySelectorAll('[data-trial]').forEach((area) => {
    area.addEventListener('input', () => { state.trial[area.dataset.trial] = area.value; });
  });
}

async function runSet(setId) {
  if (state.benchBusy) return;
  state.benchBusy = true;
  state.currentSetId = setId;
  state.run = null;
  state.previous = null;
  renderSets();
  setStatus('跑一次…');
  const trialSystem = (state.trial[setId] || '').trim();
  try {
    const started = await api('/api/bench/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(trialSystem ? { setId, recipes: [{ name: '试一版', system: trialSystem }] } : { setId }),
    });
    state.run = await api('/api/bench/runs/' + encodeURIComponent(started.runId));
    state.currentSet = await api('/api/bench/sets/' + encodeURIComponent(setId));
    state.previous = await findPrevious(state.run);
    setStatus('');
    renderRun();
  } catch (error) {
    setStatus('跑失败：' + error.message, true);
  } finally {
    state.benchBusy = false;
    if (!state.run) renderSets();
  }
}

async function findPrevious(run) {
  try {
    const body = await api('/api/bench/runs');
    const candidates = (body.runs || []).filter((item) =>
      item.set && item.set.id === run.set.id && item.id !== run.id && item.at < run.at && item.cells > 0);
    for (const item of candidates) {
      const detail = await api('/api/bench/runs/' + encodeURIComponent(item.id));
      const score = mainScore(detail);
      if (score != null) return { run: detail, score };
    }
  } catch (_) { /* 比较不上就不显示 */ }
  return null;
}

function mainScore(run) {
  if (!run) return null;
  const scores = (run.scores || []).filter((score) => score.main != null);
  return scores.length ? scores[0].main : null;
}

function labelsById(set) {
  const map = {};
  if (!set) return map;
  for (const testCase of set.cases || []) {
    for (const label of testCase.labels || []) map[label.id] = label;
  }
  return map;
}

function caseTitle(set, id) {
  if (!set) return id;
  const found = (set.cases || []).find((item) => item.id === id);
  return found ? found.title : id;
}

function renderRun() {
  const run = state.run;
  const page = $('page-bench');
  const score = mainScore(run);
  const labels = labelsById(state.currentSet);
  let html = '<div class="card">';
  html += `<div class="row"><div><h2>${esc(run.set.name)}</h2>
    <div class="muted">${esc(when(run.at))} · ${run.cells.length} 格 · ${esc(run.status)}</div></div>
    <button class="ghost" id="back-sets">返回题集</button></div>`;
  html += `<h3>${esc((run.scores && run.scores[0] && run.scores[0].mainName) || '主分')}</h3>`;
  html += `<div><span class="score">${pct(score)}</span>`;
  if (state.previous && state.previous.score != null && score != null) {
    const delta = score - state.previous.score;
    const sign = delta >= 0 ? '+' : '';
    html += ` <span class="delta ${delta >= 0 ? 'up' : 'down'}">${sign}${Math.round(delta * 100)} 个点，上一次 ${pct(state.previous.score)}</span>`;
  } else if (score != null) {
    html += ' <span class="muted">没有可比的上一跑</span>';
  }
  html += '</div>';
  const stats = (run.recipes || []).map((recipe) => labelStats(run, state.currentSet, recipe.id)).filter(Boolean);
  if (stats.length > 0) {
    html += '<h3>按标签看（主分只算配上标签的条目，漏记不扣分，以这里为准）</h3>';
    for (const item of stats) {
      html += `<div class="row"><span>${esc(recipeName(run, item.recipeId))}</span>
        <span class="muted">应记 命中 ${item.hit} / ${item.should} · 不该记 误记 ${item.wrong} / ${item.shouldNot} · 共写 ${item.items} 条 · 硬检查没过 ${item.hardFailed} · 出错 ${item.errors} 格</span></div>`;
      for (const label of item.missed) html += `<div class="muted">　漏记：${esc(label.caseTitle)} · ${esc(label.text)}</div>`;
      for (const label of item.mistaken) html += `<div class="error">　误记：${esc(label.caseTitle)} · ${esc(label.text)}</div>`;
    }
  }
  if (run.note) html += `<div class="muted">${esc(run.note)}</div>`;
  if ((run.cells || []).length === 0) {
    html += '<div class="muted">这次没有可测的题（全部跳过）。</div>';
  }

  const wrong = (run.judgments || []).filter((judgment) => judgment.verdict !== '对');
  html += '<h3>错例</h3>';
  if (wrong.length === 0) {
    html += '<div class="muted">没有错例。</div>';
  } else {
    html += '<ol class="bad">';
    for (const judgment of wrong) {
      const label = labels[judgment.labelId];
      html += `<li>${esc(caseTitle(state.currentSet, judgment.cellId.split('|')[0]))} · ${esc(judgment.verdict)}`
        + (label ? ' · ' + esc(label.kind + '：' + label.text) : '')
        + '</li>';
    }
    html += '</ol>';
  }

  html += '<h3>回执（点开看）</h3>';
  for (const cell of run.cells || []) {
    html += `<div class="cell" data-cell="${esc(cell.id)}">
      <div class="row"><span>${esc(caseTitle(state.currentSet, cell.caseId))}</span>
      <span class="muted">${cell.error ? '<span class="error">' + esc(cell.error) + '</span>' : cell.items.length + ' 条 · ' + cell.ms + 'ms'}</span></div>
      <div class="muted">${esc(recipeName(run, cell.recipeId))} · ${esc(cell.modelId)}</div>
      <div class="receipt" hidden></div>
    </div>`;
  }
  html += '</div>';
  page.innerHTML = html;

  $('back-sets').addEventListener('click', () => { state.run = null; renderSets(); });
  page.querySelectorAll('[data-cell]').forEach((row) => {
    row.addEventListener('click', () => {
      const cell = (run.cells || []).find((item) => item.id === row.dataset.cell);
      const box = row.querySelector('.receipt');
      if (!cell) return;
      if (!box.hidden) { box.hidden = true; box.innerHTML = ''; return; }
      box.hidden = false;
      box.innerHTML = itemsHtml(cell) + '<pre>' + esc(pretty(cell.output, cell.error)) + '</pre>';
    });
  });
}

/* 一版提示词在「应记 / 不该记」标签上的账：自动配只看关键词，配上「应记」= 命中，配上「不该记」= 误记，没配上的「应记」= 漏记 */
function labelStats(run, set, recipeId) {
  if (!set) return null;
  const cells = (run.cells || []).filter((cell) => cell.recipeId === recipeId);
  /* 应记：有一条判「对」= 写到了；不该记：有一条判「错」= 写进去了（C2 逐卡配、A2 逐标签判，两种都对得上） */
  const verdicts = {};
  for (const judgment of run.judgments || []) {
    const parts = judgment.cellId.split('|');
    if (parts[1] !== recipeId) continue;
    const key = parts[0] + '#' + judgment.labelId;
    (verdicts[key] = verdicts[key] || []).push(judgment.verdict);
  }
  const stats = { recipeId, should: 0, hit: 0, shouldNot: 0, wrong: 0, missed: [], mistaken: [],
    items: cells.reduce((sum, cell) => sum + (cell.items || []).length, 0),
    hardFailed: cells.reduce((sum, cell) => sum + (cell.checks || []).filter((check) => check.hard && !check.passed).length, 0),
    errors: cells.filter((cell) => cell.error).length };
  const ran = new Set(cells.filter((cell) => !cell.error).map((cell) => cell.caseId));
  for (const testCase of set.cases || []) {
    if (!ran.has(testCase.id)) continue;
    for (const label of testCase.labels || []) {
      const seen = verdicts[testCase.id + '#' + label.id] || [];
      const row = { caseTitle: testCase.title, text: label.text };
      if (label.kind === '应记') { stats.should += 1; if (seen.includes('对')) stats.hit += 1; else stats.missed.push(row); }
      if (label.kind === '不该记') { stats.shouldNot += 1; if (seen.includes('错')) { stats.wrong += 1; stats.mistaken.push(row); } }
    }
  }
  return stats.should + stats.shouldNot > 0 ? stats : null;
}

function recipeName(run, id) {
  const found = (run.recipes || []).find((item) => item.id === id);
  return found ? found.name : id;
}

/* 要调模型的写手：把解析出来的条目和没过的检查先列成人能读的几行，原始输出在下面 */
function itemsHtml(cell) {
  let html = '';
  for (const item of cell.items || []) {
    const fields = item.fields || {};
    if (fields.subject == null && fields.category == null) continue;
    const meta = [fields.subject, fields.speaker, fields.category, fields.importance && '重要度 ' + fields.importance]
      .filter(Boolean).join(' · ');
    html += `<div>· ${esc(item.text)} <span class="muted">${esc(meta)}</span></div>`;
  }
  for (const check of cell.checks || []) {
    if (!check.passed) html += `<div class="error">${esc(check.name)}没过${check.detail ? '：' + esc(check.detail) : ''}</div>`;
  }
  return html;
}

function pretty(output, error) {
  if (output == null) return error ? '没有结果：' + error : '没有输出';
  try { return JSON.stringify(JSON.parse(output), null, 2); } catch (_) { return output; }
}

/* ---------------- 整理结果：她审一轮，留 / 删 ---------------- */

async function loadReview(name) {
  const page = $('page-review');
  page.innerHTML = '<div class="card"><span class="spinner"></span>读整理结果…</div>';
  try {
    const listing = await api('/api/c2/results');
    state.reviewSets = listing.results || [];
    const newest = state.reviewSets.find((set) => (set.row || '').startsWith('包里的写入'));
    const pick = name || state.reviewName || (newest && newest.name) || listing.default || (state.reviewSets[0] && state.reviewSets[0].name);
    state.reviewName = pick;
    state.review = await api('/api/c2/review/' + encodeURIComponent(pick));
    renderReview();
  } catch (error) {
    page.innerHTML = '<div class="card error">读不了：' + esc(error.message) + '</div>';
  }
}

async function markReview(key, verdict) {
  const review = state.review;
  const next = review.verdicts[key] === verdict ? '' : verdict;
  try {
    await api('/api/c2/review', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: review.file, key, verdict: next }),
    });
    if (next) review.verdicts[key] = next; else delete review.verdicts[key];
    const row = document.querySelector(`[data-row="${key}"]`);
    if (row) row.outerHTML = reviewRow(rowByKey(key), row.dataset.kind);
    wireReview();
    if ($('review-count')) $('review-count').textContent = reviewCount();
  } catch (error) {
    setStatus('没记上：' + error.message, true);
  }
}

function rowByKey(key) {
  const review = state.review;
  return review.kept.concat(review.unsure, review.dropped).find((item) => item.key === key);
}

function reviewCount() {
  const review = state.review;
  const values = Object.values(review.verdicts);
  return `你点过 ${values.length} 张：留 ${values.filter((v) => v === 'keep').length} · 删 ${values.filter((v) => v === 'drop').length}`;
}

function reviewRow(item, kind) {
  const mine = state.review.verdicts[item.key];
  const button = (verdict, label) => `<button class="${mine === verdict ? 'primary' : 'ghost'}" data-mark="${item.key}" data-verdict="${verdict}">${label}</button>`;
  const confidence = item.confidence == null ? '' : ` <span class="tag${item.confidence < 0.6 ? ' off' : ''}">把握 ${Math.round(item.confidence * 100)}%</span>`;
  let html = `<div class="cell" data-row="${item.key}" data-kind="${kind}"><div class="row"><div style="flex:1">${item.subject ? `<strong>${esc(item.subject)}</strong> · ` : ''}${esc(item.content)}${(item.marks || []).map((m) => ` <span class="tag">${esc(m)}</span>`).join('')}${confidence}${item.since ? ` <span class="tag">自 ${esc(item.since)}</span>` : ''}`;
  if (item.why) html += `<div class="muted">模型说：${esc(item.why)}</div>`;
  const from = item.from || [];
  const sourceBox = (text) => `<div class="muted" style="white-space:pre-wrap;border-left:2px solid var(--line, #ccc);padding-left:8px;margin:4px 0">${esc(text || '（找不到出处）')}</div>`;
  if (from.length > 1) {
    html += `<details><summary class="muted">由 ${from.length} 张并成（点开看原来的卡和各自的原文）</summary>`
      + from.map((piece) => `<div style="margin-top:6px">· ${esc(piece.content)}</div>` + sourceBox(piece.source)).join('') + '</details>';
  } else {
    const text = from.length === 1 ? from[0].source : item.source;
    html += `<details><summary class="muted">看原文</summary>${sourceBox(text)}</details>`;
  }
  html += `</div>${state.review.model === 'write' ? '' : `<div style="white-space:nowrap">${button('keep', '留')} ${button('drop', '删')}</div>`}</div></div>`;
  return html;
}

function wireReview() {
  document.querySelectorAll('[data-mark]').forEach((button) => {
    button.onclick = () => markReview(button.dataset.mark, button.dataset.verdict);
  });
}

function reviewPicker() {
  // 两层分组：大类（写入 / 整理）→ 一行一种做法 → 这一行里各个模型
  const groups = [];
  for (const set of state.reviewSets || []) {
    let group = groups.find((g) => g.title === (set.group || '其它'));
    if (!group) { group = { title: set.group || '其它', rows: [] }; groups.push(group); }
    let row = group.rows.find((r) => r.title === (set.row || ''));
    if (!row) { row = { title: set.row || '', sets: [] }; group.rows.push(row); }
    row.sets.push(set);
  }
  const current = (state.reviewSets || []).find((set) => set.name === state.reviewName);
  return groups.map((group) => `<details ${current && (current.group || '其它') === group.title ? 'open' : ''} style="margin-bottom:6px">
    <summary><strong>${esc(group.title)}</strong></summary>
    <table style="margin-top:4px">${group.rows.map((row) => `<tr><td class="muted" style="padding:3px 12px 3px 0;white-space:nowrap">${esc(row.title)}</td>
      <td>${row.sets.map((set) => `<button class="${set.name === state.reviewName ? 'primary' : 'ghost'}" data-set="${esc(set.name)}">${esc(set.short || set.label)} · ${set.kept}</button>`).join(' ')}</td></tr>`).join('')}</table></details>`).join('');
}

function renderReview() {
  const review = state.review;
  const page = $('page-review');
  const section = (title, note, items, kind, open) => !items.length ? '' : `<div class="card"><details ${open ? 'open' : ''}>
    <summary><strong>${title} · ${items.length}</strong> <span class="muted">${note}</span></summary>
    ${items.map((item) => reviewRow(item, kind)).join('')}</details></div>`;
  const current = (state.reviewSets || []).find((set) => set.name === state.reviewName) || {};
  const isWrite = review.model === 'write';
  let head;
  let body;
  if (isWrite) {
    const has = (item, mark) => (item.marks || []).includes(mark);
    const notes = review.kept.filter((item) => has(item, '给 wiki'));
    const cards = review.kept.filter((item) => !has(item, '给 wiki'));
    const ways = cards.filter((item) => has(item, 'instruction'));
    const facts = cards.filter((item) => !has(item, 'instruction'));
    const chars = cards.length ? Math.round(cards.reduce((sum, item) => sum + item.content.length, 0) / cards.length) : 0;
    head = `<div class="muted">正在看：<strong>${esc(current.row || '')} · ${esc(current.short || '')}</strong>。同一段 ${review.total} 条对话，${cards.length} 张卡（平均 ${chars} 字）${notes.length ? `，${notes.length} 段给 wiki 的段落` : ''}。每条可以点开看出处原文。</div>`;
    body = section('事实', '她是什么样 / 发生了什么', facts, 'kept', true)
      + section('给克克的做法', '这种时候要怎么做 / 不要怎么做', ways, 'kept', true)
      + section('给 wiki 的段落', '某件事现在是什么情况、为什么；点开看撑着它的卡', notes, 'kept', true);
  } else {
    head = `<div class="muted">正在看：<strong>${esc(current.row || '')} · ${esc(current.short || '')}</strong>。原来 ${review.total} 张没看过的卡，整理之后：建议留 ${review.kept.length} 张（说同一件事的已并在一起）、拿不准 ${review.unsure.length} 张、删了 ${review.dropped.length} 张。并出来的卡可以点开看是由哪几张并的。</div>
    <div id="review-count" class="muted" style="margin-top:6px">${reviewCount()}</div>`;
    body = section('拿不准的', '模型没把握，先看这些', review.unsure, 'unsure', true)
      + section('建议留的', '', review.kept, 'kept', true)
      + section('它删掉的', '想捞回来的点「留」', review.dropped, 'dropped', false);
  }
  page.innerHTML = `<div class="card"><h2>结果对照</h2>${reviewPicker()}${head}</div>` + body;
  wireReview();
  page.querySelectorAll('[data-set]').forEach((button) => {
    button.onclick = () => loadReview(button.dataset.set);
  });
}

/* ---------------- 实验台：挑一个对话跑写入侧 ---------------- */

function labSetting(key, fallback) {
  try { const v = localStorage.getItem('memoryd.lab.' + key); return v == null ? fallback : v; } catch (_) { return fallback; }
}

function labSave(key, value) {
  try { localStorage.setItem('memoryd.lab.' + key, value); } catch (_) { /* 存不了就算了 */ }
}

async function loadLab() {
  const page = $('page-lab');
  page.innerHTML = '<div class="card"><span class="spinner"></span>读对话…</div>';
  try {
    const body = await api('/api/conversations');
    state.lab.conversations = body.conversations || [];
    state.lab.model = body.model;
    state.lab.loaded = true;
    renderLabList();
  } catch (error) {
    page.innerHTML = '<div class="card error">读不了对话：' + esc(error.message) + '</div>';
  }
}

function renderLabList() {
  const lab = state.lab;
  const page = $('page-lab');
  const filter = lab.filter.trim().toLowerCase();
  const rows = lab.conversations.filter((item) => !filter || (item.title || '').toLowerCase().includes(filter));
  let html = '<div class="card"><h2>实验台</h2>'
    + '<div class="muted">挑一个对话，在电脑上把写入那一侧跑一遍：上下文摘要（A2）→ 窗口总结（A3）→ 碎片（C2）。用的是和手机上同一份写手代码；结果只存在这份副本里，不写回手机。'
    + (lab.model ? ' 模型：' + esc(lab.model) : ' <span class="error">没接模型，跑不了</span>') + '</div>'
    + `<div style="margin-top:8px"><input id="lab-filter" placeholder="按标题筛" value="${esc(lab.filter)}" style="width:100%;box-sizing:border-box;font:inherit;padding:6px"></div>`
    + `<div class="muted">${rows.length} / ${lab.conversations.length} 个对话</div></div><div class="card">`;
  for (const item of rows.slice(0, 300)) {
    html += `<div class="entry click" data-conv="${esc(item.id)}"><span>${esc(item.title || '（没标题）')}</span>
      <span class="count">${item.messages} 条 · ${esc(when(item.updatedAt))}</span></div>`;
  }
  html += '</div><div id="lab-history"></div>';
  page.innerHTML = html;
  const input = $('lab-filter');
  input.addEventListener('input', () => {
    lab.filter = input.value;
    renderLabList();
    const again = $('lab-filter');
    again.focus();
    again.setSelectionRange(again.value.length, again.value.length);
  });
  page.querySelectorAll('[data-conv]').forEach((row) => {
    row.addEventListener('click', () => {
      lab.picked = lab.conversations.find((item) => item.id === row.dataset.conv);
      renderLabForm();
    });
  });
  loadLabHistory();
}

async function loadLabHistory() {
  try {
    const body = await api('/api/experiments');
    const box = $('lab-history');
    if (!box || !(body.experiments || []).length) return;
    let html = '<div class="card"><h3>跑过的</h3>';
    for (const item of body.experiments) {
      html += `<div class="entry click" data-exp="${esc(item.id)}"><span>${esc(item.windowTitle || '（没标题）')}</span>
        <span class="count">${esc(when(item.at))} · ${item.ranMessages} 条 · ${item.segments} 段 · ${item.cards} 张卡 · ${esc(item.status === 'running' ? '在跑 ' + item.progress : item.status)}</span></div>`;
    }
    box.innerHTML = html + '</div>';
    box.querySelectorAll('[data-exp]').forEach((row) => row.addEventListener('click', () => openExperiment(row.dataset.exp)));
  } catch (_) { /* 历史读不了不挡主流程 */ }
}

function renderLabForm() {
  const item = state.lab.picked;
  const page = $('page-lab');
  const field = (id, label, value, hint) => `<div style="margin-top:8px"><div class="muted">${label}</div>
    <input id="${id}" value="${esc(value)}" style="width:100%;box-sizing:border-box;font:inherit;padding:6px">${hint ? '<div class="muted">' + hint + '</div>' : ''}</div>`;
  page.innerHTML = `<div class="card"><div class="row"><div><h2>${esc(item.title || '（没标题）')}</h2>
      <div class="muted">主线 ${item.messages} 条 · ${esc(when(item.updatedAt))}</div></div>
      <button class="ghost" id="lab-back">返回</button></div>
    ${field('lab-user', '她的称呼', labSetting('user', ''), '空 = 摘要里叫「对方」、碎片里叫「用户」，和手机上没填时一样')}
    ${field('lab-char', '助手的名字', labSetting('char', ''), '')}
    <div style="margin-top:8px"><div class="muted">人设（A2 / A3 会先读它；可空）</div>
      <textarea id="lab-persona" rows="4" style="width:100%;box-sizing:border-box;font:inherit">${esc(labSetting('persona', ''))}</textarea></div>
    ${field('lab-from', '从主线第几条开始', '1', '')}
    ${field('lab-limit', '最多跑几条', String(Math.min(item.messages, 400)), '长对话先跑一截看看；上限 3000')}
    ${field('lab-seg', '上下文摘要每段几条', labSetting('seg', '40'), '手机上是聊长了挤出视野才写一段，这里按固定条数切')}
    ${field('lab-frag', '碎片每几条抽一次', labSetting('frag', '20'), '手机上默认 20')}
    <div style="margin-top:8px"><label><input type="checkbox" id="lab-a2" checked> 上下文摘要</label>
      <label><input type="checkbox" id="lab-a3" checked> 窗口总结</label>
      <label><input type="checkbox" id="lab-c2" checked> 碎片</label></div>
    <div style="margin-top:12px"><button class="primary" id="lab-run">跑</button> <span id="lab-estimate" class="muted"></span></div></div>`;
  $('lab-back').addEventListener('click', renderLabList);
  const estimate = () => {
    const n = Math.min(Number($('lab-limit').value) || 0, item.messages);
    const a2 = $('lab-a2').checked ? Math.ceil(n / (Number($('lab-seg').value) || 40)) : 0;
    const c2 = $('lab-c2').checked ? Math.ceil(n / (Number($('lab-frag').value) || 20)) : 0;
    $('lab-estimate').textContent = `大约调 ${a2 + ($('lab-a3').checked ? 1 : 0) + c2} 次模型（格式不对会多重写一次）`;
  };
  page.querySelectorAll('input').forEach((el) => el.addEventListener('input', estimate));
  estimate();
  $('lab-run').addEventListener('click', startExperiment);
}

async function startExperiment() {
  const item = state.lab.picked;
  labSave('user', $('lab-user').value);
  labSave('char', $('lab-char').value);
  labSave('persona', $('lab-persona').value);
  labSave('seg', $('lab-seg').value);
  labSave('frag', $('lab-frag').value);
  const steps = ['a2', 'a3', 'c2'].filter((step) => $('lab-' + step).checked);
  const body = {
    conversationId: item.id, userName: $('lab-user').value, assistantName: $('lab-char').value,
    persona: $('lab-persona').value, segmentSize: Number($('lab-seg').value) || 40,
    fragmentEvery: Number($('lab-frag').value) || 20, from: Math.max((Number($('lab-from').value) || 1) - 1, 0),
    limit: Number($('lab-limit').value) || 400, steps,
  };
  try {
    const started = await api('/api/experiments/run', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    openExperiment(started.id);
  } catch (error) {
    setStatus('跑不起来：' + error.message, true);
  }
}

async function openExperiment(id) {
  if (state.lab.timer) { clearTimeout(state.lab.timer); state.lab.timer = null; }
  try {
    const experiment = await api('/api/experiments/' + encodeURIComponent(id));
    state.lab.experiment = experiment;
    renderExperiment();
    if (experiment.status === 'running' && state.tab === 'lab') {
      state.lab.timer = setTimeout(() => openExperiment(id), 2000);
    }
  } catch (error) {
    setStatus('读不了这次实验：' + error.message, true);
  }
}

function segmentHtml(segment, heading) {
  let html = `<div class="cell"><div class="row"><strong>${esc(heading)}${segment.title ? ' · ' + esc(segment.title) : ''}</strong>
    <span class="muted">第 ${segment.from}–${segment.to} 条</span></div>`;
  if (segment.error) return html + `<div class="error">${esc(segment.error)}</div></div>`;
  html += `<div style="white-space:pre-wrap;margin-top:4px">${esc(segment.story)}</div>`;
  if (segment.quotes) html += `<div class="muted" style="white-space:pre-wrap;margin-top:4px">${esc(segment.quotes)}</div>`;
  if ((segment.keywords || []).length) html += `<div class="muted">关键词：${esc(segment.keywords.join('，'))}</div>`;
  if (segment.pending) html += `<div class="muted" style="white-space:pre-wrap">待续：${esc(segment.pending)}</div>`;
  for (const problem of segment.problems || []) html += `<div class="error">⚠ ${esc(problem)}</div>`;
  return html + '</div>';
}

function renderExperiment() {
  const e = state.lab.experiment;
  const page = $('page-lab');
  const cards = (e.fragments || []).reduce((sum, batch) => sum + (batch.cards || []).length, 0);
  let html = `<div class="card"><div class="row"><div><h2>${esc(e.windowTitle || '（没标题）')}</h2>
    <div class="muted">${esc(when(e.at))} · ${esc(e.model)} · 主线 ${e.totalMessages} 条里跑了 ${e.ranMessages} 条 · 调了 ${e.calls} 次 · 输入 ${e.inputTokens} / 输出 ${e.outputTokens} token</div></div>
    <button class="ghost" id="lab-back">返回</button></div>`;
  if (e.status === 'running') html += `<div><span class="spinner"></span>在跑：${esc(e.progress)}</div>`;
  if (e.note) html += `<div class="muted">${esc(e.note)}</div>`;
  html += '</div>';
  if (e.summary) html += '<div class="card"><h3>窗口总结（A3）</h3>' + segmentHtml(e.summary, '总结') + '</div>';
  if ((e.segments || []).length) {
    html += `<div class="card"><h3>上下文摘要（A2）· ${e.segments.length} 段</h3>`;
    for (const segment of e.segments) html += segmentHtml(segment, '第 ' + segment.index + ' 段');
    html += '</div>';
  }
  if ((e.fragments || []).length) {
    html += `<div class="card"><h3>碎片（C2）· ${cards} 张</h3>`;
    for (const batch of e.fragments) {
      html += `<div class="cell"><div class="row"><strong>第 ${batch.from}–${batch.to} 条</strong>
        <span class="muted">${(batch.cards || []).length} 张${batch.rejected ? ' · 拒收 ' + batch.rejected : ''}</span></div>`;
      if (batch.error) html += `<div class="error">${esc(batch.error)}</div>`;
      for (const card of batch.cards || []) {
        const meta = [card.subject, card.speaker, card.category, '重要度 ' + card.importance, '出自第 ' + card.message + ' 条'].filter(Boolean).join(' · ');
        html += `<div>· ${esc(card.content)} <span class="muted">${esc(meta)}</span></div>`;
      }
      for (const reason of batch.rejectionReasons || []) html += `<div class="error">拒收：${esc(reason)}</div>`;
      html += '</div>';
    }
    html += '</div>';
  }
  page.innerHTML = html;
  $('lab-back').addEventListener('click', () => {
    if (state.lab.timer) { clearTimeout(state.lab.timer); state.lab.timer = null; }
    renderLabList();
  });
}

/* ---------------- wiki ---------------- */

async function loadWikiIndex() {
  const page = $('page-wiki');
  page.innerHTML = '<div class="card"><span class="spinner"></span>读目录…</div>';
  try {
    const body = await api('/api/wiki/index');
    state.wikiTrail = [{ title: 'wiki', path: '' }];
    let html = '<div class="card"><h2>wiki</h2><div class="muted">根目录 → 组 → 页 → 条目。条目原文层留刀 2。</div></div><div class="card">';
    for (const group of body.groups || []) {
      const label = group.path === '{{user}}' ? '本人' : (group.title || group.path);
      html += `<div class="entry ${group.count ? 'click' : ''}" data-group="${esc(group.path)}">
        <span>${esc(label)}</span><span class="count">${group.count} 页</span></div>`;
    }
    html += '</div>';
    page.innerHTML = html;
    page.querySelectorAll('[data-group]').forEach((row) => {
      row.addEventListener('click', () => {
        if (!row.classList.contains('click')) return;
        loadWikiGroup(row.dataset.group, [{ title: 'wiki', path: '' }, { title: labelOf(row.dataset.group), path: row.dataset.group }]);
      });
    });
  } catch (error) {
    page.innerHTML = '<div class="card error">wiki 读取失败：' + esc(error.message) + '</div>';
  }
}

function labelOf(groupPath) {
  return groupPath === '{{user}}' ? '本人' : groupPath;
}

function crumbHtml(trail) {
  const parts = trail.map((item, index) => {
    const title = labelOf(item.title);
    return index === trail.length - 1
      ? '<span>' + esc(title) + '</span>'
      : `<a data-crumb="${index}">${esc(title)}</a>`;
  });
  return '<div class="crumb">' + parts.join(' / ') + '</div>';
}

function wireCrumbs(page, trail) {
  page.querySelectorAll('[data-crumb]').forEach((link) => {
    link.addEventListener('click', () => {
      const index = Number(link.dataset.crumb);
      const target = trail[index];
      const nextTrail = trail.slice(0, index + 1);
      if (index === 0) loadWikiIndex();
      else loadWikiGroup(target.path, nextTrail);
    });
  });
}

async function loadWikiGroup(path, trail) {
  const page = $('page-wiki');
  if (!trail) trail = state.wikiTrail;
  page.innerHTML = crumbHtml(trail) + '<div class="card"><span class="spinner"></span>读分组…</div>';
  try {
    const body = await api('/api/wiki/group/' + encodePath(path));
    let html = crumbHtml(trail) + '<div class="card">';
    if (!body.entries || body.entries.length === 0) html += '<div class="muted">空分组。</div>';
    for (const entry of body.entries || []) {
      if (entry.type === 'folder') {
        html += `<div class="entry click" data-folder="${esc(entry.path)}">
          <span>${esc(entry.title)}</span><span class="count">${entry.count} 页</span></div>`;
      } else {
        html += `<div class="entry click" data-page="${esc(entry.path)}">
          <span>${esc(entry.title)}${entry.hook ? ' <span class="muted">— ' + esc(entry.hook) + '</span>' : ''}</span>
          <span class="count">页</span></div>`;
      }
    }
    html += '</div>';
    page.innerHTML = html;
    wireCrumbs(page, trail);
    page.querySelectorAll('[data-folder]').forEach((row) => {
      row.addEventListener('click', () => {
        loadWikiGroup(row.dataset.folder, trail.concat([{ title: row.dataset.folder, path: row.dataset.folder }]));
      });
    });
    page.querySelectorAll('[data-page]').forEach((row) => {
      row.addEventListener('click', () => {
        loadWikiPage(row.dataset.page, trail.concat([{ title: row.dataset.page, path: row.dataset.page }]));
      });
    });
  } catch (error) {
    page.innerHTML = crumbHtml(trail) + '<div class="card error">分组读取失败：' + esc(error.message) + '</div>';
  }
}

async function loadWikiPage(path, trail) {
  const page = $('page-wiki');
  page.innerHTML = crumbHtml(trail) + '<div class="card"><span class="spinner"></span>读页…</div>';
  try {
    const body = await api('/api/wiki/page/' + encodePath(path));
    let html = crumbHtml(trail) + '<div class="card">';
    html += `<h2>${esc(body.title)}</h2>`;
    if (body.kind) html += `<span class="tag">${esc(body.kind)}</span>`;
    if (body.hook) html += `<div class="muted">${esc(body.hook)}</div>`;
    if (body.validUntil) html += `<div class="muted">有效到 ${esc(body.validUntil)}</div>`;
    if (body.now) html += '<h3>现在</h3><div>' + esc(body.now).replace(/\n/g, '<br>') + '</div>';
    if (body.records && body.records.length) {
      html += '<h3>记录</h3><ul class="plain">' + body.records.map((line) => '<li>' + esc(line) + '</li>').join('') + '</ul>';
    }
    if (body.links && body.links.length) {
      html += '<h3>连到</h3><ul class="plain">' + body.links.map((link) =>
        '<li>' + esc(link.target) + ' <span class="muted">（' + esc(link.relation) + '）' + (link.why ? esc(' ' + link.why) : '') + '</span></li>').join('') + '</ul>';
    }
    if (body.entries && body.entries.length) {
      html += '<h3>条目</h3><ul class="plain">' + body.entries.map((entry) => {
        const shown = String(entry).split('|')[0];
        return `<li>${esc(shown)} <button class="ghost" data-entry="${esc(entry)}">读原文</button></li>`;
      }).join('') + '</ul>';
    }
    html += '<h3>原文</h3><pre>' + esc(body.markdown) + '</pre>';
    html += '</div>';
    page.innerHTML = html;
    wireCrumbs(page, trail);
    page.querySelectorAll('[data-entry]').forEach((button) => {
      button.addEventListener('click', () => readEntry(button.dataset.entry, trail));
    });
  } catch (error) {
    page.innerHTML = crumbHtml(trail) + '<div class="card error">页读取失败：' + esc(error.message) + '</div>';
  }
}

async function readEntry(key, trail) {
  const page = $('page-wiki');
  try {
    const pagePath = trail.length ? trail[trail.length - 1].path : '';
    if (!pagePath || !String(key).startsWith('memory/')) throw new Error('原文层只接 seed 卡（memory/ 开头）');
    const body = await api('/api/wiki/entry/' + pagePath.split('/').length + '/' + encodePath(pagePath) + '/' + encodePath(String(key)));
    const message = body && body.text ? body.text : (body && body.missing ? '原文当时没存：' + body.missing : '没有内容');
    const note = body && body.complete === false ? '<div class="muted">未完：一期只返回首 3000 字（续读未接）</div>' : '';
    page.innerHTML = crumbHtml(trail) + `<div class="card"><h2>条目</h2><div class="muted">${esc(String(key))}</div>
      <pre>${esc(message)}</pre>${note}</div>`;
    wireCrumbs(page, trail);
  } catch (error) {
    setStatus('条目读取失败：' + error.message, true);
  }
}

/* ---------------- 启动 ---------------- */

async function openRun(runId) {
  try {
    state.run = await api('/api/bench/runs/' + encodeURIComponent(runId));
    state.currentSetId = state.run.set.id;
    state.currentSet = await api('/api/bench/sets/' + encodeURIComponent(state.run.set.id));
    state.previous = await findPrevious(state.run);
    renderRun();
  } catch (error) {
    setStatus('读这次跑失败：' + error.message, true);
    renderSets();
  }
}

document.querySelectorAll('nav button').forEach((button) => {
  button.addEventListener('click', () => switchTab(button.dataset.tab));
});

const params = new URLSearchParams(location.search);
if (params.get('tab') === 'wiki') switchTab('wiki');
if (params.get('tab') === 'lab') switchTab('lab');
if (params.get('tab') === 'review') switchTab('review');
if (params.get('run')) openRun(params.get('run'));
else if (params.get('tab') !== 'wiki') loadSets();
