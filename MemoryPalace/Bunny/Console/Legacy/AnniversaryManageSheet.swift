#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI

/// 纪念日管理页 — 控制台纪念日卡点开进入。
/// 数据直连网关 /api/anniversaries（与 Caelum 的 remember_anniversary 同一份）。
/// v7：支持置顶（钉图标）+ 长按拖动排序（List.onMove），置顶项自动排在最前。
struct AnniversaryManageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AnniversaryClient.Item] = []
    @State private var loading = true

    // 新增表单
    @State private var newName = ""
    @State private var newDate = Date()
    @State private var newIsCountdown = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                listSection
                addSection
                Section {
                    Color.clear.frame(height: 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        // 先亮出上次的（秒开），网关回来了再无声替换
        await AnniversaryClient.fetchCached { list, _ in items = list; loading = false }
        loading = false
    }

    // MARK: - 列表

    @ViewBuilder
    private var listSection: some View {
        Section {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if items.isEmpty {
                Text("还没有记录。也可以直接跟 Caelum 说\n「记一下我们 X 月 X 日相识」")
                    .font(.system(size: 13.5))
                    .foregroundColor(ConsoleView.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(items) { item in
                    itemRow(item)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove(perform: move)
            }
        } header: {
            if !loading && !items.isEmpty {
                Text("长按拖动排序 · 点钉置顶")
                    .font(.system(size: 11))
                    .foregroundColor(ConsoleView.textFaint)
                    .textCase(nil)
            }
        }
    }

    private func itemRow(_ item: AnniversaryClient.Item) -> some View {
        let disp = AnniversaryClient.display(for: item)
        return HStack(spacing: 12) {
            Button {
                Task {
                    _ = await AnniversaryClient.setPinned(id: item.id, pinned: !item.isPinned)
                    await reload()
                }
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 14))
                    .foregroundColor(item.isPinned ? ConsoleView.gold : ConsoleView.textFaint)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            Image(systemName: item.type == "countdown" ? "hourglass" : "heart")
                .font(.system(size: 15))
                .foregroundColor(disp?.highlight == true ? ConsoleView.gold : ConsoleView.green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(ConsoleView.textPrimary)
                Text(item.date)
                    .font(.system(size: 11.5))
                    .foregroundColor(ConsoleView.textMuted)
            }
            Spacer()
            Text(disp?.text ?? "已过去")
                .font(.system(size: 13.5, weight: disp?.highlight == true ? .semibold : .regular))
                .foregroundColor(disp?.highlight == true ? ConsoleView.gold : ConsoleView.textSub)
            Button {
                Task {
                    _ = await AnniversaryClient.remove(id: item.id)
                    await reload()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(ConsoleView.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
    }

    private func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        let ids = items.map { $0.id }
        Task { _ = await AnniversaryClient.reorder(ids: ids) }
    }

    // MARK: - 新增

    private var addSection: some View {
        Section {
            addForm
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD")
                .font(.system(size: 11.5, weight: .medium)).tracking(0.5)
                .foregroundColor(ConsoleView.textSub)
            TextField("名字（相识 / 生日 / 去日本…）", text: $newName)
                .font(.system(size: 15))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(ConsoleView.sink))
            DatePicker("日期", selection: $newDate, displayedComponents: .date)
                .font(.system(size: 14))
                .tint(ConsoleView.greenDeep)
            Picker("类型", selection: $newIsCountdown) {
                Text("纪念日（每年）").tag(false)
                Text("倒计时（一次）").tag(true)
            }
            .pickerStyle(.segmented)
            Button {
                Task { await addNew() }
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView().tint(.white) }
                    else { Text("记住这一天").font(.system(size: 15, weight: .semibold)) }
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(
                    newName.trimmingCharacters(in: .whitespaces).isEmpty ? ConsoleView.textFaint : ConsoleView.greenDeep))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
    }

    private func addNew() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        saving = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        _ = await AnniversaryClient.add(name: name, date: f.string(from: newDate),
                                        type: newIsCountdown ? "countdown" : "anniversary")
        newName = ""
        saving = false
        await reload()
    }
}
#endif
