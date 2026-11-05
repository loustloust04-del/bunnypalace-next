// Team ID 取值链：MP_APNS_TEAM_ID → Config/Signing.local.xcconfig 的 DEVELOPMENT_TEAM → null（推送关掉）。
// 源码里不许再有回落值；临时 xcconfig 都写在 tmpdir，不读本机那份。
import { afterEach, expect, test } from "bun:test"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { __setAPNsTestHooks, resolveTeamId, sendAPNs } from "./apns.ts"
import { installTransport, respondWith, TEST_TEAM_ID } from "./apns-fake-transport.ts"

afterEach(() => { __setAPNsTestHooks() })

const dir = mkdtempSync(join(tmpdir(), "apns-team-"))
function xcconfig(body: string): string {
  const p = join(dir, `${Math.random().toString(36).slice(2)}.xcconfig`)
  writeFileSync(p, body)
  return p
}
const missing = join(dir, "nope.xcconfig")

test("环境变量优先于 xcconfig", () => {
  expect(resolveTeamId({ MP_APNS_TEAM_ID: "ENVTEAM001" }, xcconfig("DEVELOPMENT_TEAM = FILETEAM01\n"))).toBe("ENVTEAM001")
})

test("没设环境变量 → 读 DEVELOPMENT_TEAM，去行尾注释，同键后写的生效", () => {
  const p = xcconfig("// DEVELOPMENT_TEAM = COMMENT01\nDEVELOPMENT_TEAM = FIRST00001\nMP_BUNDLE_ID_BASE = com.example.x\nDEVELOPMENT_TEAM = SECOND0001 // 本机\n")
  expect(resolveTeamId({}, p)).toBe("SECOND0001")
})

test("都没有 / 留空 / 格式不对 → null，不回落任何写死的值", () => {
  expect(resolveTeamId({}, missing)).toBeNull()
  expect(resolveTeamId({}, xcconfig("DEVELOPMENT_TEAM =\n"))).toBeNull()
  expect(resolveTeamId({}, xcconfig("DEVELOPMENT_TEAM = $(INHERITED_TEAM)\n"))).toBeNull()
  // 环境变量设了但不像 Team ID：不悄悄改读文件，直接关
  expect(resolveTeamId({ MP_APNS_TEAM_ID: "bad" }, xcconfig("DEVELOPMENT_TEAM = FILETEAM01\n"))).toBeNull()
})

test("JWT 的 iss 就是取到的 Team ID", async () => {
  const t = installTransport(respondWith(200))
  await sendAPNs({ token: "a".repeat(64) }, "t", "b", "chat1")
  const jwt = t.clients[0].headers!.authorization.replace(/^bearer /, "")
  const payload = JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString())
  expect(payload.iss).toBe(TEST_TEAM_ID)
})
