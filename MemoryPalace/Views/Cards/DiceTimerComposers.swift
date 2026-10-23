#if os(iOS)
import SwiftUI

/// ➕ →「骰子」：数字骰（几颗几面）或选项抽签（research-chat-cards §8.1）
struct DiceCardComposer: View {
    var takenIds: Set<String> = []
    let onDone: (DiceCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var usesOptions = false
    @State private var count = 1
    @State private var sides = 6
    @State private var optionsText = ""

    private var card: DiceCard? {
        usesOptions
            ? DiceCard.make(title: title, optionLines: optionsText.components(separatedBy: "\n"), avoiding: takenIds)
            : DiceCard.make(title: title, count: count, sides: sides, avoiding: takenIds)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题（可空）", text: $title)
                Picker("类型", selection: $usesOptions) {
                    Text("数字骰").tag(false)
                    Text("选项抽签").tag(true)
                }
                .pickerStyle(.segmented)
                if usesOptions {
                    Section("每行一个选项（至少两个）") {
                        TextEditor(text: $optionsText).frame(minHeight: 140)
                    }
                } else {
                    Stepper("\(count) 颗", value: $count, in: 1...20)
                    Picker("面数", selection: $sides) {
                        ForEach([4, 6, 8, 10, 12, 20, 100], id: \.self) { Text("d\($0)").tag($0) }
                    }
                }
            }
            .navigationTitle("骰子卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("放进输入框") {
                        if let card { onDone(card) }
                        dismiss()
                    }
                    .disabled(card == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// ➕ →「计时器」：名字 + 时钟式时 / 分 / 秒滚轮 + 发出后立即开始（§8.2）
struct TimerCardComposer: View {
    var takenIds: Set<String> = []
    let onDone: (TimerCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var autoStart = true

    private var card: TimerCard? {
        TimerCard.make(title: title, hours: hours, minutes: minutes, seconds: seconds, autoStart: autoStart, avoiding: takenIds)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名字（可空）", text: $title)
                Section {
                    HStack(spacing: 0) {
                        wheel($hours, range: 0..<24, unit: "小时")
                        wheel($minutes, range: 0..<60, unit: "分")
                        wheel($seconds, range: 0..<60, unit: "秒")
                    }
                    .frame(height: 180)
                } footer: {
                    if let hint = TimerCard.composerHint(hours: hours, minutes: minutes, seconds: seconds) {
                        Text(hint)
                    }
                }
                Toggle("发出后立即开始", isOn: $autoStart)
            }
            .navigationTitle("计时器卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("放进输入框") {
                        if let card { onDone(card) }
                        dismiss()
                    }
                    .disabled(card == nil)
                }
            }
        }
        .presentationDetents([.large])
    }

    /// 一列滚轮：数字 + 单位（和系统时钟的计时器一样）
    private func wheel(_ value: Binding<Int>, range: Range<Int>, unit: String) -> some View {
        HStack(spacing: 2) {
            Picker(unit, selection: value) {
                ForEach(range, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            Text(unit).font(.headline).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
