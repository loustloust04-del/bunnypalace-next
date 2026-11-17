import { afterEach, beforeEach, expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { GARDEN_TREE_LIST_BATCH, GardenTreeSync, RECEIPTS_FILE, SAVED_DIR, SYNC_DIR, treeHash, validTreePath } from "./garden-tree.ts"
import { FakeGarden } from "./garden-tree-testkit.ts"

// 花园记忆文件夹 ↔ 电脑上的 garden-memory/<楼层>/。假花园（app 那头的规矩缩小版）+ 真的 GardenTreeSync + 临时目录当 CC 家。全虚构

type Sock = { garden: FakeGarden; open: boolean }
let home = ""
let root = ""
let hub: GardenTreeSync<Sock>
const FLOOR = "星砚楼"
const CARD = "memory/cards/岚舟/ab12cd34.md"
const PERSONA = ".prompt/fields/characterDescription.txt"
const card = (tags: string, body: string) => `---\nid: ab12cd34-0000-4000-8000-000000000000\nstate: Archive\nabout: 岚舟\ntags: [${tags}]\npinned: no\n---\n\n${body}\n`

function newHub(): GardenTreeSync<Sock> {
  return new GardenTreeSync<Sock>((to, frame) => { if (to.open) queueMicrotask(() => to.garden.receive(frame)) }, { root, settleMs: 0, fallbackMs: 0 })
}

function connect(device = "device-a", name = "岚舟的手机", profileId = "floor-xingyan"): Sock {
  const sock = { open: true } as Sock
  sock.garden = new FakeGarden((frame) => queueMicrotask(() => { if (sock.open) hub.onFrame(sock, frame) }), FLOOR, device, name, profileId)
  return sock
}

function seed(g: FakeGarden): void {
  g.files.set("README.md", "# 花园记忆 · 星砚楼\n")
  g.files.set(CARD, card("皮影, 周三", "岚舟每周三去槐序巷皮影作坊学雕皮影。"))
  g.files.set("memory/self/刻纸鸢.md", "---\nname: 刻纸鸢\n---\n\n答应帮岚舟刻一只纸鸢。\n")
  g.files.set("memory/timeline/2026-11-12.md", "# 2026-11-12\n\n主调：雕皮影。\n")
  g.files.set(PERSONA, "星砚说话慢，爱用比喻。\n")
}

const disk = (path: string) => join(root, FLOOR, path)
const read = (path: string) => readFileSync(disk(path), "utf8")
const put = (path: string, content: string) => { mkdirSync(dirname(disk(path)), { recursive: true }); writeFileSync(disk(path), content) }
const receipts = () => readFileSync(disk(`${SYNC_DIR}/${RECEIPTS_FILE}`), "utf8")
const settle = () => new Promise((r) => setTimeout(r, 15))
/// 扫一遍盘、把改动送出去、等假花园回完
async function pump(): Promise<void> { hub.markDirty(); hub.tick(); await settle(); hub.tick(); await settle() }
function tree(dir = join(root, FLOOR), rel = ""): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const child = rel === "" ? e.name : `${rel}/${e.name}`
    if (child === SYNC_DIR) return []
    return e.isDirectory() ? tree(join(dir, e.name), child) : [child]
  }).sort()
}
const expectMirrors = (g: FakeGarden) => {
  expect(tree()).toEqual([...g.files.keys()].sort())
  for (const [path, content] of g.files) expect(read(path)).toBe(content)
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "garden-tree-"))
  root = join(home, "garden-memory")
  hub = newHub()
})
afterEach(() => rmSync(home, { recursive: true, force: true }))

