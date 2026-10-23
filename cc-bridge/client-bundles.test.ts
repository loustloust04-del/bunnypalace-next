import { expect, test } from "bun:test"
import { bundleAllowed, parseAllowedBundles } from "./client-bundles.ts"

test("不设 / 空串 / 只有逗号空格 → 不检查（null），谁都放行", () => {
  for (const raw of [undefined, "", " , ,"]) {
    const allowed = parseAllowedBundles(raw)
    expect(allowed).toBeNull()
    expect(bundleAllowed(allowed, null)).toBe(true)
    expect(bundleAllowed(allowed, "com.susu.MemoryPalace.susu")).toBe(true)
  }
})

test("设了名单：只放行名单里的，朋友的 .susu 包和不报 bundle 的老包都拒", () => {
  const allowed = parseAllowedBundles(" com.susu.MemoryPalace.ios , com.susu.MemoryPalace ")
  expect([...allowed!]).toEqual(["com.susu.MemoryPalace.ios", "com.susu.MemoryPalace"])
  expect(bundleAllowed(allowed, "com.susu.MemoryPalace.ios")).toBe(true)
  expect(bundleAllowed(allowed, "com.susu.MemoryPalace")).toBe(true)
  expect(bundleAllowed(allowed, "com.susu.MemoryPalace.susu")).toBe(false)
  expect(bundleAllowed(allowed, null)).toBe(false)
  expect(bundleAllowed(allowed, "")).toBe(false)
})
