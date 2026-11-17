'use strict';

const state = {
  tab: 'runs',
  conn: null,
  // 虚构题集
  sets: [],
  benchRuns: null,
  currentSetId: null,
  currentSet: null,
  run: null,
  previous: null,
  benchBusy: false,
  trial: {},
  // wiki
  wikiTrail: [],
  // 实验记录：所有跑过的放一张表（新存法 bench-runs/experiments + 老存法 gold/write、gold/organize、c2-merge）
  runs: { items: null, filter: 'all', window: '', picked: [], open: null, timer: null, appPrompt: null, vfilter: 'all', vopen: {} },
  // 一次调用：右侧抽屉
  drawer: { id: null, rows: [], n: null, tab: 'system', cache: {} },
  // 跑一次新的
  lab: { loaded: false, conversations: [], filter: '', picked: null, model: null, prompts: null },
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

const pad = (n) => String(n).padStart(2, '0');

function when(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function hm(ms) {
  const d = new Date(ms);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function dayName(ms) {
  const d = new Date(ms);
  const today = new Date();
  const start = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((start(today) - start(d)) / 86400000);
  const label = `${d.getMonth() + 1} 月 ${d.getDate()} 日`;
  return diff === 0 ? label + ' · 今天' : diff === 1 ? label + ' · 昨天' : label;
}

function longWhen(ms) {
  return ms ? `${dayName(ms)} ${hm(ms)}` : '时间没记下';
}

function tokens(n) {
  if (n == null) return '';
  return n >= 10000 ? (Math.round(n / 1000) / 10) + ' 万' : String(n);
}

function duration(seconds) {
  if (!seconds) return '';
  return seconds >= 60 ? `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒` : `${seconds} 秒`;
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
}

const notSaved = (why) => `<span class="notsaved">这一次没存${why ? '：' + esc(why) : ''}</span>`;

/* ---------------- 页签和地址栏 ---------------- */

const TABS = ['runs', 'new', 'wiki', 'bench'];

function switchTab(tab) {
  state.tab = tab;
  for (const name of TABS) {
    $('tab-' + name).classList.toggle('on', name === tab);
    $('page-' + name).hidden = name !== tab;
  }
  if (tab !== 'runs') { stopPolling(); document.body.classList.remove('wide'); closeDrawer(); }
  if (tab === 'new' && !state.lab.loaded) loadLab();
  if (tab === 'wiki' && state.wikiTrail.length === 0) loadWikiIndex();
}

function go(params) {
  history.pushState(null, '', '?' + new URLSearchParams(params).toString());
  route();
}

function route() {
  const params = new URLSearchParams(location.search);
  let tab = params.get('tab') || 'runs';
  if (tab === 'review') tab = 'runs';
  if (tab === 'lab') tab = 'new';
  if (params.get('run')) tab = 'bench';
  if (!TABS.includes(tab)) tab = 'runs';
  closeDrawer();
  switchTab(tab);
  if (tab === 'runs') {
    if (params.get('open')) openRun(params.get('open'));
    else if (params.get('compare')) openCompare(params.get('compare').split(',').filter(Boolean));
    else showRunList();
  }
  if (tab === 'bench') {
    if (params.get('run')) openBenchRun(params.get('run'));
    else renderSetsOrLoad();
  }
}

/* ---------------- 顶上一条：现在连的是哪份数据、哪个模型 ---------------- */

async function loadConn() {
  try { state.conn = await api('/api/status'); } catch (error) { state.conn = { error: error.message }; }
  renderConn();
}

function renderConn() {
  const s = state.conn;
  const el = $('conn');
  if (!s) return;
  if (s.error) { el.innerHTML = `<span class="error">连不上 memoryd：${esc(s.error)}（重启中的话等一会儿会自己连上）</span>`; return; }
  const folder = String(s.floor || '').split('/').filter(Boolean).pop() || '没记下';
  const snap = s.conversationSnapshot;
  const data = snap
    ? `<b>${esc(folder)}</b> · 楼层快照 ${snap.exportedAt ? esc(when(snap.exportedAt)) + ' 导出' : '导出时间没记'} · ${snap.windows} 个窗口 / ${snap.nodes} 条消息`
    : `<b>${esc(folder)}</b> · 没有楼层快照`;
  const model = s.model ? `<b>${esc(prettyModel(s.model))}</b>` : '<span class="error">没接模型，只能看不能跑</span>';
  el.innerHTML = `<span><span class="k">数据</span>${data}</span><span><span class="k">跑新实验用的模型</span>${model}</span>`
    + (s.note ? `<span class="error">${esc(s.note)}</span>` : '');
}

/* ---------------- 老存法那批的说明 ----------------
   老的两晚（11-11、11-12 下午）结果只存了条目，接口不给时间、模型、喂法。下面是从各轮目录里的 fed.md / trace.json 和
   结果文件修改时间抄出来的，只在接口没给对应字段时用；后端补上 meta 之后这张表就不用了。 */

const FREE_AGENT = '自由 agent：放开让它带工具自己读全文、自己定怎么写';
const PKG_WRITE = '包里的写入 agent：代码里的循环 + 专用工具，自己转圈';
const PKG_ORGANIZE = '包里的整理 agent：代码里的循环 + 专用工具，自己转圈';
const BATCH = (n) => `不带工具直接调模型，每批 ${n} 条，带前文和已记的条目`;
const V1 = '第一版任务书';
const V2 = '第二版：短，一个事实一条';
const V3 = '第三版：长，一件事一条';
const old = (at, model, feed, rounds, prompt, more) => Object.assign({ at, model, feed, rounds, prompt }, more || {});

const OLD_RUNS = {
  'write-window1-last400~existing': old('11-11 20:42', 'DeepSeek flash', '手机上原来的老写法：每 20 条抽一次，只看这 20 条', '1 轮', '手机上原来那份',
    { note: '不是实验：是手机上已经存着的条目，拿来当对照。时间是导出来的时间。' }),
  'write-window1-last400~runDS': old('11-11 20:44', 'DeepSeek flash', FREE_AGENT, 'agent 自己定', V1),
  'write-window1-last400~runOpus': old('11-11 20:46', 'Opus', FREE_AGENT, 'agent 自己定', V1 + '（原文当时没单独存）'),
  'write-window1-last400~run2Sonnet': old('11-11 21:07', 'Sonnet', FREE_AGENT, 'agent 自己定', V2),
  'write-window1-last400~run2Opus': old('11-11 21:10', 'Opus', FREE_AGENT, 'agent 自己定', V2),
  'write-window1-last400~run2DS': old('11-11 21:11', 'DeepSeek flash', FREE_AGENT, 'agent 自己定', V2),
  'write-window1-last400~run3DS': old('11-11 21:24', 'DeepSeek flash', FREE_AGENT, 'agent 自己定', V3),
  'write-window1-last400~run3Opus': old('11-11 21:25', 'Opus', FREE_AGENT, 'agent 自己定', V3),
  'write-window1-last400~run3Sonnet': old('11-11 21:25', 'Sonnet', FREE_AGENT, 'agent 自己定', V3),
  'write-window1-last400~runW_DS': old('11-11 21:54', 'DeepSeek flash', PKG_WRITE, 'agent 转了 18 圈', '写在代码里', { in: 884160, out: 22174, sec: 156 }),
  'write-window1-last400~runW_Sonnet': old('11-11 21:55', 'Sonnet', PKG_WRITE, 'agent 转了 14 圈', '写在代码里', { in: 1027759, out: 25190, sec: 222 }),
  'write-window1-last400~runW2_Sonnet': old('11-11 22:11', 'Sonnet', PKG_WRITE + '（按事交）', 'agent 转了 8 圈', '写在代码里', { in: 450520, out: 11758, sec: 103 }),
  'write-window1-last400~runW2_DS': old('11-11 22:13', 'DeepSeek flash', PKG_WRITE + '（按事交）', 'agent 转了 18 圈', '写在代码里', { in: 1171099, out: 35084, sec: 236 }),
  'write-window1-last400~run3DS_files': old('11-11 22:14', 'DeepSeek flash', FREE_AGENT, 'agent 自己定', V3 + '（files 变体）'),
  'write-window1-last400~runP_DS': old('11-11 22:39', 'DeepSeek flash', '通用 agent 外壳（工作台）', 'agent 转了 24 圈', '写在代码里', { in: 1641189, out: 30556, sec: 204 }),
  'write-window1-last400~runP_Sonnet': old('11-11 22:39', 'Sonnet', '通用 agent 外壳（工作台）', 'agent 转了 15 圈', '写在代码里', { in: 1019620, out: 18055, sec: 182 }),
  'write-window1-last400~runS_DS': old('11-11 22:58', 'DeepSeek flash', '不带工具直接调模型，整段 400 条一次给', '2 轮（写完再核对）', V3, { in: 89716, out: 49156, sec: 274 }),
  'write-window1-last400~runB_DS': old('11-11 23:26', 'DeepSeek flash', BATCH(80), '2 轮（写完再核对）', V3, { in: 201340, out: 123191 }),
  'write-window1-last400~runB_DSdraft': old('11-11 23:26', 'DeepSeek flash', BATCH(80), '1 轮（同上那次核对之前的草稿）', V3, { in: 92038, out: 89035 }),
  'write-window1-last400~runB200_DS': old('11-11 23:42', 'DeepSeek flash', BATCH(200), '2 轮（写完再核对）', V3, { in: 114175, out: 62354 }),
  'write-window1-last400~runB200_DSdraft': old('11-11 23:42', 'DeepSeek flash', BATCH(200), '1 轮（同上那次核对之前的草稿）', V3,
    { in: 52558, out: 40678, note: '手机上现在的写法就是照这一次做的。' }),
  'write-window2-last400~runown_DS': old('11-12 14:16', 'DeepSeek flash', BATCH(200) + '（只带这个窗口自己的条目）', '1 轮', V3 + '（换了窗口名）', { in: 141905, out: 40862 }),
  'write-window2-last400~runcross_DS': old('11-12 14:19', 'DeepSeek flash', BATCH(200) + '，另带窗口 1 写出来的 19 条', '1 轮', V3 + '（换了窗口名）', { in: 147221, out: 37794 }),
  'write-window4-last400~runown_DS': old('11-12 14:24', 'DeepSeek flash', BATCH(200) + '（只带这个窗口自己的条目）', '1 轮', V3 + '（换了窗口名）', { in: 49840, out: 53686 }),
  'write-window4-last400~runcross_DS': old('11-12 14:27', 'DeepSeek flash', BATCH(200) + '，另带窗口 1 写出来的 19 条', '1 轮', V3 + '（换了窗口名）', { in: 54048, out: 26169 }),
  'agent-runA1': old('11-11 17:31', '没记下', FREE_AGENT, 'agent 自己定', '第一版整理任务'),
  'agent-runA2': old('11-11 17:31', '没记下', FREE_AGENT, 'agent 自己定', '第一版整理任务'),
  'agent-runDS': old('11-11 17:50', 'DeepSeek flash', FREE_AGENT, 'agent 自己定', '第一版整理任务'),
  'agent-runHaiku': old('11-11 17:50', 'Haiku', FREE_AGENT, 'agent 自己定', '第一版整理任务'),
  'agent-runP_DS': old('11-11 19:11', 'DeepSeek flash', PKG_ORGANIZE, 'agent 转了 32 圈', '写在代码里（第 1 版）', { in: 1839366, out: 41406, sec: 237 }),
  'agent-runP_Haiku': old('11-11 19:18', 'Haiku', PKG_ORGANIZE, 'agent 转了 20 圈', '写在代码里（第 1 版）', { in: 876492, out: 65977, sec: 367 }),
  'agent-runP_Opus': old('11-11 19:20', 'Opus', PKG_ORGANIZE, 'agent 转了 42 圈', '写在代码里（第 1 版）', { in: 5308714, out: 72348, sec: 932 }),
  'agent-run2_DS': old('11-11 20:13', 'DeepSeek flash', PKG_ORGANIZE, 'agent 转了 48 圈', '写在代码里（第 2 版）', { in: 1819087, out: 43544, sec: 264 }),
  'agent-run3_DS': old('11-11 20:20', 'DeepSeek flash', PKG_ORGANIZE, 'agent 转了 47 圈', '写在代码里（第 3 版）', { in: 2465597, out: 49026, sec: 270 }),
  'agent-run4_DS': old('11-11 20:25', 'DeepSeek flash', PKG_ORGANIZE, 'agent 转了 45 圈', '写在代码里（第 4 版）', { in: 2392983, out: 51332, sec: 279 }),
  'agent-run2_Sonnet': old('11-11 20:26', 'Sonnet', PKG_ORGANIZE, 'agent 转了 49 圈', '写在代码里（第 2 版）', { in: 2769568, out: 122721, sec: 1052 }),
};

const MERGE_FEED = '程序：先一批批给每条下结论（Keep / Rewrite / Drop / Unsure），再把说同一件事的并起来；每次调用不带工具';

function prettyModel(id) {
  if (!id) return '没记下';
  const text = String(id);
  if (text === 'deepseek-flash') return 'DeepSeek flash';
  const claude = text.match(/^claude-([a-z]+)-(\d+)-(\d+)/i);
  if (claude) return claude[1][0].toUpperCase() + claude[1].slice(1) + ' ' + claude[2] + '.' + claude[3];
  return text;
}

/* 文字里夹着的模型代号换成人话（调用记录的标签里有） */
function prettyModels(text) {
  return String(text || '').replace(/claude-[a-z]+-\d+-\d+(-\d{8})?|deepseek-flash/gi, (m) => prettyModel(m));
}

function modelFromCode(code) {
  if (/Opus/i.test(code)) return 'Opus';
  if (/Sonnet/i.test(code)) return 'Sonnet';
  if (/Haiku/i.test(code)) return 'Haiku';
  if (/DS|DeepSeek/.test(code)) return 'DeepSeek flash';
  return '没记下';
}

function materialName(name) {
  const material = name.slice('write-'.length).split('~')[0];
  const m = material.match(/^window(\d+)-last(\d+)$/);
  return m ? `窗口 ${m[1]} 的最后 ${m[2]} 条` : material;
}

function parseOldTime(text) {
  const [md, time] = text.split(' ');
  const [month, day] = md.split('-').map(Number);
  const [hour, minute] = time.split(':').map(Number);
  return new Date(2026, month - 1, day, hour, minute).getTime();
}

/* 实验做的是哪一类事：C2 写入 / C2 整理 / A2·A3 摘要 */
const KINDS = { write: 'C2 写入', organize: 'C2 整理', summary: 'A2 / A3 摘要' };
const kindChip = (group) => `<span class="chip k-${group}">${esc(KINDS[group] || group)}</span>`;

function oldItem(result) {
  const name = result.name;
  const info = OLD_RUNS[name];
  const isWrite = name.startsWith('write-');
  const isMerge = name.startsWith('merge-');
  const code = isWrite ? name.split('~')[1] : isMerge ? name.replace(/\.json$/, '') : name.slice('agent-'.length);
  let at = info ? parseOldTime(info.at) : null;
  let approx = Boolean(info);
  if (isMerge) {
    const stamp = name.match(/-(\d{10})\.json$/);
    if (stamp) { at = Number(stamp[1]) * 1000; approx = false; }
  }
  const material = isWrite ? materialName(name) : '手机上原来那批条目';
  return {
    key: name, source: isWrite ? 'write' : isMerge ? 'merge' : 'agent', group: isWrite ? 'write' : 'organize',
    what: isWrite ? (name.endsWith('~existing') ? '手机上原来的条目' : '') : '收拾原来那批条目',
    at, approx, code,
    model: info ? info.model : isMerge ? prettyModel(result.short) : modelFromCode(code),
    feed: info ? info.feed : isMerge ? MERGE_FEED : (result.row || '没记下'),
    rounds: info ? info.rounds : isMerge ? '先判再并' : '没记下',
    prompt: info ? info.prompt : '没记下',
    material, windowName: material,
    cards: result.kept, dropped: result.dropped, unsure: result.unsure,
    tokensIn: info ? info.in : null, tokensOut: info ? info.out : null, seconds: info ? info.sec : null,
    note: info ? info.note : '', existing: name.endsWith('~existing'),
  };
}

const STEP_NAMES = { a2: 'A2 上下文摘要', a3: 'A3 窗口总结', c2: 'C2 写入', verdict: 'C2 整理' };

function rangeOf(e) {
  const o = e.options || {};
  const from = (o.from || 0) + 1;
  const to = from + (e.ranMessages || o.limit || 0) - 1;
  return { from, to };
}

function materialOf(e) {
  const { from, to } = rangeOf(e);
  return `第 ${from}–${to} 条` + (e.totalMessages ? `（共 ${e.totalMessages} 条）` : '');
}

function expItem(e) {
  if (e.verdict) return verdictItem(e);
  const o = e.options || {};
  const steps = o.steps || [];
  const classic = o.writer === 'classic';
  const hasC2 = steps.includes('c2');
  const cards = e.fragments ? e.fragments.reduce((sum, batch) => sum + (batch.cards || []).length, 0) : (e.cards || 0);
  const { from, to } = rangeOf(e);
  const feed = [];
  if (hasC2) feed.push(classic ? `C2 老写法：每 ${o.fragmentEvery || 20} 条抽一次，只看这几条` : `C2 每批 ${o.wholeEvery || 200} 条，带前文和已记的条目（最后不够一批的满 10 条也写）`);
  if (steps.includes('a2')) feed.push(`A2 每段 ${o.segmentSize || 40} 条`);
  if (steps.includes('a3')) feed.push('A3 读这次写的 A2 段');
  return {
    key: 'exp:' + e.id, id: e.id, source: 'exp', group: hasC2 ? 'write' : 'summary', steps,
    what: steps.length ? steps.map((s) => STEP_NAMES[s] || s).join(' + ') : 'C2 写入',
    at: e.at, approx: false, code: String(e.id).slice(0, 8),
    model: prettyModel(e.model),
    feed: feed.join('；') || '—',
    rounds: !hasC2 ? '' : classic || (o.c2Rounds || 1) === 1 ? '1 轮' : `${o.c2Rounds} 轮（写完再核对）`,
    prompt: hasC2 ? (classic ? '老写法的提示词' : (o.c2PromptName || '手机上现在跑的')) : '现行的 A2 / A3 提示词',
    windowName: e.windowTitle || '（没标题）', conv: o.conversationId, from, to,
    material: materialOf(e),
    cards, segments: (e.segments || []).length, hasSummary: Boolean(e.summary), dropped: 0, unsure: 0,
    tokensIn: e.inputTokens, tokensOut: e.outputTokens, calls: e.calls,
    seconds: e.finishedAt && e.at ? Math.round((e.finishedAt - e.at) / 1000) : null,
    status: e.status, progress: e.progress, note: e.note || '',
  };
}

/* C2 整理那种实验：列表里的一行 */
function verdictItem(e) {
  const v = e.verdict;
  const o = e.options || {};
  const fed = `新条目 ${v.newCards.length} 条 · 原文 ${v.lines} 条 · 带了已有的 ${v.existing.length} 条、她删过的 ${v.deleted.length} 条（池子里共 ${v.pool.length} 条）`
    + ` · 聊天时带着的内容 ${v.residentChars} 字${v.residentCut ? '（裁掉 ' + v.residentCut + ' 字）' : ''}`
    + (v.existingWhole == null ? '' : v.existingWhole ? ' · 已有的是整池全给' : ' · 已有的是挑出来的')
    + (v.wikiPages ? ` · wiki 页 ${v.wikiPages} 页${v.wikiCut ? '（没放进去 ' + v.wikiCut + ' 字）' : ''}` : '');
  const { from, to } = rangeOf(e);
  return {
    key: 'exp:' + e.id, id: e.id, source: 'exp', group: 'organize', verdict: true,
    what: v.name || '', at: e.at, approx: false, code: String(e.id).slice(0, 8),
    model: (e.model || '').split(' · ').map((part) => { const [id, times] = part.split('×'); return prettyModel(id) + (times ? ' ×' + times : ''); }).join(' · '),
    feed: '一次调用、不带工具：' + fed,
    rounds: v.judged && v.judged.length ? '跑完请裁判逐条判了' : '',
    prompt: 'C2 整理的提示词（写在包里）',
    windowName: e.windowTitle || '（没标题）', conv: o.conversationId, from, to,
    material: `${v.lines} 条原文`,
    cards: v.newCards.length, dropped: 0, unsure: 0, runs: (v.runs || []).length,
    tokensIn: e.inputTokens, tokensOut: e.outputTokens, calls: e.calls,
    seconds: e.finishedAt && e.at ? Math.round((e.finishedAt - e.at) / 1000) : null,
    status: e.status, progress: e.progress, note: e.note || '',
  };
}

async function loadRuns() {
  const [exps, results] = await Promise.all([api('/api/experiments'), api('/api/c2/results')]);
  const rows = exps.experiments || [];
  const details = await Promise.all(rows.map((row) => api('/api/experiments/' + encodeURIComponent(row.id)).catch(() => null)));
  const items = rows.map((row, index) => expItem(details[index] || row));
  for (const result of results.results || []) items.push(oldItem(result));
  items.sort((a, b) => (b.at || 0) - (a.at || 0));
  state.runs.items = items;
  return items;
}

function findItem(key) {
  return (state.runs.items || []).find((item) => item.key === key);
}

function stopPolling() {
  if (state.runs.timer) { clearTimeout(state.runs.timer); state.runs.timer = null; }
}

/* ---------------- 实验记录：列表 ---------------- */

function onList() {
  const params = new URLSearchParams(location.search);
  return state.tab === 'runs' && !params.get('open') && !params.get('compare');
}

async function showRunList() {
  stopPolling();
  document.body.classList.remove('wide');
  state.runs.open = null;
  const page = $('page-runs');
  if (state.runs.items) renderRunList();
  else page.innerHTML = '<div class="card"><span class="spinner"></span>读实验记录…</div>';
  try {
    await loadRuns();
    if (onList()) renderRunList();
    if ((state.runs.items || []).some((item) => item.status === 'running')) {
      state.runs.timer = setTimeout(() => { if (onList()) showRunList(); }, 5000);
    }
  } catch (error) {
    page.innerHTML = '<div class="card error">读不了：' + esc(error.message) + '</div>';
  }
}

/* 结果的数，用这一类事自己的单位 */
function countHtml(item) {
  if (item.status === 'running') return `<span class="spinner"></span><span class="muted">在跑 ${esc(item.progress || '')}</span>`;
  if (item.status && item.status !== 'done') return `<span class="error">${esc(item.status)}</span>`;
  const cost = item.tokensIn != null ? `<div class="faint">${tokens(item.tokensIn + (item.tokensOut || 0))} token${item.calls ? ' · ' + item.calls + ' 次调用' : ''}</div>` : '<div class="faint">token 没记</div>';
  if (item.verdict) return `<b>${item.cards}</b> 条新条目<div class="muted">下了 ${item.runs} 次结论</div>` + cost;
  if (item.group === 'organize') {
    return `<b>${item.cards}</b> 条 Keep<div class="muted">Drop ${item.dropped}${item.unsure ? ' · Unsure ' + item.unsure : ''}</div>` + cost;
  }
  if (item.group === 'summary') {
    return `<b>${item.segments}</b> 段 A2${item.hasSummary ? '<div class="muted">+ A3 一份</div>' : ''}` + cost;
  }
  const extra = item.segments ? `<div class="muted">+ A2 ${item.segments} 段${item.hasSummary ? ' + A3' : ''}</div>` : '';
  return `<b>${item.cards}</b> 条记忆条目${extra}` + cost;
}

function runRowHtml(item) {
  const picked = state.runs.picked.includes(item.key);
  const sub = item.source === 'exp' ? `${item.windowName} · ${item.material}` : item.material;
  const how = [item.prompt && item.prompt !== '没记下' ? '提示词：' + item.prompt : '', item.rounds && item.rounds !== '没记下' ? item.rounds : ''].filter(Boolean).join(' · ');
  return `<div class="runrow${picked ? ' picked' : ''}" data-open="${esc(item.key)}">
    <div><input type="checkbox" data-pick="${esc(item.key)}" ${picked ? 'checked' : ''} title="勾两三次来并排看"></div>
    <div class="time">${item.at ? hm(item.at) : '—'}${item.approx ? '<span class="approx" title="老实验没存时间，这是结果文件的修改时间">约</span>' : ''}</div>
    <div><div class="title">${kindChip(item.group)}<span>${esc(item.model)}</span>${item.what && item.source !== 'exp' ? '<span class="muted">' + esc(item.what) + '</span>' : ''}${item.verdict && item.what ? '<span class="muted" style="font-weight:400">' + esc(item.what) + '</span>' : ''}${item.existing ? '<span class="chip off">对照</span>' : ''}</div>
      <div>${esc(sub)}</div>
      ${how ? `<div class="faint">${esc(how)}</div>` : ''}</div>
    <div class="num">${countHtml(item)}</div>
  </div>`;
}

function pickBarHtml() {
  const picked = state.runs.picked;
  if (!picked.length) return '';
  const names = picked.map((key) => findItem(key)).filter(Boolean)
    .map((item) => `${item.at ? hm(item.at) : ''} ${KINDS[item.group]} ${item.model}`).join('、');
  return `<div class="pickbar"><span>已选 ${picked.length} 次（最多 3 次）：${esc(names)}</span>
    <button class="primary" id="pick-go" ${picked.length < 2 ? 'disabled' : ''}>并排看</button>
    <button class="ghost" id="pick-clear">清空</button></div>`;
}

function wirePickBar() {
  if ($('pick-go')) $('pick-go').onclick = () => go({ tab: 'runs', compare: state.runs.picked.join(',') });
  if ($('pick-clear')) $('pick-clear').onclick = () => { state.runs.picked = []; rerenderRuns(); };
}

function rerenderRuns() {
  if (state.runs.open) renderRunDetail(); else renderRunList();
}

function togglePick(key) {
  const picked = state.runs.picked;
  const at = picked.indexOf(key);
  if (at >= 0) picked.splice(at, 1);
  else { if (picked.length >= 3) picked.shift(); picked.push(key); }
}

function renderRunList() {
  const runs = state.runs;
  const page = $('page-runs');
  const all = runs.items || [];
  const ofKind = all.filter((item) => runs.filter === 'all' || item.group === runs.filter);
  const windows = [...new Set(ofKind.map((item) => item.windowName).filter(Boolean))];
  if (runs.window && !windows.includes(runs.window)) runs.window = '';
  const shown = ofKind.filter((item) => !runs.window || item.windowName === runs.window);
  const chip = (id, label, n) => `<button class="ghost${runs.filter === id ? ' on' : ''}" data-filter="${id}">${label} <span class="faint">${n}</span></button>`;
  const count = (group) => all.filter((i) => i.group === group).length;
  let html = `<div class="card"><div class="row"><h2>实验记录</h2><button class="primary" id="go-new">跑一次新的</button></div>
    <div class="filters" style="margin-top:8px">${chip('all', '全部', all.length)}${chip('write', KINDS.write, count('write'))}${chip('organize', KINDS.organize, count('organize'))}${chip('summary', KINDS.summary, count('summary'))}
    ${windows.length > 1 ? `<select class="text" id="win-filter"><option value="">所有材料（${windows.length} 个窗口）</option>${windows.map((w) => `<option value="${esc(w)}"${w === runs.window ? ' selected' : ''}>${esc(w)}</option>`).join('')}</select>` : ''}</div></div>`;
  html += '<div class="card">';
  let lastDay = null;
  for (const item of shown) {
    const day = item.at ? dayName(item.at) : '没记时间';
    if (day !== lastDay) { html += `<div class="day">${esc(day)}</div>`; lastDay = day; }
    html += runRowHtml(item);
  }
  if (!shown.length) html += '<div class="muted">没有。</div>';
  html += '</div>' + pickBarHtml();
  page.innerHTML = html;
  $('go-new').onclick = () => go({ tab: 'new' });
  page.querySelectorAll('[data-filter]').forEach((button) => {
    button.onclick = () => { runs.filter = button.dataset.filter; renderRunList(); };
  });
  if ($('win-filter')) $('win-filter').onchange = (event) => { runs.window = event.target.value; renderRunList(); };
  page.querySelectorAll('[data-pick]').forEach((box) => {
    box.onclick = (event) => { event.stopPropagation(); togglePick(box.dataset.pick); renderRunList(); };
  });
  page.querySelectorAll('[data-open]').forEach((row) => {
    row.onclick = () => go({ tab: 'runs', open: row.dataset.open });
  });
  wirePickBar();
}

/* ---------------- 一次实验：数据统一成一个形状 ---------------- */

const MARK_NAMES = { fact: '事实', instruction: '给克克的做法', preference: '偏好', said: '原话里说了', assistant: '助手那边说的', inferred: '推出来的', volatile: '会变' };

/* 不管哪种存法，都整理成：条目（带出处编号就带）、给 wiki 的段落、整理的 Drop / Unsure、喂了什么 */
async function loadRunData(item) {
  if (item.source === 'exp') {
    const raw = await api('/api/experiments/' + encodeURIComponent(item.id));
    const fresh = expItem(raw);
    Object.assign(item, fresh);
    const cards = (raw.fragments || []).flatMap((batch) => (batch.cards || []).map(expCard));
    return { raw, cards, notes: [], prompt: await expPrompt(raw) };
  }
  const raw = await api('/api/c2/review/' + encodeURIComponent(item.key));
  const marks = (row) => row.marks || [];
  const toCard = (row) => ({
    text: row.content, title: row.subject, msg: null, key: row.key, source: row.source, from: row.from, why: row.why,
    way: marks(row).includes('instruction'),
    meta: [marks(row).filter((m) => m !== '给 wiki').map((m) => MARK_NAMES[m] || m).join(' · '),
      row.confidence != null ? '把握 ' + Math.round(row.confidence * 100) + '%' : '', row.since ? '自 ' + row.since : ''].filter(Boolean).join(' · '),
  });
  const cards = raw.kept.filter((row) => !marks(row).includes('给 wiki')).map(toCard);
  const notes = raw.kept.filter((row) => marks(row).includes('给 wiki')).map(toCard);
  return { raw, cards, notes, fed: parseFed(raw.fed || '') };
}

function expCard(card) {
  return { text: card.content, title: card.subject, msg: card.message,
    meta: [card.speaker, MARK_NAMES[card.category] || card.category, (card.tags || []).join(' / '), card.importance != null ? '重要度 ' + card.importance : '',
      card.confidence == null ? '' : '把握 ' + card.confidence, card.day ? '自 ' + card.day : ''].filter(Boolean).join(' · ') };
}

/* 老实验目录里的 fed.md：开头一句「形式：…」说怎么喂，有「## 任务书」就是提示词全文 */
function parseFed(text) {
  if (!text) return null;
  const how = (text.split('\n').find((line) => line.startsWith('形式：')) || '').replace(/^形式：/, '');
  const hasPrompt = /^## 任务书/m.test(text);
  return { how, hasPrompt, text };
}

async function expPrompt(raw) {
  const o = raw.options || {};
  if (raw.verdict) {
    try {
      const body = await api('/api/c2/verdict/prompt');
      return { text: body.text, note: '固定的那段说明，{u} {c} 跑的时候换成称呼；后面还接着「聊天时本来就带着的内容」。当时实际喂的全文在每次调用里。' };
    } catch (_) { return { missing: '读不到' }; }
  }
  if (!(o.steps || []).includes('c2')) return { missing: 'A2 / A3 的提示词每段现生成，全文在每次调用里' };
  if (o.writer === 'classic') return { missing: '老写法的提示词写在代码里；全文在每次调用里' };
  if (o.c2Prompt) return { text: o.c2Prompt, note: '跑的时候 {u} {c} {窗口名} {起} {止} 换成称呼、窗口名和日期；换好之后的全文在每次调用里。' };
  if (state.runs.appPrompt == null) {
    try {
      const body = await api('/api/c2/prompts');
      const found = (body.prompts || []).find((p) => p.id === 'app');
      state.runs.appPrompt = found ? found.text : '';
    } catch (_) { state.runs.appPrompt = ''; }
  }
  return state.runs.appPrompt
    ? { text: state.runs.appPrompt, note: '「手机上现在跑的」那份，今天包里的版本；当时实际喂的全文在每次调用里。' }
    : { missing: '读不到手机上那份' };
}

function avgChars(cards) {
  return cards.length ? Math.round(cards.reduce((sum, card) => sum + (card.text || '').length, 0) / cards.length) : 0;
}

async function openRun(key) {
  stopPolling();
  const page = $('page-runs');
  if (!state.runs.open || state.runs.open.item.key !== key) {
    page.innerHTML = '<div class="card"><span class="spinner"></span>读这一次…</div>';
    state.runs.vfilter = 'all';
    state.runs.vopen = {};
  }
  try {
    if (!state.runs.items) await loadRuns();
    const item = findItem(key);
    if (!item) throw new Error('找不到这一次：' + key);
    const data = await loadRunData(item);
    state.runs.open = { item, data };
    renderRunDetail();
    if (item.source === 'exp' && data.raw.status === 'running') {
      state.runs.timer = setTimeout(() => {
        if (state.tab === 'runs' && new URLSearchParams(location.search).get('open') === key) openRun(key);
      }, 2500);
    }
  } catch (error) {
    page.innerHTML = '<div class="crumb"><a data-back>← 实验记录</a></div><div class="card error">读不了：' + esc(error.message) + '</div>';
    page.querySelector('[data-back]').onclick = () => go({ tab: 'runs' });
  }
}

/* ---------------- 一次实验：上面的概况 ---------------- */

function factsHtml(item, data) {
  const rows = [];
  if (item.source === 'exp') {
    const p = data.prompt;
    const promptCell = esc(item.prompt) + (p.text
      ? ` <details style="display:inline"><summary class="link" style="display:inline">看模板全文（${p.text.length} 字）</summary><div class="muted">${esc(p.note)}</div><pre style="max-height:560px">${esc(p.text)}</pre></details>`
      : `<div class="faint">${esc(p.missing || '')}</div>`);
    rows.push(['提示词', promptCell]);
  } else {
    const fed = data.fed;
    const promptCell = esc(item.prompt) + (fed && fed.hasPrompt
      ? ` <details style="display:inline"><summary class="link" style="display:inline">看全文（任务书 + 怎么拼的材料，${fed.text.length} 字）</summary><pre style="max-height:640px">${esc(fed.text)}</pre></details>`
      : ' ' + notSaved(item.existing ? '这是手机上原来的条目，不是实验' : /代码里/.test(item.prompt) ? '任务书写在代码里，当时没存下来' : '全文'));
    rows.push(['提示词', promptCell]);
  }
  let how = esc(item.feed);
  if (data.fed && data.fed.how) how += `<div class="faint">当时的记录：${esc(data.fed.how)}</div>`;
  rows.push(['怎么喂', how]);
  if (item.rounds && item.rounds !== '没记下') rows.push(['几轮', esc(item.rounds)]);
  const o = (data.raw && data.raw.options) || null;
  if (item.source === 'exp' && o && !data.raw.verdict) {
    rows.push(['称呼', `她 ${o.userName ? esc(o.userName) : '<span class="faint">空着</span>'} · 助手 ${o.assistantName ? esc(o.assistantName) : '<span class="faint">空着</span>'}`
      + ((o.steps || []).some((s) => s === 'a2' || s === 'a3') ? ` · 人设 ${o.persona ? o.persona.length + ' 字' : '<span class="faint">空着</span>'}` : '')]);
  }
  const cost = [];
  if (item.tokensIn != null) cost.push(`输入 ${tokens(item.tokensIn)} / 输出 ${tokens(item.tokensOut)} token`);
  if (item.calls) cost.push(`调了 ${item.calls} 次模型`);
  if (item.seconds) cost.push(duration(item.seconds));
  rows.push(['花了', cost.length ? esc(cost.join(' · ')) : notSaved('老实验接口没给 token')]);
  return '<dl class="facts">' + rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('') + '</dl>';
}

/* 同一个窗口、条数有重叠的别的实验：拿来并排比 */
function siblingsHtml(item) {
  const all = state.runs.items || [];
  const same = all.filter((other) => other.key !== item.key && (item.conv
    ? other.conv === item.conv && other.from <= item.to && item.from <= other.to
    : other.source !== 'exp' && other.material === item.material && other.group === item.group));
  if (!same.length) return '';
  const row = (other) => `<div class="sib">
      <span class="faint" style="width:120px">${esc(other.at ? (dayName(other.at).split(' · ')[0] + ' ' + hm(other.at)) : '—')}</span>
      ${kindChip(other.group)}
      <a class="link" data-open="${esc(other.key)}">${esc(other.model)}${other.source === 'exp' ? ' · ' + esc(other.material) : ''}${other.rounds && other.rounds !== '没记下' ? ' · ' + esc(other.rounds) : ''}</a>
      <button class="ghost" data-compare="${esc(other.key)}">和这次并排看</button></div>`;
  // 同一类事的排前面，其余按时间
  same.sort((a, b) => (b.group === item.group) - (a.group === item.group) || (b.at || 0) - (a.at || 0));
  const more = same.slice(4);
  return `<div class="siblings"><div class="muted" style="margin-bottom:4px">同一段材料的其他实验 · ${same.length}</div>${same.slice(0, 4).map(row).join('')}`
    + (more.length ? `<details><summary class="link" style="font-size:12.5px">还有 ${more.length} 次</summary>${more.map(row).join('')}</details>` : '') + '</div>';
}

/* ---------------- 一次实验：调用记录 ---------------- */

const CALL_STEP = { a2: 'A2 上下文摘要', a3: 'A3 窗口总结', c2: 'C2 写入', verdict: 'C2 整理', judge: '裁判' };

function callTitle(row) {
  const label = prettyModels(row.label).replace(/^(碎片|上下文摘要|窗口总结|裁判)\s*/, '');
  return `${CALL_STEP[row.step] || row.step}${label ? ' · ' + label : ''}`;
}

function callStats(row) {
  return `提示词 ${row.systemChars} 字 · 材料 ${row.userChars} 字 · 回了 ${row.replyChars} 字 · ${tokens(row.inputTokens)} / ${tokens(row.outputTokens)} token · ${row.seconds} 秒`;
}

/* 某一块结果是哪几次调用出的（按调用记录里的标签对上） */
function callsMatching(raw, test) {
  return (raw.callLog || []).filter(test).map((row) => row.n);
}

function callLink(ns, text) {
  if (!ns.length) return '';
  return `<a class="calllink" data-calls="${ns.join(',')}">${text || '喂了什么 · 回了什么'}${ns.length > 1 ? `（${ns.length} 次）` : ''} →</a>`;
}

function callListHtml(raw) {
  const rows = raw.callLog;
  if (!rows) return `<div class="card"><h3>每次调用</h3>${notSaved('这次是加调用记录之前跑的')}</div>`;
  if (!rows.length) return '<div class="card"><h3>每次调用</h3><span class="muted">还没调过模型。</span></div>';
  let html = `<div class="card"><h3>每次调用 · ${rows.length} 次</h3>`;
  const seen = {};
  for (const row of rows) {
    const again = seen[row.step + row.label];
    seen[row.step + row.label] = (again || 0) + 1;
    html += `<div class="callrow${state.drawer.id === raw.id && state.drawer.n === row.n ? ' on' : ''}" data-call="${row.n}">
      <span class="faint">第 ${row.n} 次</span>
      <span>${esc(callTitle(row))}${again ? ' <span class="faint">（同一块第 ' + (again + 1) + ' 次）</span>' : ''}${row.error ? '<div class="error">' + esc(row.error) + '</div>' : ''}</span>
      <span class="faint">${esc(callStats(row))}</span></div>`;
  }
  return html + '</div>';
}

/* ---------------- 一次调用：右侧抽屉，提示词 / 材料 / 原样回复 ---------------- */

const DRAWER_TABS = [['system', '提示词'], ['user', '喂进去的材料'], ['reply', '模型原样回的话']];

async function openDrawer(id, rows, n) {
  const d = state.drawer;
  d.id = id; d.rows = rows || []; d.n = Number(n);
  $('drawer').hidden = false;
  $('scrim').hidden = false;
  renderDrawer();
  markCallRows();
  const key = id + '#' + d.n;
  if (!d.cache[key]) {
    try { d.cache[key] = await api('/api/experiments/' + encodeURIComponent(id) + '/calls/' + d.n); }
    catch (error) { d.cache[key] = { failed: error.message }; }
    if (d.id === id && d.n === Number(n)) renderDrawer();
  }
}

function closeDrawer() {
  const d = state.drawer;
  if (!$('drawer') || $('drawer').hidden) return;
  d.n = null;
  $('drawer').hidden = true;
  $('scrim').hidden = true;
  markCallRows();
}

function markCallRows() {
  document.querySelectorAll('.callrow').forEach((row) => row.classList.toggle('on', state.drawer.n != null && Number(row.dataset.call) === state.drawer.n));
}

function stepDrawer(delta) {
  const d = state.drawer;
  const at = d.rows.findIndex((row) => row.n === d.n);
  const next = d.rows[at + delta];
  if (next) openDrawer(d.id, d.rows, next.n);
}

function renderDrawer() {
  const d = state.drawer;
  const row = d.rows.find((r) => r.n === d.n) || { n: d.n, step: '', label: '' };
  const at = d.rows.findIndex((r) => r.n === d.n);
  const call = d.cache[d.id + '#' + d.n];
  const tabs = DRAWER_TABS.map(([key, name]) => {
    const size = call && !call.failed ? `<span class="n">${(call[key] || '').length} 字</span>` : '';
    return `<button data-dtab="${key}" class="${d.tab === key ? 'on' : ''}">${name}${size}</button>`;
  }).join('');
  let body;
  if (!call) body = '<span class="spinner"></span>读这次调用…';
  else if (call.failed) body = '<div class="error">读不了：' + esc(call.failed) + '</div>';
  else {
    body = (call.error && d.tab === 'reply' ? `<div class="error" style="margin-bottom:8px">${esc(call.error)}</div>` : '')
      + `<pre>${esc(call[d.tab] || '（空）')}</pre>`;
  }
  $('drawer').innerHTML = `<div class="dhead"><div class="row"><div><div class="faint">第 ${d.n} 次调用，共 ${d.rows.length} 次</div>
      <h3 style="margin:2px 0 0">${esc(callTitle(row))}</h3></div>
      <div style="white-space:nowrap"><button class="ghost" id="d-prev" ${at <= 0 ? 'disabled' : ''}>← 上一次</button>
      <button class="ghost" id="d-next" ${at < 0 || at >= d.rows.length - 1 ? 'disabled' : ''}>下一次 →</button>
      <button class="ghost" id="d-close">关</button></div></div>
      ${row.systemChars != null ? `<div class="faint" style="margin-top:4px">${esc(callStats(row))}</div>` : ''}</div>
    <div class="dtabs">${tabs}<span class="spacer"></span><button class="ghost" id="d-copy">复制这一栏</button></div>
    <div class="dbody">${body}</div>`;
  $('d-close').onclick = closeDrawer;
  $('d-prev').onclick = () => stepDrawer(-1);
  $('d-next').onclick = () => stepDrawer(1);
  $('d-copy').onclick = async () => {
    try { await navigator.clipboard.writeText((call && call[d.tab]) || ''); $('d-copy').textContent = '复制好了'; }
    catch (_) { $('d-copy').textContent = '复制不了'; }
  };
  $('drawer').querySelectorAll('[data-dtab]').forEach((button) => {
    button.onclick = () => { d.tab = button.dataset.dtab; renderDrawer(); };
  });
}

/* ---------------- 一次实验：结果 ---------------- */

function cardHtml(card) {
  let html = `<div class="kcard">${card.title ? `<strong>${esc(card.title)}</strong> · ` : ''}${esc(card.text)}`;
  const meta = [card.msg != null ? '出自第 ' + card.msg + ' 条' : '', card.meta].filter(Boolean).join(' · ');
  if (meta) html += `<div class="meta">${esc(meta)}</div>`;
  if (card.why) html += `<div class="meta">模型说：${esc(card.why)}</div>`;
  const from = card.from || [];
  if (from.length > 1) {
    html += `<details><summary class="meta">由 ${from.length} 条并成，点开看原来的条目和出处</summary>`
      + from.map((piece) => `<div style="margin-top:6px">· ${esc(piece.content)}</div><div class="source">${esc(piece.source || '（找不到出处）')}</div>`).join('') + '</details>';
  } else {
    const source = from.length === 1 ? from[0].source : card.source;
    if (source) html += `<details><summary class="meta">看出处原文</summary><div class="source">${esc(source)}</div></details>`;
  }
  return html + '</div>';
}

/* 收拾原来那批条目：她可以一条条点 Keep / Drop */
function reviewRowHtml(card, verdicts) {
  const mine = verdicts[card.key];
  const button = (verdict, label) => `<button class="${mine === verdict ? 'primary' : 'ghost'}" data-mark="${esc(card.key)}" data-verdict="${verdict}">${label}</button>`;
  return `<div class="row" data-row="${esc(card.key)}" style="align-items:flex-start"><div style="flex:1;min-width:0">${cardHtml(card)}</div>
    <div style="white-space:nowrap;padding-top:8px">${button('keep', 'Keep')} ${button('drop', 'Drop')}</div></div>`;
}

function reviewCount(verdicts) {
  const values = Object.values(verdicts);
  return `你点过 ${values.length} 条：Keep ${values.filter((v) => v === 'keep').length} · Drop ${values.filter((v) => v === 'drop').length}`;
}

async function markReview(key, verdict) {
  const { item, data } = state.runs.open;
  const verdicts = data.raw.verdicts;
  const next = verdicts[key] === verdict ? '' : verdict;
  try {
    await api('/api/c2/review', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: item.key, key, verdict: next }),
    });
    if (next) verdicts[key] = next; else delete verdicts[key];
    renderRunDetail();
  } catch (error) {
    setStatus('没记上：' + error.message, true);
  }
}

