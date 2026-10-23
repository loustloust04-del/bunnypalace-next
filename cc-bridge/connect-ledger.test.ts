import { describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { LagLog, classifyConnect, classifyTerminalOpen, describeDist, finalCandidate, lagOverlapMs, launchSegments, parseConnectReport, parseTerminalReport, quantile, rulerGroupKey, rulerMetrics, runTotals, type ConnectReport } from "./connect-ledger.ts"

const base: ConnectReport = { trigger: "launch", t0: 10_000, openAt: 10_080, totalMs: 80, path: "satisfied|en0" }
const ctx = { lags: [], hubStartedAt: 0 }

describe("classifyConnect", () => {
  test("≤1s 不贴理由", () => {
    expect(classifyConnect(base, ctx)).toEqual([])
    expect(classifyConnect({ ...base, totalMs: 1_000 }, ctx)).toEqual([])
  })

  test("hub 卡顿跟连接窗口重叠", () => {
    const r = { ...base, openAt: 15_000, totalMs: 5_000 }
    const why = classifyConnect(r, { lags: [{ at: 14_000, ms: 3_000 }], hubStartedAt: 0 })
    expect(why.some(w => w.includes("hub 主循环卡 3000ms"))).toBe(true)
  })

  test("hub 重启 / 代理替答 / 超时 / 退避 / 不在 Wi-Fi 各自成条", () => {
    const r: ConnectReport = {
      ...base, openAt: 20_000, totalMs: 10_000, waitMs: 2_000, path: "satisfied|pdp_ip0,utun3",
      attempts: [
        { h: "192.168.31.20", r: "timeout", ms: 4_000 },
        { h: "100.110.76.9", r: "nothub:502", ms: 3 },
        { h: "192.168.31.20", r: "refused", ms: 2 },
        { h: "100.110.76.9", r: "ws:bad response", ms: 5 },
      ],
    }
    const why = classifyConnect(r, { lags: [], hubStartedAt: 12_000 })
    const joined = why.join("|")
    for (const k of ["hub 重启中", "探测超时 1 次", "代理替答 1 次（100.110.76.9 502）", "端口拒连", "握手失败", "退避等待 2000ms", "不在 Wi-Fi"]) {
      expect(joined).toContain(k)
    }
  })

  test("点开到开始连太久单列", () => {
    expect(classifyConnect({ ...base, openAt: 12_000, totalMs: 2_000, launchMs: 1_700 }, ctx)).toEqual(["点开后 1700ms app 才开始连"])
  })

  test("什么都对不上 → 未知", () => {
    expect(classifyConnect({ ...base, openAt: 13_000, totalMs: 3_000 }, ctx)).toEqual(["未知（看 attempts）"])
  })
})

test("lagOverlapMs 只算重叠部分", () => {
  expect(lagOverlapMs([{ at: 1_000, ms: 500 }, { at: 3_000, ms: 1_000 }], 800, 2_500)).toBe(200 + 500)
})

test("终端出字：各段超 300ms 各成一条，剩余时间单列", () => {
  const r = parseTerminalReport({ session: "mp-cc-66", t0: 0, open_at: 4_000, total_ms: 4_000,
    layout_ms: 2_000, bridge_ms: 0, hub_ms: 900, hub_steps: "size=300 resize=260 pipe=40 capture=300" })!
  const why = classifyTerminalOpen(r, { lags: [{ at: 3_000, ms: 500 }] }).join("|")
  for (const k of ["app 等终端布局 2000ms", "hub 开终端 900ms（size=300", "hub 主循环卡 500ms", "传输 / 排队 / 画屏 1100ms"]) expect(why).toContain(k)
  expect(why).not.toContain("桥没连上")
  expect(classifyTerminalOpen({ ...r, totalMs: 800 }, { lags: [] })).toEqual([])
  expect(parseTerminalReport({ t0: 1, open_at: 2, total_ms: 1 })).toBeNull()
})

test("LagLog 只留窗口内", () => {
  const log = new LagLog(1_000)
  log.add({ at: 0, ms: 300 }); log.add({ at: 500, ms: 300 }); log.add({ at: 1_600, ms: 300 })
  expect(log.list().map(e => e.at)).toEqual([1_600])
})

test("parseConnectReport：缺必填返回 null；attempts 清洗", () => {
  expect(parseConnectReport({ t0: 1 })).toBeNull()
  const r = parseConnectReport({ type: "connect_report", trigger: "foreground", t0: 1.4, open_at: 90, total_ms: 88.6,
    attempts: [{ h: "a", r: "ok", ms: 3 }, { bogus: 1 }], path: "satisfied|en0" })!
  expect(r.totalMs).toBe(89)
  expect(r.attempts).toEqual([{ h: "a", r: "ok", ms: 3 }])
  expect(r.trigger).toBe("foreground")
})

// —— 尺子 connectV2-r2（plan-app-instant-connect §2，sol R1 返工）——

/// app 端 ConnectRulerEpisode.fields 的样子（冷启动、两候选、LAN 赢）。墙钟自洽：
/// t0（进程起点）1000 + launch_ms 2100 = 入口 3100；first_req 12 → 3112；ws_open 760 → 3860；ui 1200 → 4300；finish 1208 → open_at 4308
const v2Frame = {
  type: "connect_report", trigger: "launch", t0: 1_000, open_at: 4_308, total_ms: 3_308, launch_ms: 2_100,
  main_delay_ms: 640, attempts: [{ h: "192.168.31.20", r: "ok", ms: 700 }], host: "192.168.31.20", path: "satisfied|en0",
  rev: "connectV2-r2", build: "debug", run: "run-1", dev: "dev-aaaaaaaa-1", bin: "BIN-1111", sw: {}, ep: 1,
  counts: { started: 1, ok: 1, replaced: 0, report_failed: 0 },
  first_req_ms: 12, ws_attempt: 1, ws_gen: 4, ws_via: "4.0", ws_resume_ms: 705, ws_open_ms: 760, ui_ms: 1_200,
  client_info_ms: 1_205, finish_ms: 1_208,
  first_request_at: 3_112, ws_open_at: 3_860, ui_connected_at: 4_300,
  candidates: [
    { id: "4.0", round: 4, h: "192.168.31.20", at_ms: 12, task_ms: 38, cb_ms: 41, queue_ms: 640, handle_ms: 12, won: true },
    { id: "4.1", round: 4, h: "100.110.76.9", at_ms: 12, cb_ms: 60, queue_ms: 650, handle_ms: 0, won: false, late: true, token: "不该出现" },
  ],
  busy_ms: 980, busy_n50: 4, busy_max_ms: 520, busy_window_ms: 1_200,
  segs: { entry: 0, props: 40, propProviders: 150, propCards: 220, initBegin: 260, bootstrapEligible: 300, container: 900,
          profiles: 960, cards: 1_000, initEnd: 1_300, splashRelease: 1_500, contentAppear: 1_950, connect: 1_980 },
  pre_main_ms: 120, launch_src: "icon", recovery: [],
}

describe("尺子 connectV2-r2", () => {
  test("样例墙钟自洽：t0 + launch + 各段 = open_at", () => {
    const f = v2Frame
    expect(f.t0 + f.launch_ms).toBe(f.first_request_at - f.first_req_ms)
    expect(f.pre_main_ms + f.segs.connect).toBe(f.launch_ms)
    expect(f.ui_connected_at).toBeLessThanOrEqual(f.open_at)
    expect(f.first_request_at - f.first_req_ms + f.finish_ms).toBe(f.open_at)
  })

  test("parse：新字段 camelCase；候选只留数字 + host + id；旧字段语义不变", () => {
    const r = parseConnectReport(v2Frame)!
    expect(r.totalMs).toBe(3_308)
    expect(r.mainDelayMs).toBe(640)
    expect([r.rev, r.build, r.run, r.dev, r.bin, r.ep]).toEqual(["connectV2-r2", "debug", "run-1", "dev-aaaaaaaa-1", "BIN-1111", 1])
    expect(r.sw).toEqual({})
    expect(r.counts).toEqual({ started: 1, ok: 1, replaced: 0, reportFailed: 0 })
    expect([r.firstReqMs, r.wsResumeMs, r.wsOpenMs, r.uiMs, r.clientInfoMs, r.finishMs]).toEqual([12, 705, 760, 1_200, 1_205, 1_208])
    expect([r.wsAttempt, r.wsGen, r.wsVia]).toEqual([1, 4, "4.0"])
    expect([r.firstRequestAt, r.wsOpenAt, r.uiConnectedAt]).toEqual([3_112, 3_860, 4_300])
    expect(r.candidates).toEqual([
      { id: "4.0", round: 4, h: "192.168.31.20", atMs: 12, taskMs: 38, cbMs: 41, queueMs: 640, handleMs: 12, won: true },
      { id: "4.1", round: 4, h: "100.110.76.9", atMs: 12, taskMs: undefined, cbMs: 60, queueMs: 650, handleMs: 0, won: false, late: true },
    ])
    expect(JSON.stringify(r)).not.toContain("不该出现")
    expect(r.segs?.connect).toBe(1_980)
    expect([r.preMainMs, r.launchSrc, r.busyWindowMs]).toEqual([120, "icon", 1_200])
    expect(r.recovery).toEqual([])
    for (const k of ["launchFail", "busyCapped", "wsInvalid", "candDropped"]) expect(k in r).toBe(false)
  })

  test("parse：旧 app 没 rev → 一个新字段都不出", () => {
    const { rev, ...old } = v2Frame
    const r = parseConnectReport(old)!
    for (const k of ["rev", "build", "dev", "bin", "firstReqMs", "clientInfoMs", "candidates", "segs", "busyMs", "preMainMs"]) expect(k in r).toBe(false)
  })

  test("finalCandidate：按 ws_via 找，不取「最后一个 won」；直连没有", () => {
    const r = parseConnectReport({ ...v2Frame, candidates: [
      { id: "4.0", round: 4, h: "a", queue_ms: 1, handle_ms: 1, won: true },
      { id: "9.1", round: 9, h: "b", queue_ms: 2, handle_ms: 2, won: true },
    ] })!
    expect(finalCandidate(r)?.h).toBe("a")
    expect(finalCandidate({ ...r, wsVia: "direct" })).toBeUndefined()
    expect(finalCandidate({ ...r, wsVia: "7.7" })).toBeUndefined()
  })

  test("launchSegments：固定顺序逐段差；缺点跨段命名；读失败 / 预热不给入口段；逆序 = 不可分解", () => {
    const r = parseConnectReport(v2Frame)!
    const { segs, ordered } = launchSegments(r)
    expect(ordered).toBe(true)
    expect(segs[0]).toEqual({ key: "entry", label: "进程起点→入口", ms: 120 })
    expect(segs.find(s => s.key === "bootstrapEligible")?.ms).toBe(40)
    expect(segs.find(s => s.key === "container")).toEqual({ key: "container", label: "可早连→建库完（archive 清理 + 建库）", ms: 600 })
    expect(segs.reduce((a, s) => a + s.ms, 0)).toBe(120 + 1_980)
    const mac = launchSegments({ ...r, segs: { entry: 0, initEnd: 700, contentAppear: 900 } }).segs
    expect(mac.map(s => s.label)).toEqual(["进程起点→入口", "entry→initEnd", "initEnd→contentAppear"])
    expect(launchSegments({ ...r, launchFail: true }).segs[0].key).toBe("props")
    expect(launchSegments({ ...r, prewarm: true }).segs[0].key).toBe("props")
    expect(launchSegments({ ...r, segs: undefined })).toEqual({ segs: [], ordered: true })
    // A2 早连：connect 跑到 contentAppear 前面
    expect(launchSegments({ ...r, segs: { ...r.segs!, connect: 400 } }).ordered).toBe(false)
  })

  test("classify：拆成启动某段 / 排主线程，替掉旧的 max 主线程忙和点开后才连", () => {
    const why = classifyConnect(parseConnectReport(v2Frame)!, ctx)
    const joined = why.join("|")
    for (const k of ["启动慢：可早连→建库完（archive 清理 + 建库） 600ms", "启动慢：init 其余 300ms", "启动慢：内容门→首屏 onAppear 450ms",
                     "排主线程：探测结果等 640ms", "排主线程：连上后等 440ms", "连接窗口主线程忙 980ms（>50ms 块 4 个，最长 520ms）"]) {
      expect(joined).toContain(k)
    }
    for (const k of ["app 主线程忙", "点开后", "真网络", "URLSession", "client_info"]) expect(joined).not.toContain(k)
  })

  test("classify：URLSession 生命周期 / WS 回调 / client_info 前接线 / 读失败 / 逆序 / 截断 / 归属作废", () => {
    const r = parseConnectReport({ ...v2Frame, launch_fail: true, pre_main_ms: undefined,
      candidates: [{ id: "4.0", round: 4, h: "100.110.76.9", task_ms: 900, cb_ms: 905, queue_ms: 3, handle_ms: 2, won: true }],
      ws_resume_ms: 920, ws_open_ms: 1_500, ui_ms: 1_503, client_info_ms: 1_900, busy_ms: 20, busy_capped: true, busy_window_ms: 60_000,
      ws_invalid: 2, segs: { entry: 0, contentAppear: 900, connect: 200 } })!
    const joined = classifyConnect(r, ctx).join("|")
    for (const k of ["进程起点读不到", "URLSession 任务生命周期 900ms（探测 100.110.76.9）", "WS resume→delegate 回调 580ms",
                     "主线程进入→client_info 发出 397ms", "启动分段逆序（不可分解）", "连接窗口超时截断（只记前 60000ms，其中主线程忙 20ms）",
                     "WS 时间戳归属对不上 2 次"]) {
      expect(joined).toContain(k)
    }
    expect(joined).not.toContain("排主线程")
    expect(joined).not.toContain("启动慢")
  })

  test("classify：有尺子时 hub 卡顿只算「请求发出 → WS 打开」，且只说相关", () => {
    const r = parseConnectReport(v2Frame)!
    expect(classifyConnect(r, { lags: [{ at: 3_000, ms: 1_500 }], hubStartedAt: 0 }).join("|")).not.toContain("hub 主循环卡")
    expect(classifyConnect(r, { lags: [{ at: 3_800, ms: 500 }], hubStartedAt: 0 }).join("|")).toContain("hub 主循环卡顿与连接窗口重叠 500ms（相关，非因果）")
  })

  test("quantile：nearest-rank；describeDist：n<5 列原始值", () => {
    expect(quantile([1, 2, 3, 4], 0.5)).toBe(2)
    expect(quantile([1, 2, 3, 4], 0.75)).toBe(3)
    expect(quantile([1, 2], 0.5)).toBe(1)
    expect(quantile([5], 0.9)).toBe(5)
    expect(quantile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9)).toBe(9)
    expect(describeDist([3, 8])).toBe("n=2  原始值 3 / 8")
    expect(describeDist([1, 2, 3, 4, 5])).toBe("n=  5  p50 3  p75 4  p90 5")
  })

  test("rulerMetrics：去预热；截断 / 逆序 / 作废单列不进分位数；终点用 client_info", () => {
    const a = parseConnectReport(v2Frame)!
    const b = parseConnectReport({ ...v2Frame, ui_ms: 300, ws_open_ms: 250, client_info_ms: 310, busy_ms: 100 })!
    const warm = { ...a, prewarm: true }
    const capped = { ...a, busyCapped: true }
    const disordered = { ...a, segs: { ...a.segs!, connect: 100 } }
    const old = parseConnectReport({ t0: 1, open_at: 2, total_ms: 1, trigger: "launch" })!
    const split = rulerMetrics([a, b, warm, capped, disordered, old])
    const ms = new Map(split.metrics.map(m => [m.name, m.values]))
    expect([split.prewarm, split.capped, split.disordered, split.invalid]).toEqual([1, 1, 1, 0])
    expect(ms.get("开始连→client_info 发出（终点）")).toEqual([310, 1_205, 1_205, 1_205])
    expect(ms.get("窗口主线程忙")).toEqual([100, 980, 980])
    expect(ms.get("WS 回调→主线程进入")).toEqual([50, 440, 440, 440])
    expect(ms.get("全程 进程起点→client_info 发出")).toEqual([2_410, 3_305, 3_305])
    expect(ms.get("启动 可早连→开始连")).toEqual([1_680, 1_680, 1_680])
    expect(ms.get("探测 URLSession 任务生命周期")).toEqual([38, 38, 38, 38])
  })

  test("分组按设备 × 包 × 开关，不看 from；runTotals 每进程取最大再求和", () => {
    const a = parseConnectReport(v2Frame)!
    const k = rulerGroupKey({ ...a, platform: "ios" })
    expect(k).toBe("launch · ios · dev dev-aaaa · bin BIN-1111(debug) · sw{} · connectV2-r2")
    expect(rulerGroupKey({ ...a, platform: "ios", sw: { A2: "1", A1: "0" } })).toContain("sw{A1=0,A2=1}")
    expect(rulerGroupKey({ ...a, platform: "ios", bin: "BIN-2222" })).not.toBe(k)
    const t = runTotals([
      { ...a, run: "r1", counts: { started: 1, ok: 1, replaced: 0, reportFailed: 0 } },
      { ...a, run: "r1", counts: { started: 3, ok: 2, replaced: 1, reportFailed: 1 } },
      { ...a, run: "r2", counts: { started: 1, ok: 1, replaced: 0, reportFailed: 0 } },
    ])
    expect(t).toEqual({ runs: 2, started: 4, ok: 3, replaced: 1, reportFailed: 1 })
  })

  test("统计脚本：临时账本里新旧行混着，标题写明仅成功上报 + 剔除预热，按设备 × 包分组拆分", () => {
    const dir = mkdtempSync(join(tmpdir(), "connect-ledger-"))
    try {
      const file = join(dir, "ledger.jsonl")
      const now = Date.now()
      const v2 = parseConnectReport(v2Frame)!
      const old = parseConnectReport({ t0: 1, open_at: 2, total_ms: 1_500, trigger: "launch", main_delay_ms: 400 })!
      const warm = parseConnectReport({ ...v2Frame, prewarm: true, total_ms: 90_000 })!
      const lines = [
        { at: now, from: "relay", platform: "ios", fast: false, reasons: classifyConnect(v2, ctx), ...v2 },
        { at: now, from: "192.168.31.9", platform: "ios", fast: false, reasons: classifyConnect(old, ctx), ...old },
        { at: now, from: "relay", platform: "ios", fast: false, reasons: [], ...warm },
      ]
      writeFileSync(file, lines.map(l => JSON.stringify(l)).join("\n") + "\n")
      const p = Bun.spawnSync(["bun", join(import.meta.dir, "scripts", "connect-ledger.ts"), "--file", file, "--hours", "1"])
      const out = p.stdout.toString()
      expect(p.exitCode).toBe(0)
      expect(out).toContain("[ledgerStats-r2] 仅成功上报样本")
      expect(out).toContain("已剔除冷启动预热 1 次")
      expect(out).toContain("连接 2 次")
      expect(out).toContain("launch · ios · dev dev-aaaa · bin BIN-1111(debug) · sw{} · connectV2-r2（2 次）")
      expect(out).toContain("单列（不进分位数）：预热 1")
      expect(out).toContain("启动来源：icon 2")
      expect(out).toContain("探测 回调→主线程")
      expect(out).toContain("原始值 640")
      expect(out.slice(out.indexOf("尺子拆分"), out.indexOf("理由分布"))).not.toContain("relay")
      expect(out).toContain("app 主线程忙")   // 旧行理由照旧
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
