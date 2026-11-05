import { expect, test } from "bun:test"
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { basename, join } from "node:path"
import { MAX_FETCH_NAMES, MAX_FRAME_BYTES, buildSnapshot, fetchFrames, frontmatter, isExcluded, loadExtraExcludes, manifest, sha256, stripExcludedLinks, MemoryFileCache, MemoryReplies, MemorySnapshots, CACHE_MAX_BYTES, READ_CONCURRENCY, readStats, readHooks, screenSnapshot, isPrivateName } from "./cc-memory-sync.ts"

const md = (name: string, description: string, body = "正文") => `---\nname: ${name}\ndescription: ${description}\ntype: project\n---\n\n${body}\n`

function fixtureDir(files: Record<string, string>): string {
  const dir = mkdtempSync(join(tmpdir(), "cc-memory-"))
  for (const [n, c] of Object.entries(files)) writeFileSync(join(dir, n), c)
  return dir
}

test("frontmatter 只读开头那块", () => {
  expect(frontmatter(md("剧场", "猫和狗的剧场"))).toEqual({ name: "剧场", description: "猫和狗的剧场" })
  expect(frontmatter("没有 frontmatter\nname: x")).toEqual({})
})

test("排除：private_、名单、非 md；名字或 frontmatter 提到日记的照常同步", () => {
  const none = new Set<string>()
  expect(isExcluded("private_diary_key.md", md("钥匙", "x"), none)).toBe(true)
  expect(isExcluded("private_anything.md", md("a", "b"), none)).toBe(true)
  expect(isExcluded("notes.txt", "x", none)).toBe(true)
  expect(isExcluded("x.md", md("a", "b"), new Set(["x.md"]))).toBe(true)
  expect(isExcluded("my_diary.md", md("a", "b"), new Set(["my_diary.md"]))).toBe(true)
  expect(isExcluded("my_diary.md", md("a", "b"), none)).toBe(false)
  expect(isExcluded("x.md", md("岚舟的日记本", "b"), none)).toBe(false)
  expect(isExcluded("x.md", md("a", "星砚 diary 的钥匙"), none)).toBe(false)
})

test("粟粟 D2：正文里只是提到日记的照常同步", () => {
  const body = "笔友的钥匙存在日记本里"
  expect(isExcluded("project_beacon_penpals.md", md("BEACON笔友", "AI留言墙"), new Set())).toBe(false)
  expect(isExcluded("project_beacon_penpals.md", md("BEACON笔友", "AI留言墙", body), new Set())).toBe(false)
})

test("MEMORY.md 去掉指向被排除文件的行", () => {
  const index = "- [剧场](project_theater.md) — x\n- [小克的日记本](private_diary_key.md) — 钥匙\n- [笔友](project_beacon_penpals.md) — 钥匙存日记本"
  const out = stripExcludedLinks(index, new Set(["private_diary_key.md"]))
  expect(out).not.toContain("private_diary_key.md")
  expect(out).toContain("project_theater.md")
  expect(out).toContain("project_beacon_penpals.md")
})

test("快照：排除的不进清单，MEMORY.md 已去行，哈希是发出内容的哈希", async () => {
  const dir = fixtureDir({
    "MEMORY.md": "# 索引\n- [日记本](private_diary_key.md) — 钥匙\n- [剧场](project_theater.md) — 剧场",
    "private_diary_key.md": md("钥匙", "加密日记本的钥匙", "SECRET"),
    "project_theater.md": md("剧场", "猫狗剧场", "剧场里写过日记体"),
    "project_lanzhou_diary.md": md("岚舟日记本", "钥匙存日记本的项目"),
    "notes.txt": "不是 md",
  })
  const snap = await buildSnapshot(dir, new Set(), new MemoryFileCache())
  expect([...snap.keys()].sort()).toEqual(["MEMORY.md", "project_lanzhou_diary.md", "project_theater.md"])
  expect(snap.get("MEMORY.md")).not.toContain("private_diary_key")
  const m = manifest(snap)
  expect(m.find(e => e.name === "MEMORY.md")?.sha256).toBe(sha256(snap.get("MEMORY.md")!))
  expect(JSON.stringify(m)).not.toContain("SECRET")
})