function section(title, note, inner, open) {
  return `<div class="card"><details ${open ? 'open' : ''}><summary><strong>${title}</strong> <span class="muted">${note}</span></summary>${inner}</details></div>`;
}

const VERDICT_NAMES = { keep: 'Keep', drop: 'Drop', merge: 'Merge', rewrite: 'Rewrite', unsure: 'Unsure' };
const REASON_NAMES = { unsupported: '原文不支持', not_fact: '不值得长期记', in_prompt: '提示词里已有', in_archive: '档案里已有', in_wiki: 'wiki 页里已有', deleted: '她删过' };
const SIGNAL_NAMES = { notSaid: '不是她亲口说的', citedOther: '标的是她说的、出处却是对方的话', changesExisting: '会改一条已有的', rewritten: '改写过', crossWindow: '并进了别的窗口的条目' };

const vChip = (action, extra) => `<span class="v v-${esc(action)}"${extra ? ` title="${esc(extra)}"` : ''}>${esc(VERDICT_NAMES[action] || action || '—')}</span>`;

/* 一个结论写成一行人话 */
function verdictLine(v, poolById) {
  let text = '';
  if (v.action === 'drop') text = REASON_NAMES[v.reason] || '没写理由';
  if (v.action === 'merge') text = v.text ? '并进已有的那条，把它改成：' + v.text : '已有的那条说全了，不改';
  if (v.action === 'rewrite') text = '改成：' + (v.text || '') + (v.origin ? '（谁说的改成 ' + v.origin + '）' : '');
  if (v.downgraded) text += (text ? '；' : '') + '模型交的是 ' + (VERDICT_NAMES[v.modelAction] || '看不懂的结论') + '，因为' + v.downgraded + '，代码改成了 Unsure' + (v.text ? '；它想写成：' + v.text : '');
  const ref = v.ref && poolById[v.ref];
  return { text, ref: ref ? (ref.subject ? ref.subject + ' · ' : '') + ref.content : (v.reason === 'in_wiki' && v.ref ? String(v.ref) : '') };
}