test("导出一棵树：路径和内容原样落盘；再同步没变的不重写、花园里删了的删掉", async () => {
  const sock = connect()
  seed(sock.garden)
  const first = await sock.garden.sync()
  expect(first).toMatchObject({ ok: true, files: 5, written: 5, removed: 0, pending: 0 })
  expectMirrors(sock.garden)
  expect(readFileSync(join(root, ".gitignore"), "utf8")).toBe("*\n")

  const before = statSync(disk(CARD)).mtimeMs
  await new Promise((r) => setTimeout(r, 20))
  expect(await sock.garden.sync()).toMatchObject({ ok: true, unchanged: true })
  sock.garden.files.set("memory/self/刻纸鸢.md", "---\nname: 刻纸鸢\n---\n\n答应帮岚舟刻两只纸鸢。\n")
  sock.garden.files.delete("memory/timeline/2026-11-12.md")
  expect(await sock.garden.sync()).toMatchObject({ ok: true, written: 1, removed: 1 })
  expect(statSync(disk(CARD)).mtimeMs).toBe(before)
  expectMirrors(sock.garden)
  expect(existsSync(disk("memory/timeline"))).toBe(false)
})

test("走通：改一条记忆条目的 tags、改助手设定、新建一条 → 送回花园落下 → 两边一致 → 回执三笔", async () => {
  const sock = connect()
  const g = sock.garden
  seed(g)
  await g.sync()
  put(CARD, card("皮影, 周三, 槐序巷", "岚舟每周三去槐序巷皮影作坊学雕皮影。"))
  put(PERSONA, "星砚说话慢，爱用比喻，不催人。")
  put("memory/cards/岚舟/新条目.md", "---\ntags: [纸鸢]\n---\n\n岚舟想要一只燕子形的纸鸢。")
  await pump()

  expect(g.files.get(CARD)).toContain("tags: [皮影, 周三, 槐序巷]")
  expect(g.files.get(PERSONA)).toBe("星砚说话慢，爱用比喻，不催人。\n")
  expect(g.files.get("memory/cards/岚舟/c0000001.md")).toContain("燕子形的纸鸢")
  // 新建的那条文件名换成了它的编号；助手设定换成了花园落下后的样子（多了行尾）
  expect(existsSync(disk("memory/cards/岚舟/新条目.md"))).toBe(false)
  expectMirrors(g)

  const again = await g.sync()
  expect(again).toMatchObject({ ok: true, written: 0, removed: 0, pending: 0 })
  expectMirrors(g)
  const text = receipts()
  expect(text.match(/· 落下了 ·/g)?.length).toBe(3)
  expect(text).toContain("memory/cards/岚舟/新条目.md → memory/cards/岚舟/c0000001.md")
  expect(text).toContain("## 还没落进花园（0）")
})

test("冲突：花园里那份先变了 → 不落，文件恢复成花园的，CC 写的另存在回执旁边", async () => {
  const sock = connect()
  const g = sock.garden
  seed(g)
  await g.sync()
  // 花园先改了（还没同步过来），CC 照旧的那一版改
  g.files.set(CARD, card("皮影, 周四", "岚舟改到每周四去槐序巷皮影作坊。"))
  put(CARD, card("皮影, 周三, CC 加的", "岚舟每周三去槐序巷皮影作坊学雕皮影。"))
  await pump()
  expect(read(CARD)).toBe(g.files.get(CARD)!)
  expect(g.files.get(CARD)).toContain("周四")
  const saved = readdirSync(disk(`${SYNC_DIR}/${SAVED_DIR}`))
  expect(saved.length).toBe(1)
  expect(readFileSync(disk(`${SYNC_DIR}/${SAVED_DIR}/${saved[0]}`), "utf8")).toContain("CC 加的")
  expect(receipts()).toContain(`· 冲突，没落 · ${CARD}`)
  expect(receipts()).toContain(`${SYNC_DIR}/${SAVED_DIR}/${saved[0]}`)

  // 另一条路：CC 改了还没送，花园的新版先同步过来
  g.files.set(PERSONA, "星砚最近话多了。\n")
  put(PERSONA, "CC 想写的设定。")
  expect(await g.sync()).toMatchObject({ ok: true, written: 1 })
  expect(read(PERSONA)).toBe("星砚最近话多了。\n")
  expect(readdirSync(disk(`${SYNC_DIR}/${SAVED_DIR}`)).length).toBe(2)
  expect(receipts().match(/· 冲突，没落 ·/g)?.length).toBe(2)
  expectMirrors(g)
})

