#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI

/// 药箱 — 控制台药物卡点开进入。
/// 数据直连网关 /api/meds（与 Caelum 的 meds_* 工具同一份）。
/// 记录：有哪些药、各剩多少、每次剂量；吃一次自动扣库存；补货；今天吃了啥。
struct MedsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snap: MedsClient.Snapshot?
    @State private var loading = true
    @State private var busy = false

    // 新增表单
    @State private var newName = ""
    @State private var newCount = ""
    @State private var newUnit = "片"
    @State private var newPerDose = "1"

    // 补货
    @State private var showRestock = false
    @State private var restockTarget: MedsClient.Med? = nil
    @State private var restockAmount = ""

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    if loading {
                        ProgressView().padding(.vertical, 44)
                    } else {
                        todayCard
                        medsCard
                        addCard
                    }
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("药箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
        .task { await reload() }
        .alert("补货", isPresented: $showRestock) {
            TextField("补充数量", text: $restockAmount).keyboardType(.numberPad)
            Button("取消", role: .cancel) { restockTarget = nil; restockAmount = "" }
            Button("确定") { Task { await doRestock() } }
        } message: {
            Text(restockTarget.map { "给「\($0.name)」补货（当前剩 \(MedsClient.numText($0.remaining))\($0.unit)）" } ?? "")
        }
    }

    private func reload() async {
        await MedsClient.fetchCached { s, _ in snap = s }
        loading = false
    }

    // MARK: - 今天吃了啥

    private var todayCard: some View {
        let today = snap?.today ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text("今天吃了")
                .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            if today.isEmpty {
                Text("今天还没记录吃药").font(.system(size: 13)).foregroundColor(ConsoleView.textFaint)
            } else {
                Text(today.map { "\($0.name) × \(MedsClient.numText($0.amount))" }.joined(separator: "  ·  "))
                    .font(.system(size: 14)).foregroundColor(ConsoleView.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    // MARK: - 药列表

    private var medsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我的药")
                .font(.system(size: 13, weight: .semibold)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            if (snap?.meds ?? []).isEmpty {
                Text("药箱还是空的，下面加一个吧").font(.system(size: 13)).foregroundColor(ConsoleView.textFaint)
                    .padding(.vertical, 8)
            } else {
                ForEach(snap!.meds) { med in medRow(med) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func medRow(_ med: MedsClient.Med) -> some View {
        let low = med.remaining <= med.perDose * 3
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(med.name).font(.system(size: 15, weight: .medium)).foregroundColor(ConsoleView.textPrimary)
                    Text("每次 \(MedsClient.numText(med.perDose))\(med.unit)")
                        .font(.system(size: 11)).foregroundColor(ConsoleView.textMuted)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(MedsClient.numText(med.remaining))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(low ? ConsoleView.gold : ConsoleView.textPrimary)
                    Text("剩·\(med.unit)").font(.system(size: 10)).foregroundColor(ConsoleView.textFaint)
                }
            }
            HStack(spacing: 8) {
                Button {
                    Task { busy = true; _ = await MedsClient.take(id: med.id); await reload(); busy = false }
                } label: {
                    Text("吃一次").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ConsoleView.greenDeep))
                        .foregroundColor(.white)
                }.buttonStyle(.plain).disabled(busy)
                Button {
                    restockTarget = med; restockAmount = ""; showRestock = true
                } label: {
                    Text("补货").font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ConsoleView.sink))
                        .foregroundColor(ConsoleView.greenDeep)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(ConsoleView.sink.opacity(0.5)))
        .contextMenu {
            Button(role: .destructive) {
                Task { _ = await MedsClient.remove(id: med.id); await reload() }
            } label: { Label("从药箱删除", systemImage: "trash") }
        }
    }

    // MARK: - 新增

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("加一种药")
                .font(.system(size: 11.5, weight: .medium)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            TextField("药名（右佐匹克隆 / 布洛芬…）", text: $newName)
                .font(.system(size: 15))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(ConsoleView.sink))
            HStack(spacing: 8) {
                labeledField("数量", $newCount, numeric: true)
                labeledField("单位", $newUnit)
                labeledField("每次", $newPerDose, numeric: true)
            }
            Button {
                Task { await addNew() }
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().tint(.white) }
                    else { Text("加入药箱").font(.system(size: 15, weight: .semibold)) }
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(
                    newName.trimmingCharacters(in: .whitespaces).isEmpty ? ConsoleView.textFaint : ConsoleView.greenDeep))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func labeledField(_ placeholder: String, _ text: Binding<String>, numeric: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 14))
            .keyboardType(numeric ? .numberPad : .default)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(ConsoleView.sink))
    }

    // MARK: - 动作

    private func addNew() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true
        let count = Double(newCount) ?? 0
        let perDose = Double(newPerDose) ?? 1
        let unit = newUnit.trimmingCharacters(in: .whitespaces).isEmpty ? "片" : newUnit
        _ = await MedsClient.add(name: name, count: count, unit: unit, perDose: perDose > 0 ? perDose : 1)
        newName = ""; newCount = ""; newPerDose = "1"
        busy = false
        await reload()
    }

    private func doRestock() async {
        guard let med = restockTarget, let n = Double(restockAmount), n > 0 else { restockTarget = nil; return }
        busy = true
        _ = await MedsClient.restock(id: med.id, count: n)
        restockTarget = nil; restockAmount = ""
        await reload()
        busy = false
    }
}
#endif