function verdictTally(run) {
  const count = {};
  for (const v of run.verdicts || []) count[v.action] = (count[v.action] || 0) + 1;
  return count;
}

const runName = (run) => `${prettyModel(run.model)} · 第 ${run.n} 次`;
const isControl = (run) => String(run.model || '').startsWith('（');

function verdictModel(raw) {
  const v = raw.verdict;
  const poolById = {};
  for (const card of v.pool || []) poolById[card.id] = card;
  const runs = v.runs || [];
  const judgedOf = (run) => (v.judged || []).find((j) => j.model === run.model && j.n === run.n);
  const cards = v.newCards.map((card, index) => {
    const per = runs.map((run) => {
      const found = (run.verdicts || []).find((x) => x.card === card.id);
      const judged = judgedOf(run);
      const ruling = judged && (judged.rulings || []).find((r) => r.card === card.id);
      return { run, found, ruling };
    });
    const actions = new Set(per.filter((p) => p.found && !isControl(p.run)).map((p) => p.found.action));
    return {
      card, index, per,
      split: actions.size > 1,
      unsure: per.some((p) => p.found && p.found.action === 'unsure'),
      judgedNo: per.some((p) => p.ruling && !p.ruling.ok),
    };
  });
  return { v, poolById, runs, judgedOf, cards };
}

