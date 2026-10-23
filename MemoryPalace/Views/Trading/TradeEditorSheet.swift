#if PERSONAL_APPS
import SwiftUI
import SwiftData

/// 交易卡编辑 sheet（手动兜底入口：录入/翻平仓 tag/写复盘）。原生结构（MedEditorSheet 样板）。
/// entry == nil 新建；平仓=翻 status tag（粟粟拍的"就一个 tag"，不是流程）。
struct TradeEditorSheet: View {
    let profileId: String
    var entry: TradeEntry?
    var presetSymbol: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var symbol = ""
    @State private var side = "long"
    @State private var quantityText = ""
    @State private var priceText = ""
    @State private var reason = ""
    @State private var isClosed = false
    @State private var closePriceText = ""
    @State private var reviewNote = ""

    var body: some View {
        NavigationStack {
            List {
                Section("仓位") {
                    TextField("代码，如 NVDA", text: $symbol)
                        .font(.system(size: Theme.F.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        #endif
                        .disabled(entry != nil)
                    Picker("方向", selection: $side) {
                        Text("做多").tag("long")
                        Text("做空").tag("short")
                    }
                    #if os(iOS)
                    .pickerStyle(.menu)
                    #endif
                    .tint(Theme.branchIndicator)   // 配色铁律：不要系统蓝
                    TextField("数量（股）", text: $quantityText)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    TextField("开仓价", text: $priceText)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                .listRowBackground(Theme.mainBg)

                Section {
                    TextField("为什么开这单（灵魂字段）", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("开仓理由")
                }
                .listRowBackground(Theme.mainBg)

                Section {
                    Toggle(isOn: $isClosed) {
                        Text("已平仓")
                            .font(.system(size: Theme.F.body))
                    }
                    .tint(Theme.branchIndicator)
                    if isClosed {
                        TextField("平仓价（可空）", text: $closePriceText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                } header: {
                    Text("状态")
                }
                .listRowBackground(Theme.mainBg)

                Section {
                    TextField("复盘结论（可空，聊天里复盘也会挂进来）", text: $reviewNote, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("复盘")
                }
                .listRowBackground(Theme.mainBg)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(entry == nil ? "记一笔" : "$\(symbol)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear { loadEntry() }
        #if os(macOS)
        .frame(width: 440, height: 560)
        #endif
    }

    private var canSave: Bool {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        return (1...5).contains(s.count) && s.allSatisfy { $0.isLetter && $0.isASCII }
            && Double(quantityText) ?? 0 > 0
            && Double(priceText) ?? 0 > 0
            && !reason.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadEntry() {
        guard let e = entry else {
            symbol = presetSymbol ?? ""
            return
        }
        symbol = e.symbol
        side = e.side
        quantityText = e.quantity == e.quantity.rounded() ? String(Int(e.quantity)) : String(e.quantity)
        priceText = String(e.price)
        reason = e.reason
        isClosed = e.status == "closed"
        closePriceText = e.closePrice.map { String($0) } ?? ""
        reviewNote = e.reviewNote ?? ""
    }

    private func save() {
        guard canSave else { return }
        let sym = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        let qty = Double(quantityText) ?? 0
        let price = Double(priceText) ?? 0
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReview = reviewNote.trimmingCharacters(in: .whitespacesAndNewlines)

        let target: TradeEntry
        if let e = entry {
            target = e
            target.side = side
            target.quantity = qty
            target.price = price
            target.reason = trimmedReason
        } else {
            target = TradeEntry(profileId: profileId, symbol: sym, side: side,
                                quantity: qty, price: price, reason: trimmedReason)
            modelContext.insert(target)
            TradingJournalMirror.append("开\(side == "short" ? "空" : "多") $\(sym) \(Int(qty))股 @\(price)：\(trimmedReason)", profileId: profileId)
        }
        // 平仓=翻 tag（顺手记价）
        let wasClosed = target.status == "closed"
        target.status = isClosed ? "closed" : "open"
        if isClosed {
            if target.closedAt == nil { target.closedAt = Date() }
            target.closePrice = Double(closePriceText)
            if !wasClosed {
                let pnl = target.closedPnLPercent.map { String(format: "（%+.1f%%）", $0) } ?? ""
                TradingJournalMirror.append("平 $\(sym)\(pnl)", profileId: profileId)
            }
        } else {
            target.closedAt = nil
            target.closePrice = nil
        }
        if !trimmedReview.isEmpty, trimmedReview != (entry?.reviewNote ?? "") {
            target.reviewNote = trimmedReview
            target.reviewedAt = Date()
            TradingJournalMirror.append("复盘 $\(sym)：\(trimmedReview)", profileId: profileId)
        } else if trimmedReview.isEmpty {
            target.reviewNote = nil
        }
        try? modelContext.save()
        dismiss()
    }
}
#endif