test("目录不存在 = 空快照", async () => {
  expect((await buildSnapshot(join(tmpdir(), "no-such-dir-cc-memory"), new Set(), new MemoryFileCache())).size).toBe(0)
})

/// 改异步前的同步实现（逐字照抄），用来对拍
function legacySnapshot(dir: string, extra: Set<string>): Map<string, string> {
  const raw = new Map<string, string>()
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(".md")) continue
    try { raw.set(name, readFileSync(join(dir, name), "utf8")) } catch {}
  }
  const excluded = new Set<string>()
  const kept = new Map<string, string>()
  for (const [name, text] of raw) {
    if (isExcluded(name, text, extra)) excluded.add(name)
    else kept.set(name, text)
  }
  const index = kept.get("MEMORY.md")
  if (index !== undefined) kept.set("MEMORY.md", stripExcludedLinks(index, excluded))
  return kept
}

test("异步快照与原来的同步版逐项一致（40 个文件 > 并行上限、顺序、内容、清单、取文件帧）", async () => {
  const files: Record<string, string> = { "MEMORY.md": "# 索引\n- [日记](private_x.md)\n" + Array.from({ length: 30 }, (_, i) => `- [f${i}](f${i}.md)`).join("\n") }
  for (let i = 0; i < 38; i++) files[`f${i}.md`] = md(`第${i}`, i % 7 === 0 ? "日记" : "普通", "正文".repeat(i * 50))
  files["private_x.md"] = md("x", "y")
  files["skip.txt"] = "不是 md"
  const dir = fixtureDir(files)
  const extra = new Set(["f3.md"])
  const want = legacySnapshot(dir, extra)
  const got = await buildSnapshot(dir, extra, new MemoryFileCache())
  expect([...got.entries()]).toEqual([...want.entries()])
  expect(JSON.stringify(manifest(got))).toBe(JSON.stringify(manifest(want)))
  const names = [...want.keys()].slice(0, 25)
  expect(fetchFrames(got, names)).toEqual(fetchFrames(want, names))
})

test("按 mtime 缓存：没变不重读；改了（mtime / 大小变）重读；读失败用上次读到的；删掉的文件出缓存", async () => {
  const dir = fixtureDir({ "a.md": md("a", "x", "v1"), "b.md": md("b", "x") })
  const cache = new MemoryFileCache()
  expect((await buildSnapshot(dir, new Set(), cache)).get("a.md")).toContain("v1")
  expect(cache.size).toBe(2)
  // 缓存命中：把缓存里的内容换掉，文件没动 → 拿到的是缓存里的（证明没重读）
  const pa = join(dir, "a.md")
  cache.set(pa, { ...cache.get(pa)!, text: "FROM-CACHE" })
  expect((await buildSnapshot(dir, new Set(), cache)).get("a.md")).toBe("FROM-CACHE")
  // 改内容（同样大小也行：mtime 变）→ 重读
  writeFileSync(pa, md("a", "x", "v2"))
  const t = statSync(pa).mtimeMs / 1000 + 5
  utimesSync(pa, t, t)
  expect((await buildSnapshot(dir, new Set(), cache)).get("a.md")).toContain("v2")
  // 再改且读不了（权限）→ 用上次读到的 v2，不是跳过
  writeFileSync(pa, md("a", "x", "v3"))
  utimesSync(pa, t + 5, t + 5)
  chmodSync(pa, 0o000)
  try { expect((await buildSnapshot(dir, new Set(), cache)).get("a.md")).toContain("v2") }
  finally { chmodSync(pa, 0o644) }
  // 删掉 → 不在快照、也不在缓存
  rmSync(join(dir, "b.md"))
  expect((await buildSnapshot(dir, new Set(), cache)).has("b.md")).toBe(false)
  expect(cache.has(join(dir, "b.md"))).toBe(false)
})

test("读不了、从没读到过的文件跳过（与原来一样）", async () => {
  const dir = fixtureDir({ "a.md": md("a", "x"), "locked.md": md("l", "x") })
  chmodSync(join(dir, "locked.md"), 0o000)
  try { expect([...(await buildSnapshot(dir, new Set(), new MemoryFileCache())).keys()]).toEqual(["a.md"]) }
  finally { chmodSync(join(dir, "locked.md"), 0o644) }
})

