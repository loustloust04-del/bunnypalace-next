/// 多台设备同时看一个 tmux 窗口时按谁的尺寸来（#046 审计 T51）。
///
/// 以前谁 attach / resize 就把整个窗口改成谁的尺寸：手机一看，Mac 那边被压成 52 列；Mac 再改回去，手机又乱。
/// 现在取「正在前台看」的那些设备里最小的那个（tmux 的 window-size smallest 规则），谁都不会画出界。
/// App 退后台时发 terminal_active=false，它就不算了（iOS 退后台 socket 还挂着、pane 也不 detach）；
/// 老 App 不发这一帧 = 一直算前台。

export interface TerminalSize { cols: number; rows: number }

export class TerminalSizeTracker<Client> {
  private sizes = new Map<string, Map<Client, TerminalSize>>()
  private inactive = new Set<Client>()

  set(session: string, client: Client, size: TerminalSize): void {
    let bySession = this.sizes.get(session)
    if (!bySession) { bySession = new Map(); this.sizes.set(session, bySession) }
    bySession.set(client, size)
  }

  /// 这台设备在看这个窗口吗（attach 时登记，detach / 断开时拿掉）——迟到的 resize 只认还在看的
  has(session: string, client: Client): boolean {
    return this.sizes.get(session)?.has(client) ?? false
  }

  remove(session: string, client: Client): void {
    const bySession = this.sizes.get(session)
    if (!bySession) return
    bySession.delete(client)
    if (bySession.size === 0) this.sizes.delete(session)
  }

  /// 连接断了：从所有窗口里拿掉，返回受影响的窗口
  removeClient(client: Client): string[] {
    this.inactive.delete(client)
    const touched: string[] = []
    for (const [session, bySession] of this.sizes) {
      if (bySession.delete(client)) touched.push(session)
      if (bySession.size === 0) this.sizes.delete(session)
    }
    return touched
  }

  /// 前后台切换：返回这台设备正在看的窗口（它们的有效尺寸可能变了）
  setActive(client: Client, active: boolean): string[] {
    if (active) this.inactive.delete(client)
    else this.inactive.add(client)
    const touched: string[] = []
    for (const [session, bySession] of this.sizes) {
      if (bySession.has(client)) touched.push(session)
    }
    return touched
  }

  /// 前台设备里最小的列数 / 行数；没有前台设备 → null（别动窗口，保持原样）
  effective(session: string): TerminalSize | null {
    const bySession = this.sizes.get(session)
    if (!bySession) return null
    let cols = Infinity
    let rows = Infinity
    for (const [client, size] of bySession) {
      if (this.inactive.has(client)) continue
      cols = Math.min(cols, size.cols)
      rows = Math.min(rows, size.rows)
    }
    return Number.isFinite(cols) ? { cols, rows } : null
  }
}