function verdictCardDetail(m, row) {
  const { v, poolById } = m;
  const card = row.card;
  let html = '';
  const hits = (v.hits || {})[card.id] || [];
  if (hits.length) {
    html += `<details><summary class="meta">喂模型时为这条捞到的 ${hits.length} 条</summary>` + hits.map((hit) => {
      const o = poolById[hit.id] || {};
      const marks = [o.isDeleted ? '她删过的' : '已有的', o.isProtected ? '带锁' : '', o.otherWindow ? '别的窗口' : ''].filter(Boolean).join(' · ');
      const judgedSame = v.related && !v.related.error && ((v.related.same || {})[card.id] || []).includes(hit.id);
      return `<div class="source">${esc(marks)}${judgedSame ? ' · 裁判认是同一件事' : ''}：${esc((o.subject ? o.subject + ' · ' : '') + (o.content || ''))}</div>`;
    }).join('') + '</details>';
  }
  const missed = v.related && !v.related.error ? ((v.related.same || {})[card.id] || []).filter((id) => !hits.some((hit) => hit.id === id)) : [];
  for (const id of missed) {
    const o = poolById[id] || {};
    html += `<div class="error" style="font-size:12.5px">裁判认是同一件事、但没捞到：${esc((o.subject ? o.subject + ' · ' : '') + (o.content || ''))}</div>`;
  }
  for (const p of row.per) {
    if (!p.found) continue;
    const line = verdictLine(p.found, poolById);
    const signals = ((p.run.signals || {})[card.id] || []).map((sig) => SIGNAL_NAMES[sig] || sig);
    html += `<div style="margin-top:8px"><b style="font-weight:500">${esc(runName(p.run))}</b> ${vChip(p.found.action)} ${esc(line.text)}`;
    if (line.ref) html += `<div class="source">${p.found.reason === 'deleted' ? '她删过的那条' : p.found.reason === 'in_wiki' ? 'wiki 那一页' : '已有的那条'}：${esc(line.ref)}</div>`;
    if (p.found.why) html += `<div class="meta">模型说：${esc(p.found.why)}</div>`;
    if (signals.length) html += `<div class="meta">代码看到的：${esc(signals.join('、'))}</div>`;
    if (p.ruling) html += `<div class="meta${p.ruling.ok ? '' : ' error'}">裁判：${p.ruling.ok ? '认可' : '不认可'}${p.ruling.should ? '，它认为该 ' + esc(VERDICT_NAMES[p.ruling.should] || p.ruling.should) : ''}${p.ruling.why ? ' —— ' + esc(p.ruling.why) : ''}</div>`;
    html += '</div>';
  }
  return html || '<span class="muted">没有结论。</span>';
}