test("取文件：只给快照里的名字，排除的拿不到", () => {
  const snap = new Map([["a.md", "A"], ["b.md", "B"]])
  const frames = fetchFrames(snap, ["a.md", "private_diary_key.md", "../etc/passwd", 42])
  expect(frames.length).toBe(1)
  const f = JSON.parse(frames[0])
  expect(f.type).toBe("cc_memory_files")
  expect(f.files).toEqual([{ name: "a.md", content: "A" }])
})

test("取文件：每次最多 MAX_FETCH_NAMES 个，按帧大小分批", () => {
  const big = "字".repeat(Math.floor(MAX_FRAME_BYTES / 3 / 2))   // 每个约半帧
  const snap = new Map<string, string>()
  for (let i = 0; i < 30; i++) snap.set(`f${i}.md`, big)
  const frames = fetchFrames(snap, [...snap.keys()])
  const sent = frames.flatMap(fr => JSON.parse(fr).files.map((x: { name: string }) => x.name))
  expect(sent.length).toBe(MAX_FETCH_NAMES)
  for (const fr of frames) expect(Buffer.byteLength(fr, "utf8")).toBeLessThan(MAX_FRAME_BYTES + 4096)
})

test("单个超帧上限的文件跳过并报出名字", () => {
  const snap = new Map([["huge.md", "x".repeat(MAX_FRAME_BYTES + 1)], ["ok.md", "ok"]])
  const frames = fetchFrames(snap, ["huge.md", "ok.md"]).map(f => JSON.parse(f))
  expect(frames.flatMap(f => f.files.map((x: { name: string }) => x.name))).toEqual(["ok.md"])
  expect(frames.find(f => f.skipped)?.skipped).toEqual(["huge.md"])
})

test("排除名单文件：# 注释和空行忽略", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cc-memory-ex-"))
  const p = join(dir, "x.exclude")
  writeFileSync(p, "# 注释\n\na.md\n  b.md  \n")
  expect([...(await loadExtraExcludes(p))].sort()).toEqual(["a.md", "b.md"])
  expect((await loadExtraExcludes(join(dir, "none"))).size).toBe(0)
})

test("审查 R1-5 缓存只留要发的：超过单帧上限的在清单里但不常驻；frontmatter 提到日记的照常同步、常驻；按名字排除的不读也照样去 MEMORY.md 行", async () => {
  const dir = fixtureDir({
    "MEMORY.md": "- [钥匙](private_k.md)\n- [日记](d.md)\n- [大](big.md)",
    "big.md": "x".repeat(MAX_FRAME_BYTES + 1),
    "d.md": md("小克的日记本", "x"),
    "private_k.md": "SECRET",
  })
  chmodSync(join(dir, "private_k.md"), 0o000)   // 读不了也要照删 MEMORY.md 里那行：说明按名字排除的根本没去读
  const cache = new MemoryFileCache()
  try {
    const snap = await buildSnapshot(dir, new Set(), cache)
    expect([...snap.keys()].sort()).toEqual(["MEMORY.md", "big.md", "d.md"])
    expect(snap.get("MEMORY.md")).toBe("- [日记](d.md)\n- [大](big.md)")
    expect(manifest(snap).find(e => e.name === "big.md")?.size).toBe(MAX_FRAME_BYTES + 1)
    expect([cache.has(join(dir, "big.md")), cache.has(join(dir, "d.md")), cache.has(join(dir, "private_k.md")), cache.has(join(dir, "MEMORY.md"))])
      .toEqual([false, true, false, true])
  } finally { chmodSync(join(dir, "private_k.md"), 0o644) }
})

test("审查 R1-4 读盘并发是全进程的：5 个构建同时跑（各自的缓存、各 30 个文件），同时在读的最多 READ_CONCURRENCY 个", async () => {
  const dirs = Array.from({ length: 5 }, () => {
    const files: Record<string, string> = {}
    for (let i = 0; i < 30; i++) files[`f${i}.md`] = md(`f${i}`, "x", "正文".repeat(200))
    return fixtureDir(files)
  })
  readStats.peak = 0
  const snaps = await Promise.all(dirs.map(d => buildSnapshot(d, new Set(), new MemoryFileCache())))
  expect(snaps.map(s => s.size)).toEqual([30, 30, 30, 30, 30])
  expect(readStats.peak).toBe(READ_CONCURRENCY)   // 确实撞上了上限（150 个读一起排），又没超过
  expect(readStats.active).toBe(0)
})