test("只读：改了 / 删了时间轴 → 恢复成花园的 + 回执", async () => {
  const sock = connect()
  const g = sock.garden
  seed(g)
  await g.sync()
  const timeline = "memory/timeline/2026-11-12.md"
  put(timeline, "# 2026-11-12\n\nCC 改的主调。\n")
  rmSync(disk("README.md"))
  put("随手记.md", "不在树里的文件")
  await pump()
  expect(read(timeline)).toBe(g.files.get(timeline)!)
  expect(read("README.md")).toBe(g.files.get("README.md")!)
  expect(existsSync(disk("随手记.md"))).toBe(false)
  expect(receipts().match(/· 只读，没落 ·/g)?.length).toBe(3)
  expectMirrors(g)
})

test("app 不在线：改动留在盘上排着，回执看得出还没落；hub 重启不丢；连上以后送到并落下", async () => {
  const sock = connect()
  const g = sock.garden
  seed(g)
  await g.sync()
  sock.open = false
  hub.onClose(sock)
  put(PERSONA, "离线时改的设定。")
  put("memory/cards/岚舟/离线新条目.md", "岚舟周末要去放纸鸢。")
  await pump()
  expect(read(PERSONA)).toBe("离线时改的设定。")
  expect(receipts()).toContain("## 还没落进花园（2）")
  expect(receipts()).toContain(`- ${PERSONA} · 修改 · 花园没连着，连上就送`)
  expect(receipts()).toContain("- memory/cards/岚舟/离线新条目.md · 新建 · 花园没连着，连上就送")
  expect(g.files.get(PERSONA)).toBe("星砚说话慢，爱用比喻。\n")

  hub = newHub()   // hub 重启：什么都不记得，盘上的还在
  await pump()
  expect(receipts()).toContain("## 还没落进花园（2）")

  const back = connect()
  back.garden.files = g.files
  expect(await back.garden.sync()).toMatchObject({ ok: true, unchanged: true, pending: 2 })
  await pump()
  expect(g.files.get(PERSONA)).toBe("离线时改的设定。\n")
  expect([...g.files.keys()].filter((p) => p.startsWith("memory/cards/岚舟/c")).length).toBe(1)
  expect(receipts()).toContain("## 还没落进花园（0）")
  expectMirrors(g)
})

test("每次询问：先回等她点，文件保持 CC 改后的样子；她点了才落 / 拒了恢复", async () => {
  const sock = connect()
  const g = sock.garden
  seed(g)
  await g.sync()
  g.policy = () => "ask"
  put(CARD, card("皮影, 等她点", "岚舟每周三去槐序巷皮影作坊学雕皮影。"))
  put(PERSONA, "等她点的设定。")
  await pump()
  expect(g.waiting.size).toBe(2)
  expect(read(PERSONA)).toBe("等她点的设定。")
  expect(receipts()).toContain(`- ${PERSONA} · 修改 · 已送到花园，等她点允许（等她点）`)
  const sentSoFar = g.seen.filter((f) => f.type === "garden_tree_changes").flatMap((f) => f.changes).length
  expect(sentSoFar).toBe(2)
  await pump()
  expect(g.seen.filter((f) => f.type === "garden_tree_changes").flatMap((f) => f.changes).length).toBe(sentSoFar)   // 没点之前不重复送

  const ids = [...g.waiting.values()]
  g.answer(ids.find((c) => c.path === CARD)!.id, true)
  g.answer(ids.find((c) => c.path === PERSONA)!.id, false)
  await settle()
  expect(g.files.get(CARD)).toContain("等她点")
  expect(read(PERSONA)).toBe("星砚说话慢，爱用比喻。\n")
  expect(receipts()).toContain(`· 落下了 · ${CARD}`)
  expect(receipts()).toContain(`· 被拒，没落 · ${PERSONA}`)
  expect(readFileSync(disk(`${SYNC_DIR}/${SAVED_DIR}/${readdirSync(disk(`${SYNC_DIR}/${SAVED_DIR}`))[0]}`), "utf8")).toBe("等她点的设定。")
  expectMirrors(g)
})

