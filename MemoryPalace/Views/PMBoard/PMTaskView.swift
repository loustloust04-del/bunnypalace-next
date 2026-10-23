#if PERSONAL_APPS
#if DEBUG
import SwiftUI

// MARK: - pmBoard「待验」tab：主仓 TASK.md（只读，Q19）+ 当场叫验的临时项（Q16 只显示不写）（docs/plan-dev-subapp-v2.md P1-d-2）
// 「待验」开头的节排最前；长按一项看「谁做的」，能进那个人的聊天。勾选走 Mac 或叫 Warden。

struct PMTaskView: View {
    let open: (String) -> Void
    @State private var store = PMBoardStore.shared
    @State private var openOnly = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let t = store.task {
                    if let e = store.taskError { PMNotice(text: e) }
                    HStack {
                        Toggle("只看没勾的", isOn: $openOnly).toggleStyle(.switch).controlSize(.mini).fixedSize()
                        Spacer()
                        Text("TASK.md · Mac 上 \(PMTime.ago(t.mtime))改过").font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
                    }
                    .font(.system(size: Theme.F.caption))
                    if !t.temp.isEmpty { temp(t.temp) }
                    ForEach(Array(t.sections.enumerated()), id: \.offset) { _, s in section(s) }
                } else if let e = store.taskError {
                    PMEmpty(icon: "wifi.exclamationmark", text: e)
                } else if !store.bridgeConnected {
                    PMEmpty(icon: "wifi.slash", text: "桥没连上（记忆花园没连到 Mac 上的 hub）")
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .refreshable { store.requestTask() }
    }

    private func temp(_ list: [PMTaskBoard.Temp]) -> some View {
        PMCard(title: "当场在叫你验（临时，不进 TASK.md）") {
            ForEach(Array(list.enumerated()), id: \.offset) { _, x in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PMWhoLabel(who: x.who, open: open)
                    Text(x.text).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                .font(.system(size: Theme.F.secondary))
            }
        }
    }

    @ViewBuilder
    private func section(_ s: PMTaskSection) -> some View {
        let groups = s.groups.map { g in (g, g.items.filter { !openOnly || !$0.done }) }.filter { !$0.1.isEmpty }
        if !groups.isEmpty {
            PMSectionTitle(text: s.title.isEmpty ? "TASK" : s.title, count: s.title.hasPrefix("待验") ? groups.reduce(0) { $0 + $1.1.count } : nil)
                .padding(.top, 6)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 6) {
                    if !pair.0.title.isEmpty {
                        Text(pair.0.title).font(.system(size: Theme.F.caption, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    }
                    ForEach(pair.1, id: \.line) { item in row(item) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sidebarBg, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func row(_ it: PMTaskItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: it.done ? "checkmark.square" : "square").font(.system(size: Theme.F.caption)).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.text).font(.system(size: Theme.F.secondary)).foregroundStyle(it.done ? Theme.textMuted : Theme.textPrimary).lineLimit(3)
                if let who = it.who {
                    Text(who.name + (who.alive ? "" : " · 已退出")).font(.system(size: Theme.F.badge)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Text(it.whoLine ?? "不知道是谁（没有标记、也没有合并单号）")
            if !it.id.isEmpty { Text(it.id) }
            if let sid = it.who?.sid {
                Button("进它的聊天", systemImage: "bubble.left") { open(sid) }
            }
        }
    }
}
#endif
#endif
