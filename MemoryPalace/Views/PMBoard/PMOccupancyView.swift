#if PERSONAL_APPS
#if DEBUG
import SwiftUI

// MARK: - pmBoard「占用」tab（docs/plan-dev-subapp-v2.md P1-b）
// 横幅（冻结 / 工位暂停编译）→ 🔨 编译 → 🔀 合并 → 📱 设备 → ▦ 工位。名字都能点进那个人的详情（人走了也能点：详情给恢复命令）。

struct PMOccupancyView: View {
    let open: (String) -> Void
    @State private var store = PMBoardStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let o = store.occupancy {
                    if let e = store.occupancyError { PMNotice(text: e) }
                    if let f = o.build.frozen { PMNotice(text: "⏸ 编译冻结：\(f)") }
                    if o.build.zonePaused { PMNotice(text: "⏸ 工位暂停本地编译（只有集成区在编）") }
                    build(o.build)
                    merges(o.merges)
                    devices(o.devices)
                    zones(o.zones)
                    Text("Mac 上 \(o.generatedText) 的数据")
                        .font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                } else if let e = store.occupancyError {
                    PMEmpty(icon: "wifi.exclamationmark", text: e)
                } else if !store.bridgeConnected {
                    PMEmpty(icon: "wifi.slash", text: "桥没连上（记忆花园没连到 Mac 上的 hub）")
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .refreshable { store.requestOccupancy() }
    }

    // MARK: 🔨 编译

    private func build(_ b: PMOccBuild) -> some View {
        PMCard(title: "🔨 编译") {
            if let h = b.holder {
                HStack(spacing: 6) {
                    Text(h.state == "overload" ? "超载等着" : "在编").foregroundStyle(h.state == "overload" ? PMState.wait.color : PMState.busy.color)
                    PMWhoLabel(who: h.who, open: open)
                    Text("· \(h.where) · \(PMTime.ago(h.since).replacingOccurrences(of: "前", with: ""))").foregroundStyle(Theme.textMuted)
                }
                .font(.system(size: Theme.F.secondary))
                if let why = h.overloadWhy { PMDim(text: why) }
            } else {
                PMDim(text: "编译锁空闲")
            }
            ForEach(b.queue) { q in
                HStack(spacing: 6) {
                    Text("\(q.pos)\(q.prio ? "⁺" : "")").font(.system(size: Theme.F.caption, design: .serif)).foregroundStyle(Theme.textMuted).frame(width: 18, alignment: .leading)
                    PMWhoLabel(who: q.who, open: open)
                    Text("· \(q.where)\(q.queuedAt.map { " · 排了 " + PMTime.ago($0).replacingOccurrences(of: "前", with: "") } ?? "")")
                        .foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                .font(.system(size: Theme.F.secondary))
            }
            if let l = b.last {
                PMDim(text: "上一个：\(l.where) \(l.secs.map { "编了 \(Int($0)) 秒" } ?? "") \(l.ok ? "✓" : "✗") · \(PMTime.ago(l.at))")
            }
        }
    }

    // MARK: 🔀 合并

    private func merges(_ m: PMOccupancy.Merges) -> some View {
        PMCard(title: "🔀 合并") {
            PMDim(text: m.lockHeld ? "Warden 正在合" : "合并锁空闲")
            if !m.processing.isEmpty { mergeRows("正在合", m.processing) }
            if !m.pending.isEmpty { mergeRows("排着", m.pending) }
            if !m.recent.isEmpty { mergeRows("最近", Array(m.recent.prefix(5))) }
        }
    }

    private func mergeRows(_ title: String, _ list: [PMOccMerge]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: Theme.F.caption, weight: .semibold)).foregroundStyle(Theme.textMuted)
            ForEach(list) { m in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("#\(m.id)").font(.system(size: Theme.F.caption, design: .monospaced)).foregroundStyle(Theme.textMuted)
                        PMWhoLabel(who: m.who, open: open)
                        if !m.result.isEmpty {
                            Text(m.result == "merged" ? "✓ 合了" : m.result).foregroundStyle(m.result == "merged" ? PMState.busy.color : PMState.wait.color)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: Theme.F.secondary))
                    Text(m.why).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
            }
        }
    }

    // MARK: 📱 设备

    private func devices(_ list: [PMOccDevice]) -> some View {
        PMCard(title: "📱 设备") {
            ForEach(list) { d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(d.note).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        if let h = d.holder {
                            if h.pinned { Text("📌").font(.system(size: Theme.F.caption)) }
                            PMWhoLabel(who: h.who, open: open)
                        } else {
                            Text("空闲").foregroundStyle(Theme.textMuted)
                        }
                    }
                    .font(.system(size: Theme.F.secondary))
                    if let h = d.holder, let exp = h.expires, exp > Date.now.timeIntervalSince1970 * 1000 {
                        Text("在叫你验，还剩 \(Int((exp / 1000 - Date.now.timeIntervalSince1970) / 60) + 1) 分钟\(h.why.isEmpty ? "" : "：" + h.why)")
                            .font(.system(size: Theme.F.caption)).foregroundStyle(PMState.wait.color)
                    } else if let h = d.holder, !h.why.isEmpty {
                        PMDim(text: h.why)
                    }
                    if !d.queue.isEmpty {
                        HStack(spacing: 4) {
                            Text("排着：").foregroundStyle(Theme.textMuted)
                            ForEach(Array(d.queue.enumerated()), id: \.offset) { _, q in PMWhoLabel(who: q.who, open: open) }
                        }
                        .font(.system(size: Theme.F.caption))
                    }
                }
            }
        }
    }

    // MARK: ▦ 工位

    private func zones(_ list: [PMOccZone]) -> some View {
        PMCard(title: "▦ 工位") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(list) { z in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(z.zone).font(.system(size: Theme.F.secondary, weight: .semibold)).foregroundStyle(z.exists ? Theme.textPrimary : Theme.textMuted).lineLimit(1)
                        Text(z.desc).font(.system(size: Theme.F.badge)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        if let o = z.owner {
                            PMWhoLabel(who: o, open: open).font(.system(size: Theme.F.caption))
                        } else {
                            Text("空").font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
                        }
                        if let a = z.ahead, a > 0 || (z.dirty ?? 0) > 0 {
                            Text("领先 \(a) · 未提交 \(z.dirty ?? 0)").font(.system(size: Theme.F.badge)).foregroundStyle(Theme.textMuted)
                        }
                        if let w = z.warn { Text("⚠ \(w)").font(.system(size: Theme.F.badge)).foregroundStyle(PMState.wait.color).lineLimit(2) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(z.owner?.alive == true ? PMState.busy.color.opacity(0.10) : Theme.mainBg, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

// MARK: - 小零件

/// 「谁」：有 sid 就能点进详情；人走了标灰
struct PMWhoLabel: View {
    let who: PMWho
    let open: (String) -> Void

    var body: some View {
        let label = Text(who.title.map { "\(who.name)·\($0)" } ?? who.name)
            .foregroundStyle(who.alive ? Theme.textPrimary : Theme.textMuted)
            .lineLimit(1)
        if let sid = who.sid {
            Button { open(sid) } label: { label.underline(who.alive, color: Theme.textMuted.opacity(0.4)) }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}

struct PMCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: Theme.F.sectionHeader, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PMDim: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted).lineLimit(2)
    }
}
#endif
#endif