test("格式不对：回执带着是哪一行，文件恢复，CC 写的另存", async () => {
  const sock = connect()
  const g = sock.garden
  seed(g)
  await g.sync()
  put(CARD, "---\n格式坏: 这一行\n---\n\n正文\n")
  await pump()
  expect(receipts()).toContain(`· 没落下 · ${CARD}：这一行认不出来：格式坏: 这一行`)
  expectMirrors(g)
})

test("等她点的时候 CC 又改了同一份：只认后来那一版", async () => {
  const sock = connect()
  const g = sock.garden
  seed(g)
  await g.sync()
  g.policy = () => "ask"
  put(PERSONA, "第一版。")
  await pump()
  put(PERSONA, "第二版。")
  await pump()
  expect(g.waiting.size).toBe(1)
  g.answer([...g.waiting.keys()][0], true)
  await settle()
  expect(g.files.get(PERSONA)).toBe("第二版。\n")
  expectMirrors(g)
})

test("两台设备不互相盖：另一台同名楼层被拒；说了接手才换主，并且换主后回执送到新的那台", async () => {
  const a = connect()
  seed(a.garden)
  await a.garden.sync()
  const b = connect("device-b", "测试机")
  b.garden.files.set("memory/self/别的.md", "测试机上的记忆\n")
  expect(await b.garden.sync()).toMatchObject({ ok: false, reason: "other_device", owner_name: "岚舟的手机" })
  expectMirrors(a.garden)
  expect(await b.garden.sync(true)).toMatchObject({ ok: true, written: 1 })
  expectMirrors(b.garden)
  expect(await a.garden.sync()).toMatchObject({ ok: false, reason: "other_device", owner_name: "测试机" })
  put("memory/self/别的.md", "CC 改的\n")
  await pump()
  expect(b.garden.files.get("memory/self/别的.md")).toBe("CC 改的\n")
  expect(a.garden.seen.some((f) => f.type === "garden_tree_changes")).toBe(false)
})

test("老格式的文件夹（没有同步状态）：照花园的整份换掉，多出来的不当成 CC 新写的", async () => {
  mkdirSync(join(root, FLOOR), { recursive: true })
  writeFileSync(join(root, FLOOR, "模型船.md"), "- 老格式的一份\n")
  writeFileSync(join(root, FLOOR, "README.md"), "老说明")
  const sock = connect()
  seed(sock.garden)
  expect(await sock.garden.sync()).toMatchObject({ ok: true, files: 5 })
  expectMirrors(sock.garden)
  await pump()
  expect(sock.garden.seen.some((f) => f.type === "garden_tree_changes")).toBe(false)
})

test("关掉开关：这台的楼层文件夹删掉；别的设备的删不了", async () => {
  const a = connect()
  seed(a.garden)
  await a.garden.sync()
  const b = connect("device-b", "测试机")
  b.garden.remove()
  await settle()
  expect(existsSync(join(root, FLOOR, "README.md"))).toBe(true)
  a.garden.remove()
  await settle()
  expect(existsSync(join(root, FLOOR))).toBe(false)
})