function verdictHtml(raw) {
  const m = verdictModel(raw);
  const { v, runs, judgedOf } = m;
  const keys = Object.keys(VERDICT_NAMES);

  // 每一次下结论的账：一行一次
  let tally = `<table class="vt"><tr><th>这一次</th>${keys.map((k) => `<th style="text-align:center">${vChip(k)}</th>`).join('')}<th>裁判认可</th><th></th></tr>`;
  for (const run of runs) {
    const count = verdictTally(run);
    const judged = judgedOf(run);
    let judge = '<span class="faint">—</span>';
    if (judged) {
      const auto = (run.verdicts || []).filter((x) => x.action !== 'unsure').map((x) => x.card);
      const ok = (judged.rulings || []).filter((r) => r.ok && auto.includes(r.card)).length;
      judge = judged.error ? `<span class="error">${esc(judged.error)}</span>` : `${ok} / ${auto.length} <span class="faint">（${esc(prettyModel(judged.judge))}）</span>`;
    }
    const ns = callsMatching(raw, (r) => (r.step === 'verdict' && r.label === `${run.model} 第 ${run.n} 次`)
      || (r.step === 'judge' && r.label.includes(`判 ${run.model} 第 ${run.n} 次`)));
    const flags = [run.retried ? '<span class="chip warn">格式不对重问过一次</span>' : '', run.failed ? '<span class="chip warn">两次都不合格，全算 Unsure</span>' : '',
      run.error ? `<span class="error">${esc(run.error)}</span>` : ''].join(' ');
    tally += `<tr><td>${esc(runName(run))} ${flags}</td>${keys.map((k) => `<td class="num">${count[k] || '<span class="faint">·</span>'}</td>`).join('')}<td>${judge}</td><td style="text-align:right">${callLink(ns, '调用')}</td></tr>`;
  }
  tally += '</table>';
  if (v.related) {
    if (v.related.error) tally += `<div class="error" style="margin-top:8px">裁判找同一件事：${esc(v.related.error)}</div>`;
    else {
      const fed = new Set([...(v.existing || []), ...(v.deleted || [])]);
      let gold = 0, found = 0;
      const goldCards = new Set();
      for (const ids of Object.values(v.related.same || {})) for (const id of ids) { gold += 1; goldCards.add(id); if (fed.has(id)) found += 1; }
      const useful = [...fed].filter((id) => goldCards.has(id)).length;
      const ns = callsMatching(raw, (r) => r.step === 'judge' && /整池/.test(r.label));
      tally += `<div class="muted" style="margin-top:8px">捞旧条目：裁判（${esc(prettyModel(v.related.judge))}）对着整池 ${v.pool.length} 条找出 ${gold} 对「同一件事」，喂给模型的里面有 ${found} 对；喂进去的 ${fed.size} 条里，${useful} 条是裁判认的。 ${callLink(ns, '调用')}</div>`;
    }
  }

  // 逐条：一行一条新条目，每一次的结论排成列；点一行看理由
  const f = state.runs.vfilter;
  const pass = (row) => f === 'all' || (f === 'split' && row.split) || (f === 'unsure' && row.unsure) || (f === 'judge' && row.judgedNo);
  const n = (test) => m.cards.filter(test).length;
  const chip = (id, label, count) => `<button class="ghost${f === id ? ' on' : ''}" data-vfilter="${id}">${label} <span class="faint">${count}</span></button>`;
  let grid = `<div class="filters" style="margin-bottom:8px">${chip('all', '全部', m.cards.length)}${chip('split', '各次结论不一样', n((r) => r.split))}${chip('unsure', '有 Unsure', n((r) => r.unsure))}${chip('judge', '裁判不认可', n((r) => r.judgedNo))}</div>`;
  grid += `<table class="vt vgrid"><tr><th>新条目</th>${runs.map((run) => `<th class="runh">${esc(prettyModel(run.model))}<br><span class="faint">第 ${run.n} 次</span></th>`).join('')}</tr>`;
  for (const row of m.cards.filter(pass)) {
    const open = Boolean(state.runs.vopen[row.card.id]);
    const card = row.card;
    grid += `<tr class="vrow${open ? ' open' : ''}" data-vcard="${esc(card.id)}"><td class="vtext">${card.subject ? '<strong>' + esc(card.subject) + '</strong> · ' : ''}${esc(card.content)}
      <div class="meta muted">${esc([card.speaker, card.message ? '出自这批第 ' + card.message + ' 条' : ''].filter(Boolean).join(' · '))}</div></td>`
      + row.per.map((p) => `<td>${p.found ? vChip(p.found.action, p.found.action === 'drop' ? REASON_NAMES[p.found.reason] : p.found.why) : '<span class="faint">—</span>'}${p.ruling && !p.ruling.ok ? '<span class="judge-no">裁判不认可</span>' : ''}</td>`).join('')
      + '</tr>';
    if (open) grid += `<tr class="vdetail"><td colspan="${runs.length + 1}">${verdictCardDetail(m, row)}</td></tr>`;
  }
  grid += '</table>';
  return `<div class="card"><h3>每一次下结论的账</h3>${runs.length ? tally : '<div class="muted">还没跑完。</div>'}</div>`
    + `<div class="card"><h3>逐条看 · ${v.newCards.length} 条新条目</h3><div class="muted" style="margin-bottom:8px">点一行看每一次的理由、并进了哪条、裁判怎么说。</div>${grid}</div>`;
}

function segmentHtml(segment, heading, link) {
  let html = `<div class="seg"><div class="row"><strong>${esc(heading)}${segment.title ? ' · ' + esc(segment.title) : ''}</strong>
    <span><span class="muted">第 ${segment.from}–${segment.to} 条</span> ${link || ''}</span></div>`;
  if (segment.error) return html + `<div class="error">${esc(segment.error)}</div></div>`;
  html += `<div style="white-space:pre-wrap;margin-top:4px">${esc(segment.story)}</div>`;
  if (segment.quotes) html += `<div class="muted" style="white-space:pre-wrap;margin-top:4px">${esc(segment.quotes)}</div>`;
  if ((segment.keywords || []).length) html += `<div class="muted">关键词：${esc(segment.keywords.join('，'))}</div>`;
  if (segment.pending) html += `<div class="muted" style="white-space:pre-wrap">待续：${esc(segment.pending)}</div>`;
  for (const problem of segment.problems || []) html += `<div class="error">有问题：${esc(problem)}</div>`;
  return html + '</div>';
}

