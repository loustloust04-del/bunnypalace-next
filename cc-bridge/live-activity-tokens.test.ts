import { test, expect } from "bun:test"
import { mkdtempSync, writeFileSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import {
  emptyLaTokenStore, registerLaToken, unregisterLaToken, loadLaTokens, saveLaTokens,
} from "./live-activity-tokens.ts"

const updateMsg = (over: Record<string, unknown> = {}) => ({
  type: "register_la_token", kind: "update",
  activity_id: "ACT-1", token: "aabbcc", session_name: "mp-cc",
  install_id: "INSTALL-1", env: "sandbox", preview: "full", ...over,
})

const startMsg = (over: Record<string, unknown> = {}) => ({
  type: "register_la_token", kind: "start",
  token: "ddeeff", install_id: "INSTALL-1", env: "production", preview: "hidden", ...over,
})

test("register update token 落 update 表（按 activity_id）", () => {
  const store = emptyLaTokenStore()
  expect(registerLaToken(store, updateMsg())).toEqual({ ok: true })
  const rec = store.update["ACT-1"]
  expect(rec.token).toBe("aabbcc")
  expect(rec.session_name).toBe("mp-cc")
  expect(rec.install_id).toBe("INSTALL-1")
  expect(rec.env).toBe("sandbox")
  expect(rec.preview).toBe("full")
  expect(typeof rec.updated_at).toBe("number")
  expect(Object.keys(store.start)).toEqual([])
})

test("register start token 落 start 表（按 install_id）", () => {
  const store = emptyLaTokenStore()
  expect(registerLaToken(store, startMsg()).ok).toBe(true)
  expect(store.start["INSTALL-1"].token).toBe("ddeeff")
  expect(store.start["INSTALL-1"].preview).toBe("hidden")
  expect(Object.keys(store.update)).toEqual([])
})

test("同一 activity 换 token = 替换旧值，不追加；replaced 报旧 token", () => {
  const store = emptyLaTokenStore()
  registerLaToken(store, updateMsg())
  const res = registerLaToken(store, updateMsg({ token: "999999", previous_token: "aabbcc" }))
  expect(res).toEqual({ ok: true, replaced: "aabbcc" })
  expect(Object.keys(store.update)).toEqual(["ACT-1"])
  expect(store.update["ACT-1"].token).toBe("999999")
  expect(store.update["ACT-1"].previous_token).toBe("aabbcc")
})

test("M5 ⑤：started_at 首次注册即落；同 activity 换 token 不重置（否则 8h 换岛永远等不到）", () => {
  const store = emptyLaTokenStore()
  registerLaToken(store, updateMsg())
  const first = store.update["ACT-1"].started_at
  expect(typeof first).toBe("number")
  expect(first).toBe(store.update["ACT-1"].updated_at)
  registerLaToken(store, updateMsg({ token: "999999" }))
  expect(store.update["ACT-1"].started_at).toBe(first)
  // 另一个 activity 是另一个岛，自己的岁数自己算
  registerLaToken(store, updateMsg({ activity_id: "ACT-2" }))
  expect(store.update["ACT-2"].started_at).toBe(store.update["ACT-2"].updated_at)
})

test("重复报同一个 token 不算 replace", () => {
  const store = emptyLaTokenStore()
  registerLaToken(store, updateMsg())
  expect(registerLaToken(store, updateMsg())).toEqual({ ok: true })
})

test("preview 缺省 hidden（跟 alert 路径的缺省 full 故意不对称）", () => {
  const store = emptyLaTokenStore()
  registerLaToken(store, updateMsg({ preview: undefined }))
  expect(store.update["ACT-1"].preview).toBe("hidden")
  registerLaToken(store, updateMsg({ activity_id: "ACT-2", preview: "garbage" }))
  expect(store.update["ACT-2"].preview).toBe("hidden")
})

test("env 非法 → 拒绝且不落表", () => {
  const store = emptyLaTokenStore()
  const res = registerLaToken(store, updateMsg({ env: "staging" }))
  expect(res.ok).toBe(false)
  expect(res.reason).toContain("bad_env")
  expect(Object.keys(store.update)).toEqual([])
})

test("缺必填字段 → 拒绝并给出 reason", () => {
  const store = emptyLaTokenStore()
  expect(registerLaToken(store, updateMsg({ kind: "nope" })).reason).toContain("bad_kind")
  expect(registerLaToken(store, updateMsg({ token: "" })).reason).toBe("missing_token")
  expect(registerLaToken(store, updateMsg({ install_id: undefined })).reason).toBe("missing_install_id")
  expect(registerLaToken(store, updateMsg({ activity_id: undefined })).reason).toBe("missing_activity_id")
  expect(registerLaToken(store, updateMsg({ session_name: undefined })).reason).toBe("missing_session_name")
  expect(registerLaToken(store, startMsg({ install_id: undefined })).reason).toBe("missing_install_id")
  expect(store).toEqual(emptyLaTokenStore())
})

test("unregister 删对应表的记录；幂等；kind/id 缺失 → ok:false", () => {
  const store = emptyLaTokenStore()
  registerLaToken(store, updateMsg())
  registerLaToken(store, startMsg())

  expect(unregisterLaToken(store, { kind: "update", activity_id: "ACT-1" })).toEqual({ ok: true })
  expect(store.update["ACT-1"]).toBeUndefined()
  expect(store.start["INSTALL-1"]).toBeDefined()
  expect(unregisterLaToken(store, { kind: "update", activity_id: "ACT-1" })).toEqual({ ok: true })

  expect(unregisterLaToken(store, { kind: "start", install_id: "INSTALL-1" })).toEqual({ ok: true })
  expect(store.start["INSTALL-1"]).toBeUndefined()

  expect(unregisterLaToken(store, { kind: "update" })).toEqual({ ok: false })
  expect(unregisterLaToken(store, {})).toEqual({ ok: false })
})

test("load 缺文件 / 坏 JSON / 坏形状 → 空 store，不抛", () => {
  const dir = mkdtempSync(join(tmpdir(), "la-tokens-test-"))
  const missing = join(dir, "nope.json")
  expect(loadLaTokens(missing)).toEqual(emptyLaTokenStore())
  expect(existsSync(missing)).toBe(false)   // load 绝不落盘

  const broken = join(dir, "broken.json")
  writeFileSync(broken, "{ not json")
  expect(loadLaTokens(broken)).toEqual(emptyLaTokenStore())

  const junk = join(dir, "junk.json")
  writeFileSync(junk, JSON.stringify({ update: { "ACT-1": { nope: 1 } }, start: "wat" }))
  expect(loadLaTokens(junk)).toEqual(emptyLaTokenStore())
})

test("save → load round trip", () => {
  const dir = mkdtempSync(join(tmpdir(), "la-tokens-test-"))
  const path = join(dir, "la-tokens.json")
  const store = emptyLaTokenStore()
  registerLaToken(store, updateMsg())
  registerLaToken(store, startMsg())
  saveLaTokens(path, store)
  expect(loadLaTokens(path)).toEqual(store)
})

test("topic：合法的落记录，坏的丢掉，不带的不落键（老记录形状不变）", () => {
  const store = emptyLaTokenStore()
  registerLaToken(store, updateMsg({ topic: "com.susu.MemoryPalace.susu" }))
  registerLaToken(store, startMsg({ topic: "com.susu.MemoryPalace.susu.push-type.liveactivity" }))
  registerLaToken(store, updateMsg({ activity_id: "ACT-2" }))
  expect(store.update["ACT-1"].topic).toBe("com.susu.MemoryPalace.susu")
  expect("topic" in store.start["INSTALL-1"]).toBe(false)
  expect("topic" in store.update["ACT-2"]).toBe(false)
})

test("老 la-tokens.json（无 topic）照读，带 topic 的往返不丢", () => {
  const p = join(mkdtempSync(join(tmpdir(), "la-topic-")), "la-tokens.json")
  writeFileSync(p, JSON.stringify({
    update: { "ACT-1": { token: "aa", session_name: "mp-cc", install_id: "I", env: "sandbox", preview: "full", updated_at: 1 } },
    start: {},
  }))
  expect(loadLaTokens(p).update["ACT-1"].topic).toBeUndefined()

  const store = emptyLaTokenStore()
  registerLaToken(store, startMsg({ topic: "com.susu.MemoryPalace.susu" }))
  saveLaTokens(p, store)
  expect(loadLaTokens(p).start["INSTALL-1"].topic).toBe("com.susu.MemoryPalace.susu")
})
