import { timedSyncFs } from "./block-ledger"
const { existsSync, readFileSync, writeFileSync, mkdirSync, renameSync } = timedSyncFs("voice-calls ")
import { dirname } from "node:path"

export type CallStatus = "ringing" | "accepted" | "declined" | "canceled" | "missed" | "ended"
export interface VoiceCall {
  call_id: string; chat_id: string; install_id: string; session: string; caller: string
  created_at: number; expires_at: number; status: CallStatus
}
export interface CallDevice { install_id: string; token: string; env: "sandbox" | "production"; topic: string }
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const active = (c: VoiceCall) => c.status === "ringing" || c.status === "accepted"
/** 独立、持久的 VoIP 注册和呼叫账本；不读取普通 APNs token。 */
export class VoiceCalls {
  private calls: VoiceCall[] = []
  private devices = new Map<string, CallDevice>()
  constructor(private path: string | undefined, private now = () => Date.now()) {}
  load() {
    if (!this.path || !existsSync(this.path)) return
    const db = JSON.parse(readFileSync(this.path, "utf8"))
    if (db.version !== 1 || !Array.isArray(db.calls) || !Array.isArray(db.devices)) throw new Error("call ledger damaged")
    this.calls = db.calls.filter((c: VoiceCall) => uuid.test(c.call_id) && typeof c.chat_id === "string" && Number.isFinite(c.expires_at)).slice(-100)
    // 重启不能恢复已失去音频宿主的 accepted；ringing 保留到 TTL。
    this.calls.forEach(c => { if (c.status === "accepted") c.status = "ended" })
    for (const d of db.devices) this.register(d, false)
    this.expire(); this.save()
  }
  private save() {
    if (!this.path) return
    mkdirSync(dirname(this.path), { recursive: true })
    writeFileSync(this.path + ".tmp", JSON.stringify({ version: 1, calls: this.calls, devices: [...this.devices.values()] }), { mode: 0o600 })
    renameSync(this.path + ".tmp", this.path)
  }
  register(d: any, save = true) {
    if (!uuid.test(d.install_id ?? "")) throw new Error("invalid install_id")
    if (d.enabled === false) { this.devices.delete(d.install_id) }
    else {
      if (!/^[0-9a-f]{64,200}$/i.test(d.token ?? "") || !/^[A-Za-z0-9.-]{3,200}$/.test(d.topic ?? "") || !["sandbox", "production"].includes(d.env)) throw new Error("invalid VoIP registration")
      this.devices.set(d.install_id, { install_id: d.install_id, token: d.token, topic: d.topic, env: d.env })
    }
    if (save) this.save()
  }
  device(id: string) { return this.devices.get(id) }
  expire(): VoiceCall[] {
    const changed = this.calls.filter(c => c.status === "ringing" && c.expires_at <= this.now())
    changed.forEach(c => { c.status = "missed" }); if (changed.length) this.save()
    return changed.map(c => ({ ...c }))
  }
  create(call_id: string, chat_id: string, install_id: string, session: string, boundChat: string | undefined, caller: string): { call: VoiceCall; fresh: boolean } {
    this.expire()
    if (!session || chat_id !== boundChat) throw new Error("call must target this session's bound chat")
    if (!uuid.test(call_id) || !uuid.test(chat_id)) throw new Error("invalid call/chat id")
    const prior = this.calls.find(c => c.call_id === call_id)
    if (prior) {
      if (prior.session !== session || prior.chat_id !== chat_id || prior.install_id !== install_id) throw new Error("call id collision")
      return { call: { ...prior }, fresh: false }
    }
    if (!this.devices.has(install_id)) throw new Error("device has not enabled native calls")
    if (this.calls.some(c => active(c))) throw new Error("another call is active")
    const call: VoiceCall = { call_id, chat_id, install_id, session, caller: caller.replace(/[\r\n]/g, " ").slice(0, 80) || session, created_at: this.now(), expires_at: this.now() + 60_000, status: "ringing" }
    this.calls = this.calls.slice(-99); this.calls.push(call); this.save()
    return { call: { ...call }, fresh: true }
  }
  get(id: string) { this.expire(); const c = this.calls.find(c => c.call_id === id); return c ? { ...c } : undefined }
  forDevice(id: string) { this.expire(); return this.calls.filter(c => c.install_id === id).slice(-20).map(c => ({ ...c })) }
  transition(id: string, event: "accept" | "decline" | "hangup" | "cancel" | "fail", actor: { install_id?: string; session?: string }): VoiceCall {
    this.expire(); const c = this.calls.find(c => c.call_id === id)
    if (!c || (actor.install_id !== c.install_id && actor.session !== c.session)) throw new Error("call not owned by this actor")
    if (event === "cancel" && actor.session !== c.session) throw new Error("only caller can cancel")
    if (["accept", "decline", "hangup"].includes(event) && actor.install_id !== c.install_id) throw new Error("only target device can answer/end")
    if (c.status === "ringing") c.status = event === "accept" ? "accepted" : event === "decline" ? "declined" : event === "cancel" ? "canceled" : "missed"
    else if (c.status === "accepted" && ["hangup", "cancel", "fail"].includes(event)) c.status = "ended"
    this.save(); return { ...c }
  }
}
