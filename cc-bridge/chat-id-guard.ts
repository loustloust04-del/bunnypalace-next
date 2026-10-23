// CC 回 reply 时要把 36 位 chat_id 原样抄回来，偶尔会错一位（09-17 小克把 3E7994B7… 抄成
// 3E7194B7…：app 找不到对话按设计丢，hub 还按「没人在看」推了 APNs，粟粟盯着屏幕等不到）。
// 已知会话里有唯一的近似匹配就纠正过去；优先该 session 最近对话；没有近似就原样放行
//（hub 刚重启缓冲为空时不能拒）。
export function correctChatId(id: string, known: Iterable<string>, preferred?: string): { id: string; corrected: boolean } {
  const set = new Set([...known].filter(Boolean))
  if (set.has(id)) return { id, corrected: false }
  if (preferred && near(id, preferred)) return { id: preferred, corrected: true }
  const cands = [...set].filter(k => near(id, k))
  return cands.length === 1 ? { id: cands[0], corrected: true } : { id, corrected: false }
}

const MAX_DIFF = 2
function near(a: string, b: string): boolean {
  if (a.length !== b.length || a === b) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i] && ++diff > MAX_DIFF) return false
  return true
}