function outputHtml(item, data) {
  const raw = data.raw;
  if (item.source === 'exp' && raw.verdict) return verdictHtml(raw);
  if (item.source === 'exp') {
    let html = '';
    if ((raw.fragments || []).length) {
      let inner = '';
      for (const batch of raw.fragments) {
        const ns = callsMatching(raw, (r) => r.step === 'c2' && r.label.includes(`第 ${batch.from}–${batch.to} 条`));
        inner += `<div class="ghead"><span>第 ${batch.from}–${batch.to} 条 · ${(batch.cards || []).length} 条${batch.rejected ? ' · 拒收 ' + batch.rejected : ''}${batch.known == null ? '' : ' · 喂的时候带了已记的 ' + batch.known + ' 条、前文 ' + batch.before + ' 条'}${batch.tail ? ' · 最后一截' : ''}</span>${callLink(ns)}</div>`;
        if (batch.error) inner += `<div class="error">${esc(batch.error)}</div>`;
        inner += (batch.cards || []).map((card) => cardHtml(expCard(card))).join('');
        for (const reason of batch.rejectionReasons || []) inner += `<div class="error">拒收：${esc(reason)}</div>`;
      }
      html += `<div class="card"><h3>写出的记忆条目 · ${data.cards.length} 条 <span class="muted" style="font-weight:400">平均 ${avgChars(data.cards)} 字</span></h3>${inner}</div>`;
    } else if ((item.steps || []).includes('c2')) {
      html += `<div class="card"><h3>写出的记忆条目</h3><div class="muted">${raw.status === 'running' ? '还在跑。' : '一条都没写。'}</div></div>`;
    }
    if (raw.summary) {
      html += `<div class="card"><h3>A3 窗口总结</h3>${segmentHtml(raw.summary, '总结', callLink(callsMatching(raw, (r) => r.step === 'a3')))}</div>`;
    }
    if ((raw.segments || []).length) {
      const segs = raw.segments.map((s) => segmentHtml(s, '第 ' + s.index + ' 段',
        callLink(callsMatching(raw, (r) => r.step === 'a2' && new RegExp(`第 ${s.index} 段$`).test(r.label))))).join('');
      html += `<div class="card"><h3>A2 上下文摘要 · ${raw.segments.length} 段</h3>${segs}</div>`;
    } else if ((item.steps || []).includes('a2')) {
      html += `<div class="card"><h3>A2 上下文摘要</h3><div class="muted">${raw.status === 'running' ? '还在跑。' : '一段都没写。'}</div></div>`;
    }
    return html;
  }
  if (item.group === 'organize') {
    const verdicts = raw.verdicts || {};
    const unsure = raw.unsure.map((row) => Object.assign(cardOf(row), { key: row.key }));
    const dropped = raw.dropped.map((row) => Object.assign(cardOf(row), { key: row.key }));
    const list = (cards) => cards.map((card) => reviewRowHtml(card, verdicts)).join('');
    return `<div class="card"><div class="row"><h3 style="margin:0">原来 ${raw.total} 条 → Keep ${raw.kept.length} · Drop ${raw.dropped.length}${raw.unsure.length ? ' · Unsure ' + raw.unsure.length : ''}</h3><span class="muted">${reviewCount(verdicts)}</span></div>
      <div class="muted">点 Keep / Drop 记下你的判断，再点一次撤回。</div></div>`
      + (unsure.length ? section(`Unsure · ${unsure.length}`, '模型没把握', list(unsure), true) : '')
      + section(`Keep · ${data.cards.length}`, '说同一件事的已经并在一起', list(data.cards), true)
      + (dropped.length ? section(`Drop · ${dropped.length}`, '', list(dropped), false) : '');
  }
  const ways = data.cards.filter((card) => card.way);
  const facts = data.cards.filter((card) => !card.way);
  return section(`写出的记忆条目 · ${data.cards.length} 条`, (ways.length ? `事实 ${facts.length} 条 · 给克克的做法 ${ways.length} 条 · ` : '') + `平均 ${avgChars(data.cards)} 字`, facts.concat(ways).map(cardHtml).join(''), true)
    + (data.notes.length ? section(`给 wiki 的段落 · ${data.notes.length}`, '某件事现在是什么情况、为什么；点开看撑着它的条目', data.notes.map(cardHtml).join(''), false) : '')
    + `<div class="card"><h3>每次调用</h3>${notSaved('老实验只留了结果，没留每次调用')}</div>`;
}

function cardOf(row) {
  return { text: row.content, title: row.subject, msg: null, source: row.source, from: row.from, why: row.why, meta: '' };
}

function renderRunDetail() {
  const { item, data } = state.runs.open;
  const page = $('page-runs');
  document.body.classList.toggle('wide', Boolean(item.verdict));
  const picked = state.runs.picked.includes(item.key);
  const title = item.source === 'exp' ? `${item.windowName}` : item.material;
  let html = '<div class="crumb"><a data-back>← 实验记录</a></div>';
  html += `<div class="card"><div class="row" style="align-items:flex-start"><div>
      <div style="display:flex;gap:8px;align-items:center">${kindChip(item.group)}<span class="muted">${item.what && item.what !== KINDS[item.group] && item.what !== STEP_NAMES.a2 ? esc(item.what) : ''}</span></div>
      <h2 style="margin-top:6px">${esc(item.model)} · ${esc(title)}${item.source === 'exp' ? ' <span class="muted" style="font-size:14px;font-weight:400">' + esc(item.material) + '</span>' : ''}</h2>
      <div class="faint">${esc(longWhen(item.at))}${item.approx ? '（约，老实验没存时间）' : ''} · 代号 ${esc(item.code)}</div></div>
    <button class="ghost${picked ? ' on' : ''}" id="pick-this">${picked ? '已选来并排看' : '选来并排看'}</button></div>`;
  if (item.status === 'running') html += `<div style="margin-top:8px"><span class="spinner"></span>在跑：${esc(item.progress)}</div>`;
  if (item.status && item.status !== 'done' && item.status !== 'running') html += `<div class="error" style="margin-top:8px">${esc(item.status)}</div>`;
  if (item.note) html += `<div class="muted" style="margin-top:6px">${esc(item.note)}</div>`;
  html += factsHtml(item, data) + siblingsHtml(item) + '</div>';
  html += outputHtml(item, data);
  if (item.source === 'exp') html += callListHtml(data.raw);
  page.innerHTML = html + pickBarHtml();
  page.querySelector('[data-back]').onclick = () => go({ tab: 'runs' });
  $('pick-this').onclick = () => { togglePick(item.key); renderRunDetail(); };
  const rows = (data.raw && data.raw.callLog) || [];
  page.querySelectorAll('[data-call]').forEach((row) => { row.onclick = () => openDrawer(item.id, rows, row.dataset.call); });
  page.querySelectorAll('[data-calls]').forEach((link) => {
    link.onclick = (event) => { event.stopPropagation(); openDrawer(item.id, rows, link.dataset.calls.split(',')[0]); };
  });
  page.querySelectorAll('[data-open]').forEach((link) => { link.onclick = () => go({ tab: 'runs', open: link.dataset.open }); });
  page.querySelectorAll('[data-compare]').forEach((button) => { button.onclick = () => go({ tab: 'runs', compare: [item.key, button.dataset.compare].join(',') }); });
  page.querySelectorAll('[data-mark]').forEach((button) => { button.onclick = () => markReview(button.dataset.mark, button.dataset.verdict); });
  page.querySelectorAll('[data-vfilter]').forEach((button) => { button.onclick = () => { state.runs.vfilter = button.dataset.vfilter; renderRunDetail(); }; });
  page.querySelectorAll('[data-vcard]').forEach((row) => {
    row.onclick = () => { const id = row.dataset.vcard; state.runs.vopen[id] = !state.runs.vopen[id]; renderRunDetail(); };
  });
  wirePickBar();
}

/* ---------------- 并排看 ---------------- */

async function openCompare(keys) {
  stopPolling();
  state.runs.open = null;
  document.body.classList.add('wide');
  const page = $('page-runs');
  page.innerHTML = '<div class="card"><span class="spinner"></span>读这几次…</div>';
  try {
    if (!state.runs.items) await loadRuns();
    const items = keys.map(findItem).filter(Boolean);
    if (items.length < 2) throw new Error('要选两到三次');
    state.runs.picked = items.map((item) => item.key);
    const datas = await Promise.all(items.map(loadRunData));
    renderCompare(items, datas);
  } catch (error) {
    page.innerHTML = '<div class="crumb"><a data-back>← 实验记录</a></div><div class="card error">' + esc(error.message) + '</div>';
    page.querySelector('[data-back]').onclick = () => go({ tab: 'runs' });
  }
}

function compareStat(item, data) {
  if (item.verdict) {
    const runs = data.raw.verdict.runs || [];
    return runs.map((run) => {
      const count = verdictTally(run);
      return `<div class="muted">${esc(runName(run))}：${Object.keys(VERDICT_NAMES).filter((k) => count[k]).map((k) => VERDICT_NAMES[k] + ' ' + count[k]).join(' · ')}</div>`;
    }).join('');
  }
  if (item.group === 'summary') return `<div><b>${(data.raw.segments || []).length}</b> 段 A2${data.raw.summary ? ' + A3' : ''}</div>`;
  return `<div><b>${data.cards.length}</b> 条</div><div><b>${avgChars(data.cards)}</b> 字/条</div>`;
}

function compareHeadHtml(item, data) {
  const cost = item.tokensIn != null ? `${tokens(item.tokensIn)} / ${tokens(item.tokensOut)}` : '没记';
  const fed = item.source === 'exp'
    ? (data.prompt.text ? `<details><summary class="link">看提示词模板全文</summary><pre style="max-height:420px">${esc(data.prompt.text)}</pre></details>` : `<span class="faint">${esc(data.prompt.missing || '')}</span>`)
    : (data.fed && data.fed.hasPrompt ? `<details><summary class="link">看提示词全文</summary><pre style="max-height:420px">${esc(data.fed.text)}</pre></details>` : notSaved('提示词全文'));
  return `<div class="col"><div class="faint">${esc(longWhen(item.at))}${item.approx ? '（约）' : ''}</div>
    <h3 style="margin:4px 0;display:flex;gap:8px;align-items:center">${kindChip(item.group)}<a class="link" data-open="${esc(item.key)}">${esc(item.model)}</a></h3>
    <div>${esc(item.source === 'exp' ? item.windowName + ' · ' + item.material : item.material)}</div>
    <div class="muted">提示词：${esc(item.prompt)}${item.rounds && item.rounds !== '没记下' ? ' · ' + esc(item.rounds) : ''}</div>
    <div class="muted">怎么喂：${esc(item.feed)}</div>
    <div class="stat">${compareStat(item, data)}<div class="muted">token 输入 / 输出<br>${esc(cost)}</div></div>
    <div style="margin-top:6px">${fed}</div></div>`;
}

