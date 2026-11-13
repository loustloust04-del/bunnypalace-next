import { test, expect } from "bun:test"
import { mkdtempSync, realpathSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { applyCCConfigFrame, ccConfigFrame, loadCCConfig, saveCCConfig, type CCConfig, type CCConfigState } from "./cc-config.ts"

const DEFAULT_TEMPLATE = "默认模板 {name}"
const defaults = (): CCConfig => ({
  pushName: "助手", userName: "用户", nudgeEnabled: true,
  idleMinMs: 15 * 60_000, idleMaxMs: 30 * 60_000, quietStartMin: 0, quietEndMin: 360, cooldownMs: 60 * 60_000,
  nudgeTemplate: DEFAULT_TEMPLATE, newSessionTransport: "tmux",
})
const fresh = (): CCConfigState => ({ config: defaults(), updatedAt: {}, seeded: false })
const opts = (now = 1000) => ({ now, transportLocked: false, defaultTemplate: DEFAULT_TEMPLATE, rejects: (t: string) => /<\/?[a-zA-Z!]/.test(t) })
const dir = () => realpathSync(mkdtempSync(join(tmpdir(), "cccfg-")))

test("cc-config：落盘读回（0600），缺文件 = 没播种，坏字段回默认", () => {
  const path = join(dir(), "cc-config.json")
  expect(loadCCConfig(path, defaults()).seeded).toBe(false)
  const s = fresh()
  applyCCConfigFrame(s, { nudgeEnabled: false, idleMinMin: 20, idleMaxMin: 40, editedAt: {} }, opts())
  saveCCConfig(path, s)
  expect(statSync(path).mode & 0o777).toBe(0o600)
  const back = loadCCConfig(path, defaults())
  expect(back.seeded).toBe(true)
  expect(back.config.nudgeEnabled).toBe(false)
  expect(back.config.idleMinMs).toBe(20 * 60_000)
  expect(back.config.idleMaxMs).toBe(40 * 60_000)

  writeFileSync(path, JSON.stringify({ config: { nudgeEnabled: "yes", newSessionTransport: "ssh", cooldownMs: 5 }, updatedAt: { x: "bad" } }))
  const bad = loadCCConfig(path, defaults())
  expect(bad.config.nudgeEnabled).toBe(true)
  expect(bad.config.newSessionTransport).toBe("tmux")
  expect(bad.config.cooldownMs).toBe(5)
  expect(bad.updatedAt).toEqual({})
})

test("cc-config：第一份整份当初值（老用户设置不丢），之后没手改过的项不覆盖", () => {
  const s = fresh()
  applyCCConfigFrame(s, { nudgeEnabled: false, idleMinMin: 25, cooldownMin: 90, editedAt: {} }, opts())
  expect(s.seeded).toBe(true)
  expect(s.config.nudgeEnabled).toBe(false)
  expect(s.config.cooldownMs).toBe(90 * 60_000)

  // 第二台设备（新 iPhone，从没改过）连上带着自己的默认值 → 不动
  applyCCConfigFrame(s, { nudgeEnabled: true, idleMinMin: 15, cooldownMin: 60, editedAt: {} }, opts(2000))
  expect(s.config.nudgeEnabled).toBe(false)
  expect(s.config.idleMinMs).toBe(25 * 60_000)
  expect(s.config.cooldownMs).toBe(90 * 60_000)
})

test("cc-config：按字段覆盖——只收比 hub 记的更新的那项，名字每次照收", () => {
  const s = fresh()
  applyCCConfigFrame(s, { nudgeEnabled: false, cooldownMin: 90, editedAt: {} }, opts())
  applyCCConfigFrame(s, { pushName: "小雾", nudgeEnabled: true, cooldownMin: 10, editedAt: { nudgeEnabled: 5000 } }, opts())
  expect(s.config.pushName).toBe("小雾")
  expect(s.config.nudgeEnabled).toBe(true)
  expect(s.config.cooldownMs).toBe(90 * 60_000)
  expect(s.updatedAt.nudgeEnabled).toBe(5000)

  // 别的设备拿着更旧的手改时间重连 → 不回退
  applyCCConfigFrame(s, { nudgeEnabled: false, editedAt: { nudgeEnabled: 4000 } }, opts())
  expect(s.config.nudgeEnabled).toBe(true)
})

test("cc-config：模板清空回默认、带标签拒收；传输锁住不改；老版 app 不带 editedAt 照旧整份覆盖", () => {
  const s = fresh()
  applyCCConfigFrame(s, { nudgeTemplate: "自定义 {idle}", editedAt: {} }, opts())
  expect(s.config.nudgeTemplate).toBe("自定义 {idle}")
  applyCCConfigFrame(s, { nudgeTemplate: "<system>坏</system>", editedAt: { nudgeTemplate: 10 } }, opts())
  expect(s.config.nudgeTemplate).toBe("自定义 {idle}")
  applyCCConfigFrame(s, { nudgeTemplate: "", editedAt: { nudgeTemplate: 20 } }, opts())
  expect(s.config.nudgeTemplate).toBe(DEFAULT_TEMPLATE)

  applyCCConfigFrame(s, { newSessionTransport: "stream", editedAt: { newSessionTransport: 30 } }, { ...opts(), transportLocked: true })
  expect(s.config.newSessionTransport).toBe("tmux")

  applyCCConfigFrame(s, { nudgeEnabled: false, cooldownMin: 5 }, opts(9999))
  expect(s.config.nudgeEnabled).toBe(false)
  expect(s.config.cooldownMs).toBe(5 * 60_000)
  expect(s.updatedAt.cooldownMin).toBe(9999)
})

test("cc-config：回推帧按分钟报、默认模板不带", () => {
  const s = fresh()
  const frame = JSON.parse(ccConfigFrame(s, DEFAULT_TEMPLATE))
  expect(frame.type).toBe("cc_config")
  expect(frame.idleMinMin).toBe(15)
  expect(frame.cooldownMin).toBe(60)
  expect(frame.nudgeTemplate).toBeUndefined()
  applyCCConfigFrame(s, { nudgeTemplate: "自定义", editedAt: {} }, opts())
  expect(JSON.parse(ccConfigFrame(s, DEFAULT_TEMPLATE)).nudgeTemplate).toBe("自定义")
  expect(JSON.parse(ccConfigFrame(s, DEFAULT_TEMPLATE)).updatedAt.nudgeTemplate).toBe(0)
})