test("审查 R1-4 同一目录的构建合并：在读时再来 5 个清单请求只多排一份；取文件跟在途的、或复用最近一份", async () => {
  const gates: (() => void)[] = []
  let builds = 0
  const build = async () => {
    const n = ++builds
    await new Promise<void>(r => gates.push(r))
    return new Map([["v.md", `v${n}`]])
  }
  const s = new MemorySnapshots("/unused", new MemoryFileCache(), build, 60_000, async () => new Set())
  const first = s.fresh()
  const later = Array.from({ length: 5 }, () => s.fresh())
  const fetchWhileQueued = s.recent()
  await Bun.sleep(0)                             // 构建前先读名单（异步），等一拍
  expect(builds).toBe(1)
  gates.shift()!()
  expect((await first).get("v.md")).toBe("v1")
  await Bun.sleep(0)
  expect(builds).toBe(2)                         // 排队的那一份在第一份读完后才开始：一定看得到请求之后的改动
  gates.shift()!()
  for (const p of [...later, fetchWhileQueued]) expect((await p).get("v.md")).toBe("v2")
  expect((await s.recent()).get("v.md")).toBe("v2")   // 最近一份还新：取文件直接复用，不重扫
  expect(builds).toBe(2)
})

test("审查 R1-3 同一连接的回包按请求顺序：旧 fetch 读得慢、新清单读得快，也是旧 fetch 先发、新清单后发", async () => {
  const sent: string[] = []
  const replies = new MemoryReplies(f => sent.push(f))
  let releaseOld!: () => void
  const oldFetch = replies.push(async () => { await new Promise<void>(r => { releaseOld = r }); return ["files(old.md=OLD)"] })
  const newManifest = replies.push(async () => ["manifest(files=[])"])
  await Bun.sleep(10)
  expect(sent).toEqual([])                       // 新清单早就读完了，也要等前面那条
  releaseOld()
  await Promise.all([oldFetch, newManifest])
  expect(sent).toEqual(["files(old.md=OLD)", "manifest(files=[])"])
  // 一条失败不断链
  await replies.push(async () => { throw new Error("x") }).catch(() => {})
  await replies.push(async () => ["after"])
  expect(sent.at(-1)).toBe("after")
})

test("审查 R1-3 旧构建晚到的读数不写回缓存：读到一半有新构建开始，旧的那次读完不再 set（已删除的文件不会复活在缓存里）", async () => {
  const dir1 = fixtureDir({ "a.md": md("a", "x"), "slow.md": "slow" })
  let release!: () => void
  const gate = new Promise<void>(r => { release = r })
  readHooks.onOpen = path => path.endsWith("slow.md") ? gate : undefined
  const cache = new MemoryFileCache()
  try {
    const older = buildSnapshot(dir1, new Set(), cache)   // 读 slow.md 卡在闸上，a.md 读完了还没进缓存
    await Bun.sleep(50)
    const dir2 = fixtureDir({ "b.md": md("b", "x") })
    await buildSnapshot(dir2, new Set(), cache)            // 更新的一次构建开始并完成
    rmSync(join(dir1, "a.md"))                             // a.md 已经删了
    release()
    const snap = await older
    expect(snap.get("slow.md")).toBe("slow")
    expect(cache.has(join(dir1, "a.md"))).toBe(false)      // 没有版本核对时这里是 true
    expect(cache.has(join(dir2, "b.md"))).toBe(true)
  } finally { readHooks.onOpen = undefined }
})