function renderCompare(items, datas) {
  const page = $('page-runs');
  const n = items.length;
  const groups = new Set(items.map((item) => item.group));
  const materials = new Set(items.map((item) => item.source === 'exp' ? item.conv + ':' + item.from + '-' + item.to : item.material));
  const wire = () => {
    page.querySelector('[data-back]').onclick = () => go({ tab: 'runs' });
    page.querySelectorAll('[data-open]').forEach((link) => { link.onclick = () => go({ tab: 'runs', open: link.dataset.open }); });
    page.querySelectorAll('[data-calls]').forEach((link) => {
      link.onclick = () => { const i = Number(link.dataset.col); openDrawer(items[i].id, datas[i].raw.callLog || [], link.dataset.calls.split(',')[0]); };
    });
  };
  const notes = [];
  if (groups.size > 1) notes.push('这几次做的不是同一类事。');
  if (materials.size > 1) notes.push('材料不完全一样。');
  let html = '<div class="crumb"><a data-back>← 实验记录</a></div>';
  html += `<div class="card"><h2>并排看 ${n} 次</h2>${notes.length ? '<div class="muted">' + notes.join(' ') + '</div>' : ''}</div>`;
  html += `<div class="cmp" style="--n:${n}">${items.map((item, i) => compareHeadHtml(item, datas[i])).join('')}</div>`;

  // A2：按段的条数范围对齐
  if ([...groups].every((g) => g === 'summary')) {
    const ranges = new Map();
    datas.forEach((data) => (data.raw.segments || []).forEach((s) => ranges.set(s.from + '-' + s.to, [s.from, s.to])));
    const sorted = [...ranges.values()].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    for (const [from, to] of sorted) {
      html += `<div class="bucket">第 ${from}–${to} 条</div><div class="cmp" style="--n:${n}">` + datas.map((data, i) => {
        const s = (data.raw.segments || []).find((x) => x.from === from && x.to === to);
        if (!s) return '<div class="col"><span class="faint">这一次没有这一段</span></div>';
        const ns = callsMatching(data.raw, (r) => r.step === 'a2' && new RegExp(`第 ${s.index} 段$`).test(r.label));
        return `<div class="col">${segmentHtml(s, '第 ' + s.index + ' 段', ns.length ? `<a class="calllink" data-col="${i}" data-calls="${ns.join(',')}">调用 →</a>` : '')}</div>`;
      }).join('') + '</div>';
    }
    if (datas.some((data) => data.raw.summary)) {
      html += `<div class="bucket">A3 窗口总结</div><div class="cmp" style="--n:${n}">`
        + datas.map((data) => `<div class="col">${data.raw.summary ? segmentHtml(data.raw.summary, '总结') : '<span class="faint">没有</span>'}</div>`).join('') + '</div>';
    }
    page.innerHTML = html;
    wire();
    return;
  }

  // C2 整理：同一条新条目在每一次实验里的结论
  if (items.every((item) => item.verdict)) {
    const models = datas.map((data) => verdictModel(data.raw));
    const keyOf = (card) => (card.subject || '') + '·' + card.content;
    const order = [];
    const seen = new Set();
    for (const m of models) for (const row of m.cards) { const k = keyOf(row.card); if (!seen.has(k)) { seen.add(k); order.push(row.card); } }
    html += `<div class="bucket">逐条看 · ${order.length} 条新条目</div>`;
    for (const card of order) {
      html += `<div class="card" style="padding:10px 14px;margin-bottom:8px"><div>${card.subject ? '<strong>' + esc(card.subject) + '</strong> · ' : ''}${esc(card.content)}</div><div class="cmp" style="--n:${n};margin-top:6px">`
        + models.map((m) => {
          const row = m.cards.find((r) => keyOf(r.card) === keyOf(card));
          if (!row) return '<div><span class="faint">这一次没有这条</span></div>';
          return '<div>' + row.per.map((p) => p.found ? `<div style="margin:2px 0"><span class="faint">${esc(runName(p.run))}</span> ${vChip(p.found.action)} <span class="muted">${esc(verdictLine(p.found, m.poolById).text)}</span></div>` : '').join('') + '</div>';
        }).join('') + '</div></div>';
    }
    page.innerHTML = html;
    wire();
    return;
  }

  // C2 写入：按出处的消息编号对齐
  const aligned = datas.every((data) => data.cards.length && data.cards.every((card) => card.msg != null));
  if (aligned) {
    const size = 20;
    const nums = datas.flatMap((data) => data.cards.map((card) => card.msg));
    const lo = Math.min(...nums);
    const hi = Math.max(...nums);
    for (let a = Math.floor((lo - 1) / size) * size + 1; a <= hi; a += size) {
      const b = a + size - 1;
      const cells = datas.map((data) => data.cards.filter((card) => card.msg >= a && card.msg <= b).sort((x, y) => x.msg - y.msg));
      if (cells.every((cell) => !cell.length)) continue;
      html += `<div class="bucket">出自第 ${a}–${b} 条</div><div class="cmp" style="--n:${n}">`
        + cells.map((cell) => `<div class="col">${cell.map(cardHtml).join('') || '<span class="faint">这一段没写</span>'}</div>`).join('') + '</div>';
    }
  } else {
    html += `<div class="bucket">写出的记忆条目${datas.some((data) => data.cards.some((card) => card.msg == null)) ? ' <span class="faint" style="font-weight:400">有的实验没存每条出自第几条，各列按自己写出来的先后排</span>' : ''}</div><div class="cmp" style="--n:${n}">`
      + datas.map((data) => {
        const cards = data.cards.slice();
        if (cards.every((card) => card.msg != null)) cards.sort((x, y) => x.msg - y.msg);
        return `<div class="col">${cards.map(cardHtml).join('') || '<span class="faint">一条都没有</span>'}</div>`;
      }).join('') + '</div>';
  }
  page.innerHTML = html;
  wire();
}

/* ---------------- 跑一次新的 ---------------- */

function labSetting(key, fallback) {
  try { const v = localStorage.getItem('memoryd.lab.' + key); return v == null ? fallback : v; } catch (_) { return fallback; }
}

function labSave(key, value) {
  try { localStorage.setItem('memoryd.lab.' + key, value); } catch (_) { /* 存不了就算了 */ }
}