test("关掉开关时 CC 还有没落进花园的修改：树拿掉，写过的另存、每一处进回执，不送回花园；再打开照花园的整份摆回来", async () => {
  const sock = connect()
  seed(sock.garden)
  await sock.garden.sync()
  sock.open = false
  hub.onClose(sock)
  put(PERSONA, "关同步前 CC 改的设定。\n")
  put("memory/cards/岚舟/新的.md", "岚舟想学做纸鸢。\n")
  rmSync(disk("memory/self/刻纸鸢.md"))
  const again = connect()
  seed(again.garden)
  again.garden.remove()
  await settle()
  expect(tree()).toEqual([])
  const saved = readdirSync(disk(`${SYNC_DIR}/${SAVED_DIR}`)).map((name) => readFileSync(disk(`${SYNC_DIR}/${SAVED_DIR}/${name}`), "utf8")).sort()
  expect(saved).toEqual(["关同步前 CC 改的设定。\n", "岚舟想学做纸鸢。\n"].sort())
  const text = receipts()
  for (const path of [PERSONA, "memory/cards/岚舟/新的.md", "memory/self/刻纸鸢.md"]) expect(text).toContain(path)
  expect(text).toContain("花园那边关了同步")
  await pump()
  expect(again.garden.seen.some((f) => f.type === "garden_tree_changes")).toBe(false)
  expect(await again.garden.sync()).toMatchObject({ ok: true, files: 5 })
  expectMirrors(again.garden)
  await pump()
  expect(again.garden.seen.some((f) => f.type === "garden_tree_changes")).toBe(false)
  expect(receipts()).toContain("花园那边关了同步")
  expect(readdirSync(disk(`${SYNC_DIR}/${SAVED_DIR}`)).length).toBe(2)
})

test("楼层改了名字：同一台同一层楼的文件夹跟着改名，待落的修改不丢", async () => {
  const sock = connect()
  seed(sock.garden)
  await sock.garden.sync()
  sock.open = false
  hub.onClose(sock)
  put(PERSONA, "改名前 CC 写的。")
  const renamed = { open: true } as Sock
  renamed.garden = new FakeGarden((frame) => queueMicrotask(() => hub.onFrame(renamed, frame)), "槐序楼")
  renamed.garden.files = sock.garden.files
  expect(await renamed.garden.sync()).toMatchObject({ ok: true })
  expect(existsSync(join(root, FLOOR))).toBe(false)
  await settle()
  expect(renamed.garden.files.get(PERSONA)).toBe("改名前 CC 写的。\n")
  expect(readFileSync(join(root, "槐序楼", PERSONA), "utf8")).toBe("改名前 CC 写的。\n")
})

test("量大：清单和要的清单分批走，一份不少", async () => {
  const sock = connect()
  const n = GARDEN_TREE_LIST_BATCH * 2 + 7
  for (let i = 0; i < n; i++) sock.garden.files.set(`memory/cards/岚舟/k${String(i).padStart(7, "0")}.md`, `第 ${i} 张：${"皮影".repeat(300)}\n`)
  expect(await sock.garden.sync()).toMatchObject({ ok: true, files: n, written: n })
  expect(sock.garden.seen.filter((f) => f.type === "garden_tree_need" && Array.isArray(f.paths)).length).toBe(3)
  expect(tree().length).toBe(n)
})

test("往外跑的路径、链接：不写", async () => {
  for (const bad of ["../外面.md", "/etc/x", "memory//x.md", "memory/../x.md", "_sync/.state.json", "a\\b", ""]) expect(validTreePath(bad)).toBe(false)
  expect(validTreePath(".prompt/fields/characterDescription.txt")).toBe(true)
  const sock = connect()
  seed(sock.garden)
  await sock.garden.sync()
  // CC 家里有人把 memory/self 换成了指向外面的链接
  const outside = join(home, "外面")
  mkdirSync(outside)
  rmSync(disk("memory/self"), { recursive: true })
  symlinkSync(outside, disk("memory/self"))
  sock.garden.files.set("memory/self/刻纸鸢.md", "新内容\n")
  await sock.garden.sync()
  expect(readdirSync(outside)).toEqual([])
  // 指纹两头要算出同一个：app 那边的 GardenTree.hash（GardenMemorySyncTests 钉着同一个值）
  expect(treeHash("岚舟每周三去槐序巷皮影作坊学雕皮影。\n")).toBe("8a6ac19ade6c7392754b4e41f0cab070")
})