test("审查 R1-5 缓存总字节有上限，按最近使用淘汰；整个目录没了，这个目录的缓存全清", async () => {
  const c = new MemoryFileCache(100)
  const f = (n: number) => ({ mtimeMs: 1, ctimeMs: 1, size: n, text: "x".repeat(n) })
  c.set("/d/a", f(40)); c.set("/d/b", f(40))
  c.get("/d/a")                       // a 变成最近用过
  c.set("/d/c", f(40))                // 超 100：扔最久没用的 b
  expect([c.has("/d/a"), c.has("/d/b"), c.has("/d/c"), c.bytes]).toEqual([true, false, true, 80])
  c.set("/d/huge", f(101))            // 单个就超上限：不进
  expect([c.has("/d/huge"), c.bytes]).toEqual([false, 80])
  expect(CACHE_MAX_BYTES).toBeGreaterThan(MAX_FRAME_BYTES)

  const dir = fixtureDir({ "a.md": md("a", "x"), "b.md": md("b", "x") })
  const cache = new MemoryFileCache()
  await buildSnapshot(dir, new Set(), cache)
  expect(cache.size).toBe(2)
  rmSync(dir, { recursive: true })
  expect((await buildSnapshot(dir, new Set(), cache)).size).toBe(0)
  expect([cache.size, cache.bytes]).toEqual([0, 0])
})

// MARK: - 审查 seed-all（astra）P1-1 / P1-2 / P2-3 / P2-6

const pipeline = JSON.parse(readFileSync(join(import.meta.dir, "../fixtures/cc-memory-sync/pipeline.json"), "utf8")) as {
  files: Record<string, string>; symlinks: Record<string, string>; expected: Record<string, string>; markers: string[]
}

function pipelineDir(): string {
  const dir = fixtureDir(pipeline.files)
  for (const [link, target] of Object.entries(pipeline.symlinks)) symlinkSync(target, join(dir, link))
  return dir
}

async function withOpenSpy<T>(fn: (opened: string[]) => Promise<T>): Promise<T> {
  const opened: string[] = []
  readHooks.onOpen = path => { opened.push(basename(path)) }
  try { return await fn(opened) } finally { readHooks.onOpen = undefined }
}

test("合成管线（hub 段）：快照 == 夹具 expected；私人（不分大小写）/ 符号链接一次都没打开；MEMORY.md 链接变体全剥", async () => {
  const dir = pipelineDir()
  await withOpenSpy(async opened => {
    const snap = await buildSnapshot(dir, new Set(), new MemoryFileCache())
    expect(Object.fromEntries(snap)).toEqual(pipeline.expected)
    expect(opened.sort()).toEqual(Object.keys(pipeline.expected).sort())
    const sent = fetchFrames(snap, [...snap.keys(), "my_diary.md", "PRIVATE_xingyan.md"]).join("\n") + JSON.stringify(manifest(snap))
    for (const marker of pipeline.markers) expect(sent).not.toContain(marker)
  })
})

test("P1-2 私人文件 = 文件名以 private_ 开头（不分大小写），读取次数 0；中间带 private_ 的是普通文件，照常同步", async () => {
  for (const name of ["private_a.md", "PRIVATE_b.md", "Private_c.md", "sub/private_d.md"]) expect(isPrivateName(name)).toBe(true)
  for (const name of ["privately.md", "project_private_repo_direction.md", "note_private_y.md", "note_PRIVATE_d.md"]) expect(isPrivateName(name)).toBe(false)
  const dir = fixtureDir({ "PRIVATE_b.md": "S1", "Private_c.md": "S2", "private_e.md": "S3", "ok.md": "ok", "project_private_x.md": "私有仓库", "note_private_y.md": "y" })
  await withOpenSpy(async opened => {
    const snap = await buildSnapshot(dir, new Set(), new MemoryFileCache())
    expect([...snap.keys()].sort()).toEqual(["note_private_y.md", "ok.md", "project_private_x.md"])
    expect(opened.sort()).toEqual(["note_private_y.md", "ok.md", "project_private_x.md"])
  })
})

