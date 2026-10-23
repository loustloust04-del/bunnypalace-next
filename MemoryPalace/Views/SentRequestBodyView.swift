import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// #089 P0-c：检查器「请求」页默认看的——这个对话上一次**真实发出去**的请求体（网络层原样存的，不是另算的预览）。
/// 显示时图片 base64 换占位、排版成多行；「复制」复制原样字节（key 已去掉）。同一对话里新请求进来就刷新
struct SentRequestBodyView: View {
    @Environment(\.settingsMetrics) private var m
    let conversationId: String?

    @State private var turn: SentTurn?
    @State private var loaded = false
    @State private var index = 0

    private var store: SentRequestStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let turn, !turn.requests.isEmpty {
                let sent = turn.requests[min(index, turn.requests.count - 1)]
                header(sent, total: turn.requests.count)
                if turn.requests.count > 1 {
                    Picker("", selection: $index) {
                        ForEach(turn.requests.indices, id: \.self) { i in
                            Text("第 \(i + 1) 次").tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ScrollView(.vertical) {
                    Text(Self.displayText(sent.body))
                        .font(m.caption.monospaced())
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
            } else if loaded {
                Text(conversationId == nil
                     ? "设置页没有绑定对话——到聊天右栏「Prompt 工具」看"
                     : "这个对话在这台设备上还没有真实发出的请求。切到「下一轮预览」看现在点发送会发什么。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(conversationId ?? "")#\(conversationId.map(store.version) ?? 0)") {
            guard let conversationId else { turn = nil; loaded = true; return }
            let fresh = await store.latest(conversationId: conversationId)
            if fresh?.turnId != turn?.turnId { index = 0 }
            turn = fresh
            loaded = true
        }
    }

    private func header(_ sent: SentRequest, total: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("上一次真实发出的请求 Body")
                    .font(m.sectionHeader.weight(.medium))
                    .foregroundColor(Theme.textSecondary)
                Text("\(sent.sentAt.formatted(date: .abbreviated, time: .shortened)) · \(sent.model)\(total > 1 ? " · 这一回合共 \(total) 次请求" : "")")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                Text(sent.url)
                    .font(m.caption.monospaced())
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                #if os(iOS)
                UIPasteboard.general.string = sent.body
                #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sent.body, forType: .string)
                #endif
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    /// 显示用：解得开就图片换占位 + 排版；解不开原样
    static func displayText(_ body: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: PersonaSettingsTab.redactingImageData(obj),
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return body }
        return text
    }
}