async function loadLab() {
  const page = $('page-new');
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

function modelLine() {
  return state.lab.model
    ? `用 <b>${esc(prettyModel(state.lab.model))}</b> 跑；结果只存在电脑上这份副本里，不写回手机。`
    : '<span class="error">这个 memoryd 启动时没接模型，现在跑不了。</span>';
}

function renderLabList() {
  const lab = state.lab;
  const page = $('page-new');
  const filter = lab.filter.trim().toLowerCase();
  const rows = lab.conversations.filter((item) => !filter || (item.title || '').toLowerCase().includes(filter));
  const ran = new Set((state.runs.items || []).map((item) => item.conv).filter(Boolean));
  let html = '<div class="card"><h2>跑一次新的 · 挑一个对话</h2>'
    + `<div class="muted">${modelLine()}</div>`
    + `<div style="margin-top:10px"><input class="text" id="lab-filter" placeholder="按标题找对话" value="${esc(lab.filter)}"></div>`
    + `<div class="faint" style="margin-top:4px">${rows.length} / ${lab.conversations.length} 个对话，按最后聊的时间排</div></div><div class="card">`;
  for (const item of rows.slice(0, 300)) {
    const tags = [item.isCC ? '<span class="chip">CC</span>' : '', ran.has(item.id) ? '<span class="chip k-write">跑过实验</span>' : ''].join(' ');
    html += `<div class="entry click" data-conv="${esc(item.id)}"><span>${esc(item.title || '（没标题）')} ${tags}</span>
      <span class="count">${item.messages} 条 · 最后聊在 ${esc(when(item.updatedAt))}</span></div>`;
  }
  html += '</div>';
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
}

function renderLabForm() {
  const item = state.lab.picked;
  const page = $('page-new');
  const field = (id, label, value, hint) => `<div class="field"><b>${label}</b>
    <input class="text" id="${id}" value="${esc(value)}">${hint ? '<div class="faint">' + hint + '</div>' : ''}</div>`;
  const start = Math.max(item.messages - Math.min(item.messages, 400) + 1, 1);
  page.innerHTML = `<div class="crumb"><a id="lab-back">← 换一个对话</a></div><div class="card form">
    <h2>${esc(item.title || '（没标题）')}</h2>
    <div class="muted">共 ${item.messages} 条 · 最后聊在 ${esc(when(item.updatedAt))} · ${modelLine()}</div>

    <h3 style="margin-top:16px">跑哪几步</h3>
    <div><label><input type="checkbox" id="lab-c2" checked> C2 写入</label>
      <label style="margin-left:14px"><input type="checkbox" id="lab-a2"> A2 上下文摘要</label>
      <label style="margin-left:14px"><input type="checkbox" id="lab-a3"> A3 窗口总结</label></div>

    <h3>跑哪一段</h3>
    <div class="two">
      ${field('lab-from', '从第几条开始', String(start), '默认是最后 400 条')}
      ${field('lab-limit', '最多跑几条', String(Math.min(item.messages, 400)), '最多 3000')}
    </div>

    <div id="lab-c2-opts">
    <h3>C2 写入</h3>
    <div class="field"><b>提示词</b>
      <select class="text" id="lab-prompt-pick" style="width:auto"></select>
      <textarea class="text mono" id="lab-prompt" rows="14" style="margin-top:6px"></textarea>
      <div class="faint">这就是喂给模型的提示词全文，改过的会记成「（改过）」。{u} {c} {窗口名} {起} {止} 跑的时候换成称呼、窗口名和这一批的日期。</div></div>
    <div class="two">
      <div class="field"><b>写几轮</b>
        <select class="text" id="lab-rounds"><option value="1">只写一次</option><option value="2" selected>写完再核对一次（两轮）</option></select></div>
      ${field('lab-whole', '每批喂几条', labSetting('whole', '200'), '手机上是 200，连同前文和已记的条目一起给；最后不够一批的满 10 条也写')}
    </div>
    <div class="field"><label><input type="checkbox" id="lab-classic"> 改用老写法（每 20 条抽一次，只看这 20 条，不带前文和已记的条目）</label></div>
    </div>

    <div id="lab-summary-opts" hidden>
      <h3>A2 / A3</h3>
      ${field('lab-seg', 'A2 每段几条', labSetting('seg', '40'), '手机上是聊长了挤出视野才写一段，这里按固定条数切')}
      <div class="field"><b>人设</b>
        <textarea class="text" id="lab-persona" rows="4" placeholder="可以空着">${esc(labSetting('persona', ''))}</textarea></div>
    </div>

    <h3>称呼</h3>
    <div class="two">
      ${field('lab-user', '她的称呼', labSetting('user', ''), '空着 = 摘要里叫「对方」、条目里叫「用户」，和手机上没填时一样')}
      ${field('lab-char', '助手的名字', labSetting('char', ''), '')}
    </div>

    <div style="margin-top:18px"><button class="primary" id="lab-run" ${state.lab.model ? '' : 'disabled'}>跑</button> <span id="lab-estimate" class="muted"></span></div></div>`;
  $('lab-back').addEventListener('click', renderLabList);
  const estimate = () => {
    $('lab-summary-opts').hidden = !($('lab-a2').checked || $('lab-a3').checked);
    $('lab-c2-opts').hidden = !$('lab-c2').checked;
    const n = Math.min(Number($('lab-limit').value) || 0, item.messages);
    const a2 = $('lab-a2').checked ? Math.ceil(n / (Number($('lab-seg').value) || 40)) : 0;
    const every = $('lab-classic').checked ? 20 : (Number($('lab-whole').value) || 200);
    const c2 = $('lab-c2').checked ? Math.ceil(n / every) * (Number($('lab-rounds').value) || 1) : 0;
    $('lab-estimate').textContent = `大约调 ${a2 + ($('lab-a3').checked ? 1 : 0) + c2} 次模型（格式不对会多重写一次）`;
  };
  page.querySelectorAll('input, select').forEach((el) => el.addEventListener('input', estimate));
  estimate();
  api('/api/c2/prompts').then((body) => {
    const prompts = body.prompts || [];
    const pick = $('lab-prompt-pick');
    if (!pick) return;
    pick.innerHTML = prompts.map((p) => `<option value="${esc(p.id)}">${esc(p.name)}</option>`).join('');
    const show = () => { const found = prompts.find((p) => p.id === pick.value); $('lab-prompt').value = found ? found.text : ''; };
    pick.value = labSetting('prompt', 'app');
    if (!pick.value && prompts.length) pick.value = prompts[0].id;
    show();
    pick.addEventListener('change', show);
    state.lab.prompts = prompts;
  }).catch(() => { /* 读不到就用手机上那份 */ });
  $('lab-run').addEventListener('click', startExperiment);
}

async function startExperiment() {
  const item = state.lab.picked;
  labSave('user', $('lab-user').value);
  labSave('char', $('lab-char').value);
  labSave('persona', $('lab-persona').value);
  labSave('seg', $('lab-seg').value);
  labSave('whole', $('lab-whole').value);
  labSave('prompt', $('lab-prompt-pick').value);
  const preset = (state.lab.prompts || []).find((entry) => entry.id === $('lab-prompt-pick').value);
  const promptText = $('lab-prompt').value;
  const edited = preset && preset.text !== promptText;
  const steps = ['a2', 'a3', 'c2'].filter((step) => $('lab-' + step).checked);
  const body = {
    conversationId: item.id, userName: $('lab-user').value, assistantName: $('lab-char').value,
    persona: $('lab-persona').value, segmentSize: Number($('lab-seg').value) || 40,
    fragmentEvery: 20, wholeEvery: Number($('lab-whole').value) || 200, writer: $('lab-classic').checked ? 'classic' : 'whole',
    from: Math.max((Number($('lab-from').value) || 1) - 1, 0),
    limit: Number($('lab-limit').value) || 400, steps,
    c2Prompt: preset && preset.id === 'app' && !edited ? '' : promptText,
    c2PromptName: (preset ? preset.name : '自己写的') + (edited ? '（改过）' : ''),
    c2Rounds: Number($('lab-rounds').value) || 1,
  };
  try {
    const started = await api('/api/experiments/run', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    state.runs.items = null;
    go({ tab: 'runs', open: 'exp:' + started.id });
  } catch (error) {
    setStatus('跑不起来：' + error.message, true);
  }
}

/* ---------------- 虚构题集 ---------------- */

function renderSetsOrLoad() {
  state.run = null;
  if (!state.sets.length || state.benchRuns == null) loadSets(); else renderSets();
}

async function loadSets() {
  setStatus('读题集…');
  try {
    const [body, runs] = await Promise.all([api('/api/bench/sets'), api('/api/bench/runs').catch(() => ({ runs: [] }))]);
    state.sets = body.sets || [];
    state.benchRuns = runs.runs || [];
    setStatus('');
    renderSets();
  } catch (error) {
    setStatus('题集读取失败：' + error.message, true);
  }
}

function renderSets() {
  const page = $('page-bench');
  let html = '<div class="card"><h2>虚构题集</h2>'
    + '<div class="muted">人工标好「应记 / 不该记」的虚构考题，只用来确认功能跑得通；写得好不好以真对话上的实验为准。'
    + '要调模型的题集可以贴一版新提示词，和现在用的那版一起跑、并排出分。</div>'
    + '</div>';
  if (state.sets.length === 0) {
    html += '<div class="card muted">没有题集。</div>';
  }
  for (const set of state.sets) {
    const tag = set.runnable ? '<span class="chip k-write">能跑</span>' : `<span class="chip off">${set.needsModel ? '没接模型，跑不了' : '不能跑'}</span>`;
    const trial = set.needsModel && set.runnable
      ? `<div style="margin-top:8px"><textarea class="text mono" data-trial="${esc(set.id)}" rows="5" placeholder="试一版提示词（system）。空着 = 只跑现在用的那版。写入有 {{称呼}} {{我的名字}} {{日期}}；摘要有 {{人设块}} {{任务说明}} {{称呼}}">${esc(state.trial[set.id] || '')}</textarea></div>`
      : '';
    html += `<div class="set"><div style="flex:1">
      <div><strong>${esc(set.name)}</strong> ${tag}</div>
      <div class="muted">${set.caseCount} 道题 · ${set.needsModel ? '要调模型' : '不调模型'} · <span class="faint">代号 ${esc(set.id)} / ${esc(set.writer)}</span></div>${trial}
    </div><div><button class="primary" data-run="${esc(set.id)}" ${state.benchBusy || !set.runnable ? 'disabled' : ''}>跑一次</button></div></div>`;
  }
  if (state.benchBusy) html += '<div class="card"><span class="spinner"></span>跑中…</div>';
  const past = state.benchRuns || [];
  html += `<div class="card"><h3>以前跑过 · ${past.length}</h3>` + (past.length
    ? past.slice(0, 50).map((run) => `<div class="entry click" data-benchrun="${esc(run.id)}"><span>${esc((run.set && run.set.name) || run.id)}</span><span class="count">${esc(when(run.at))}</span></div>`).join('')
    : '<div class="muted">还没有。</div>') + '</div>';
  page.innerHTML = html;
  page.querySelectorAll('[data-run]').forEach((button) => {
    button.addEventListener('click', () => runSet(button.dataset.run));
  });
  page.querySelectorAll('[data-trial]').forEach((area) => {
    area.addEventListener('input', () => { state.trial[area.dataset.trial] = area.value; });
  });
  page.querySelectorAll('[data-benchrun]').forEach((row) => {
    row.addEventListener('click', () => go({ tab: 'bench', run: row.dataset.benchrun }));
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
    state.benchRuns = null;
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
  let html = '<div class="crumb"><a id="back-sets">← 虚构题集</a></div><div class="card">';
  html += `<div><h2>${esc(run.set.name)}</h2>
    <div class="muted">${esc(when(run.at))} · ${run.cells.length} 格 · ${esc(run.status)}</div></div>`;
  html += `<h3 style="margin-top:14px">${esc((run.scores && run.scores[0] && run.scores[0].mainName) || '主分')}</h3>`;
  html += `<div><span class="score">${pct(score)}</span>`;
  if (state.previous && state.previous.score != null && score != null) {
    const delta = score - state.previous.score;
    const sign = delta >= 0 ? '+' : '';
    html += ` <span class="delta ${delta >= 0 ? 'up' : 'down'}">${sign}${Math.round(delta * 100)} 个点，上一次 ${pct(state.previous.score)}</span>`;
  } else if (score != null) {
    html += ' <span class="muted">没有可比的上一次</span>';
  }
  html += '</div>';
  const stats = (run.recipes || []).map((recipe) => labelStats(run, state.currentSet, recipe.id)).filter(Boolean);
  if (stats.length > 0) {
    html += '<h3 style="margin-top:14px">按标签看（主分只算配上标签的条目，漏记不扣分，以这里为准）</h3>';
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
  html += '<h3 style="margin-top:14px">错例</h3>';
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

  html += '<h3 style="margin-top:14px">每道题写出了什么（点开看）</h3>';
  for (const cell of run.cells || []) {
    html += `<div class="cell click" data-cell="${esc(cell.id)}">
      <div class="row"><span>${esc(caseTitle(state.currentSet, cell.caseId))}</span>
      <span class="muted">${cell.error ? '<span class="error">' + esc(cell.error) + '</span>' : cell.items.length + ' 条 · ' + cell.ms + 'ms'}</span></div>
      <div class="muted">${esc(recipeName(run, cell.recipeId))} · ${esc(cell.modelId)}</div>
      <div class="receipt" hidden></div>
    </div>`;
  }
  html += '</div>';
  page.innerHTML = html;

  $('back-sets').addEventListener('click', () => { state.run = null; if (new URLSearchParams(location.search).get('run')) go({ tab: 'bench' }); else loadSets(); });
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
  /* 应记：有一条判「对」= 写到了；不该记：有一条判「错」= 写进去了（C2 逐条配、A2 逐标签判，两种都对得上） */
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

async function openBenchRun(runId) {
  try {
    state.run = await api('/api/bench/runs/' + encodeURIComponent(runId));
    state.currentSetId = state.run.set.id;
    state.currentSet = await api('/api/bench/sets/' + encodeURIComponent(state.run.set.id));
    state.previous = await findPrevious(state.run);
    renderRun();
  } catch (error) {
    setStatus('读这次跑失败：' + error.message, true);
    loadSets();
  }
}

/* ---------------- wiki ---------------- */

async function loadWikiIndex() {
  const page = $('page-wiki');
  page.innerHTML = '<div class="card"><span class="spinner"></span>读目录…</div>';
  try {
    const body = await api('/api/wiki/index');
    state.wikiTrail = [{ title: 'wiki', path: '' }];
    let html = '<div class="card"><h2>wiki</h2><div class="muted">这份副本里的 C3 wiki：分组 → 页 → 页里的条目。「读原文」看条目出自哪段对话（现在只有种子条目能读）。</div></div><div class="card">';
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
    if (body.kind) html += `<span class="chip">${esc(body.kind)}</span>`;
    if (body.hook) html += `<div class="muted">${esc(body.hook)}</div>`;
    if (body.validUntil) html += `<div class="muted">有效到 ${esc(body.validUntil)}</div>`;
    if (body.now) html += '<h3 style="margin-top:14px">现在</h3><div>' + esc(body.now).replace(/\n/g, '<br>') + '</div>';
    if (body.records && body.records.length) {
      html += '<h3 style="margin-top:14px">记录</h3><ul class="plain">' + body.records.map((line) => '<li>' + esc(line) + '</li>').join('') + '</ul>';
    }
    if (body.links && body.links.length) {
      html += '<h3 style="margin-top:14px">连到</h3><ul class="plain">' + body.links.map((link) =>
        '<li>' + esc(link.target) + ' <span class="muted">（' + esc(link.relation) + '）' + (link.why ? esc(' ' + link.why) : '') + '</span></li>').join('') + '</ul>';
    }
    if (body.entries && body.entries.length) {
      html += '<h3 style="margin-top:14px">条目</h3><ul class="plain">' + body.entries.map((entry) => {
        const shown = String(entry).split('|')[0];
        return `<li>${esc(shown)} <button class="ghost" data-entry="${esc(entry)}">读原文</button></li>`;
      }).join('') + '</ul>';
    }
    html += '<details style="margin-top:14px"><summary class="muted">这一页的源文件</summary><pre>' + esc(body.markdown) + '</pre></details>';
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
    if (!pagePath || !String(key).startsWith('memory/')) throw new Error('现在只能读种子条目的原文（memory/ 开头的条目）');
    const body = await api('/api/wiki/entry/' + pagePath.split('/').length + '/' + encodePath(pagePath) + '/' + encodePath(String(key)));
    const message = body && body.text ? body.text : (body && body.missing ? '原文当时没存：' + body.missing : '没有内容');
    const note = body && body.complete === false ? '<div class="muted">只显示了前 3000 字</div>' : '';
    page.innerHTML = crumbHtml(trail) + `<div class="card"><h2>条目原文</h2><div class="faint">${esc(String(key))}</div>
      <pre>${esc(message)}</pre>${note}</div>`;
    wireCrumbs(page, trail);
  } catch (error) {
    setStatus('条目读取失败：' + error.message, true);
  }
}

/* ---------------- 启动 ---------------- */

document.querySelectorAll('nav button').forEach((button) => {
  button.addEventListener('click', () => go({ tab: button.dataset.tab }));
});
$('scrim').addEventListener('click', closeDrawer);
document.addEventListener('keydown', (event) => {
  if ($('drawer').hidden) return;
  if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement && document.activeElement.tagName)) return;
  if (event.key === 'Escape') closeDrawer();
  if (event.key === 'ArrowLeft') stepDrawer(-1);
  if (event.key === 'ArrowRight') stepDrawer(1);
});
window.addEventListener('popstate', route);
loadConn();
setInterval(loadConn, 30000);
route();