test("P1-1 符号链接 / FIFO / 文件夹不打开；读过的文件换成链接后，缓存也不再给（含列目录之后、打开之前才换的）", async () => {
  const dir = fixtureDir({ "plain.md": "PLAIN", "swap.md": "OLD_PLAIN", "late.md": "OLD_LATE", "private_t.md": "SYNTH_SECRET" })
  const outside = mkdtempSync(join(tmpdir(), "cc-memory-outside-"))
  writeFileSync(join(outside, "o.md"), "SYNTH_OUTSIDE")
  symlinkSync("private_t.md", join(dir, "link.md"))
  symlinkSync(join(outside, "o.md"), join(dir, "outside.md"))
  expect(Bun.spawnSync(["/usr/bin/mkfifo", join(dir, "pipe.md")]).exitCode).toBe(0)
  mkdirSync(join(dir, "folder.md"))
  const cache = new MemoryFileCache()
  await withOpenSpy(async opened => {
    let snap = await buildSnapshot(dir, new Set(), cache)
    expect([...snap.keys()].sort()).toEqual(["late.md", "plain.md", "swap.md"])
    expect(opened.sort()).toEqual(["late.md", "plain.md", "swap.md"])
    expect(cache.has(join(dir, "swap.md"))).toBe(true)

    rmSync(join(dir, "swap.md")); symlinkSync("private_t.md", join(dir, "swap.md"))
    readHooks.onOpen = path => {   // 列目录时还是普通文件，打开前一刻换成链接（竞态）
      if (path.endsWith("late.md")) { rmSync(path); symlinkSync("private_t.md", path) }
    }
    snap = await buildSnapshot(dir, new Set(), cache)
    expect([...snap.keys()]).toEqual(["plain.md"])
    expect([cache.has(join(dir, "swap.md")), cache.has(join(dir, "late.md"))]).toEqual([false, false])
    expect(JSON.stringify([...snap.values()])).not.toContain("SYNTH_")
  })
})

test("P2-3 MEMORY.md 按行剥：链接目标按完整路径判、正文里裸写的以 private_ 开头的文件名也判（不分大小写），排除 / 名单文件名同剥，悬空的也剥；中间带 private_ 的不动", () => {
  const keep = [
    "- [keep](project_ok.md) — 这行提到 private 和日记", "- [keep2](project_listed.md)", "- [keep3](unlinked.md.bak)",
    "- [私有仓库](project_private_repo.md) — 私有仓库方向", "- [笔记](note_PRIVATE_y.md)",
  ]
  const index = [
    "- [a](./private_x.md)", "- [b](PRIVATE_y.md#section \"标题\")", "- [c](private\\_w.md)", "- [d](private%5Fv.md)",
    "- [e](sub/../Private_u.md)", "- [f](listed.md)", "- [g](<linked.md>)", "- 见 notes/private_a.md", "private_b.md 开头那份",
    "- 文件名带 private_ 的不同步",
    ...keep,
  ].join("\n")
  const out = stripExcludedLinks(index, new Set(["linked.md"]), new Set(["listed.md"]))
  expect(out).toBe(keep.join("\n"))
})

test("astra 第三轮：中文括号里裸写的私人文件、private_ 后面跟标点的链接目标要剥；目标里带空格（<> 或 %20）的普通文件不剥", () => {
  const strip = [
    "- 私人备注（private_gone.md）：SYNTH_SECRET",
    "- [秘密](private_!gone.md) — SYNTH_SECRET",
    "- 见【PRIVATE_x.md】", "- 《Private_y.md》里写着", "- 备注、private_z.md",
  ]
  const keep = [
    "- [公开](<project private_repo.md>) — 讲私有仓库",
    "- [公开](project%20private_repo.md) — 讲私有仓库",
    "- [公开](<private_dir/ok.md>)",
  ]
  expect(stripExcludedLinks([...strip, ...keep].join("\n"), new Set())).toBe(keep.join("\n"))
})

test("一致性：同一个名字，链接目标（行内 / <> / %编码 / 引用定义）剥不剥，和 isPrivateName 判定一致；裸写的不带路径的名字也一致", () => {
  const names = [
    "private_a.md", "PRIVATE_b.md", "Private_c.md", "private_!gone.md", "sub/private_d.md", "./Private_e.md#x",
    "project_private_repo.md", "note_PRIVATE_y.md", "project private_repo.md", "privately.md", "private_dir/ok.md", "私人（private_x）.md",
  ]
  for (const name of names) {
    const priv = isPrivateName(name.split("#")[0])
    const forms = [`- [x](<${name}>)`, `- [x](${encodeURI(name).replaceAll("%23", "#")})`, `[x]: <${name}>`]
    if (!/[\s/（]/.test(name)) forms.push(`- [x](${name})`, `- 见 ${name}`, `- 见（${name}）`)
    for (const line of forms) expect([line, stripExcludedLinks(line, new Set()) === ""]).toEqual([line, priv])
  }
})

