/// `MP_CC_ALLOWED_BUNDLES`：非本机连接只放行这些 app（bundle id，逗号分隔）。不设 = 不检查。
///
/// 防的是「别人的包拿到了我的口令」（比如帮朋友装机时误扫了自己的配对码）：
/// 朋友的 `.susu` 包连我的 hub 会被直接断开。bundle 是客户端自报的，拦不住拿口令手写客户端冒充——真正的锁仍是口令。
export function parseAllowedBundles(raw: string | undefined): Set<string> | null {
  const list = (raw ?? "").split(",").map((s) => s.trim()).filter(Boolean)
  return list.length > 0 ? new Set(list) : null
}

export function bundleAllowed(allowed: Set<string> | null, bundle: string | null): boolean {
  return allowed === null || (bundle !== null && allowed.has(bundle))
}
