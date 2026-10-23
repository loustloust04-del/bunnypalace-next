// 记忆花园 · 补原图（#057）
// 在已登录的 claude.ai 或 chatgpt.com 页面的开发者工具控制台里粘贴运行。
// 做的事：按下面清单里的编号，从这个网站取你自己上传过的原图，存进你选的文件夹（文件名 = 编号）。
// 不做的事：不往这个网站以外的地方发任何东西，不读清单以外的文件，不改你的账号。
(() => {
  const CONFIG = __BACKFILL_CONFIG__;
  const SITE = { claude: "claude.ai", chatgpt: "chatgpt.com" }[CONFIG.source];
  if (!SITE || !location.hostname.endsWith(SITE)) {
    alert(`这段脚本要在 ${SITE} 的页面上运行（你现在在 ${location.hostname}）。`);
    return;
  }
  if (!window.showDirectoryPicker) {
    alert("这个浏览器不支持选文件夹，请用 Chrome 或 Edge。");
    return;
  }

  const GAP_MS = 1000;           // 每秒 1 张
  const MAX_FAILS_IN_ROW = 5;    // 连续出错这么多次就停下
  let stopped = false;

  // ---- 小面板 ----
  const panel = document.createElement("div");
  panel.style.cssText = "position:fixed;right:16px;bottom:16px;z-index:2147483647;width:300px;padding:14px;" +
    "border-radius:12px;background:#FFFBF6;color:#333;font:13px/1.5 -apple-system,sans-serif;" +
    "box-shadow:0 4px 20px rgba(0,0,0,.15);border:1px solid #E7EEEC";
  panel.innerHTML = `<div style="font-weight:600;margin-bottom:6px">记忆花园 · 补原图（${CONFIG.items.length} 张）</div>
    <div data-k="msg">选一个空文件夹开始。可以随时停，下次选同一个文件夹会接着下。</div>
    <div style="margin-top:10px;display:flex;gap:8px">
      <button data-k="go" style="flex:1;padding:6px;border:0;border-radius:8px;background:#8EBD9F;color:#fff;cursor:pointer">选文件夹并开始</button>
      <button data-k="stop" style="padding:6px 10px;border:1px solid #ccc;border-radius:8px;background:#fff;cursor:pointer">关闭</button>
    </div>`;
  document.body.appendChild(panel);
  const $ = (k) => panel.querySelector(`[data-k="${k}"]`);
  const say = (text) => { $("msg").textContent = text; };
  $("stop").onclick = () => { stopped = true; panel.remove(); };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  function extensionOf(bytes) {
    const b = bytes;
    if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) return "png";
    if (b[0] === 0xFF && b[1] === 0xD8) return "jpg";
    if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return "gif";
    if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45) return "webp";
    if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) return "heic";
    return null;
  }

  class Limited extends Error {
    constructor(seconds) { super("rate limited"); this.seconds = seconds; }
  }

  async function checked(response) {
    if (response.status === 429) throw new Limited(Number(response.headers.get("retry-after")) || 60);
    return response;
  }

  // ---- 两个网站各自怎么按编号取 ----
  let claudeOrgs = null;
  async function fetchClaude(item) {
    if (!claudeOrgs) {
      const r = await checked(await fetch("/api/organizations", { credentials: "include" }));
      if (!r.ok) throw new Error(`取组织失败 ${r.status}（登录了吗？）`);
      claudeOrgs = (await r.json()).map((o) => o.uuid);
    }
    for (const org of claudeOrgs) {
      const r = await checked(await fetch(`/api/organizations/${org}/files/${encodeURIComponent(item.id)}/contents`,
        { credentials: "include" }));
      if (r.ok) return r.blob();
      if (r.status !== 404 && r.status !== 403) throw new Error(`HTTP ${r.status}`);
    }
    return null;
  }

  let chatgptToken = null;
  async function fetchChatGPT(item) {
    if (!chatgptToken) {
      const r = await checked(await fetch("/api/auth/session", { credentials: "include" }));
      chatgptToken = r.ok ? (await r.json()).accessToken : null;
      if (!chatgptToken) throw new Error("取不到登录令牌（登录了吗？）");
    }
    const query = new URLSearchParams({ post_id: "", inline: "false" });
    if (item.conversationId) query.set("conversation_id", item.conversationId);
    const r = await checked(await fetch(`/backend-api/files/download/${encodeURIComponent(item.id)}?${query}`,
      { headers: { Authorization: `Bearer ${chatgptToken}` }, credentials: "include" }));
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const info = await r.json();
    if (!info.download_url) return null;
    const file = await checked(await fetch(info.download_url));
    if (!file.ok) throw new Error(`下载 HTTP ${file.status}`);
    return file.blob();
  }

  const fetchOne = CONFIG.source === "claude" ? fetchClaude : fetchChatGPT;

  // ---- 主循环 ----
  $("go").onclick = async () => {
    let dir;
    try {
      dir = await window.showDirectoryPicker({ mode: "readwrite" });
    } catch {
      return say("没选文件夹。");
    }
    $("go").disabled = true;
    const have = new Set();
    for await (const [name] of dir.entries()) have.add(name.replace(/\.[^.]+$/, ""));

    const results = [];
    let ok = 0, missing = 0, failsInRow = 0;
    for (let i = 0; i < CONFIG.items.length && !stopped; i++) {
      const item = CONFIG.items[i];
      if (have.has(item.id)) { results.push({ id: item.id, status: "ok" }); ok++; continue; }
      say(`第 ${i + 1} / ${CONFIG.items.length} 张… 已存 ${ok}，找不到 ${missing}`);
      try {
        const blob = await fetchOne(item);
        if (!blob) {
          results.push({ id: item.id, status: "notFound" }); missing++;
        } else {
          const bytes = new Uint8Array(await blob.arrayBuffer());
          const ext = extensionOf(bytes);
          if (!ext) {
            results.push({ id: item.id, status: "error", message: `不是图片（${blob.type || "未知类型"}，${bytes.length} 字节）` });
          } else {
            const handle = await dir.getFileHandle(`${item.id}.${ext}`, { create: true });
            const out = await handle.createWritable();
            await out.write(bytes);
            await out.close();
            results.push({ id: item.id, status: "ok" }); ok++;
          }
        }
        failsInRow = 0;
      } catch (e) {
        if (e instanceof Limited) {
          say(`网站让慢一点，等 ${e.seconds} 秒…`);
          await sleep(e.seconds * 1000);
          i--;
          continue;
        }
        results.push({ id: item.id, status: "error", message: String(e.message || e) });
        if (++failsInRow >= MAX_FAILS_IN_ROW) { say(`连续出错 ${failsInRow} 次，先停下：${e.message || e}`); break; }
      }
      await sleep(GAP_MS);
    }

    const manifest = await dir.getFileHandle("backfill-manifest.json", { create: true });
    const out = await manifest.createWritable();
    await out.write(JSON.stringify({ source: CONFIG.source, items: results }, null, 1));
    await out.close();
    $("go").disabled = false;
    $("go").textContent = "接着下";
    say(`${stopped ? "停了" : "完成"}：存了 ${ok} 张，服务器上找不到 ${missing} 张。回到花园选这个文件夹。`);
  };
})();