test("P2-3 引用式：定义指向私人文件就剥定义行；只靠这个标签引用的行剥（标签空白 / 大小写归一），本行有行内链接的不剥（行内优先）", () => {
  const index = [
    "[safe](project_ok.md) — 普通材料",
    "[safe]: private_x.md",
    "- [摘要][My   Label]",
    "- [My label]",
    "[my label]: <./PRIVATE_y.md> \"t\"",
    "- [好的][ok]",
    "[ok]: project_ok.md",
  ].join("\n")
  expect(stripExcludedLinks(index, new Set())).toBe(["[safe](project_ok.md) — 普通材料", "- [好的][ok]", "[ok]: project_ok.md"].join("\n"))
})

test("P2-3 性能回归：未闭合括号 / 方括号的长行线性处理，不回溯", () => {
  for (const line of ["[x](".repeat(32000), "[".repeat(128000), "](".repeat(64000), "[a]".repeat(40000) + "\n[a]: private_x.md", "\\_".repeat(64000)]) {
    const t0 = performance.now()
    stripExcludedLinks(line, new Set(["a.md", "b.md"]), new Set(["c.md"]))
    expect(performance.now() - t0).toBeLessThan(200)
  }
})

test("P2-6 名单一变：旧快照不复用、被列进名单的缓存清掉、取文件前按当前名单再核一遍", async () => {
  const dir = fixtureDir({ "MEMORY.md": "- [甲](a.md)\n- [乙](b.md)", "a.md": "A", "b.md": "B" })
  let excludes = new Set<string>()
  const cache = new MemoryFileCache()
  const s = new MemorySnapshots(dir, cache, buildSnapshot, 60_000, async () => new Set(excludes))
  expect([...(await s.fresh()).keys()].sort()).toEqual(["MEMORY.md", "a.md", "b.md"])
  expect(cache.has(join(dir, "b.md"))).toBe(true)
  excludes = new Set(["b.md"])
  const got = await s.recent()                      // 60 秒内，但名单变了：不复用
  expect([...got.keys()].sort()).toEqual(["MEMORY.md", "a.md"])
  expect(got.get("MEMORY.md")).toBe("- [甲](a.md)")
  expect(cache.has(join(dir, "b.md"))).toBe(false)
  // 在途 / 排队的快照是旧名单读的：发之前照样按当前名单筛
  const stale = new Map([["MEMORY.md", "- [乙](b.md)\n- [甲](a.md)"], ["a.md", "A"], ["b.md", "B"]])
  expect(Object.fromEntries(screenSnapshot(stale, excludes))).toEqual({ "MEMORY.md": "- [甲](a.md)", "a.md": "A" })
})

test("P2-6 在途：构建读到一半名单变了，fresh / recent 等到快照后按此刻名单再核一遍，缓存同步清掉", async () => {
  const dir = fixtureDir({ "MEMORY.md": "- [甲](a.md)\n- [乙](b.md)", "a.md": "A", "b.md": "B" })
  let excludes = new Set<string>()
  const cache = new MemoryFileCache()
  const s = new MemorySnapshots(dir, cache, buildSnapshot, 60_000, async () => new Set(excludes))
  let release!: () => void
  const gate = new Promise<void>(r => { release = r })
  readHooks.onOpen = path => path.endsWith("a.md") ? gate : undefined
  try {
    const manifestP = s.fresh()
    const fetchP = s.recent()
    await Bun.sleep(20)
    excludes = new Set(["b.md"])                    // 构建还卡着时把 b.md 列进名单
    release()
    for (const got of [await manifestP, await fetchP]) {
      expect(Object.fromEntries(got)).toEqual({ "MEMORY.md": "- [甲](a.md)", "a.md": "A" })
    }
    expect(cache.has(join(dir, "b.md"))).toBe(false)
    expect(cache.has(join(dir, "a.md"))).toBe(true)
  } finally { readHooks.onOpen = undefined }
})
