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
                if let thinking = Self.thinkingLine(sent.body) {
                    Text(thinking)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
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

    /// 显示用：解得开就图片换占位、思考块签名 / redacted 密文缩成字数 + 排版；解不开原样（「复制」照旧复制原文）
    static func displayText(_ body: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: PersonaSettingsTab.redactingImageData(redactingThinkingSecrets(obj)),
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return body }
        return text
    }

    /// thinking 回传 §3.7：思考块的 signature、redacted_thinking 的 data 换成 `<签名 1832 字>` / `<redacted 密文 N 字>`
    static func redactingThinkingSecrets(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            switch dict["type"] as? String {
            case "thinking":
                if let sig = dict["signature"] as? String { dict["signature"] = "<签名 \(sig.count) 字>" }
                return dict
            case "redacted_thinking":
                if let data = dict["data"] as? String { dict["data"] = "<redacted 密文 \(data.count) 字>" }
                return dict
            default:
                return dict.mapValues(redactingThinkingSecrets)
            }
        }
        if let array = value as? [Any] { return array.map(redactingThinkingSecrets) }
        return value
    }

    /// 头部一行：`思考：adaptive · 摘要 · effort 默认(medium) · max_tokens 36864`；带了当轮思考块（第 2 次及以后）再加「回传思考块 N 个」。
    /// 没有思考参数也没回传块 = nil（OpenAI 兼容 / 老模型默认档）
    static func thinkingLine(_ body: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return nil }
        let messages = obj["messages"] as? [[String: Any]] ?? []
        let echoed = messages.reduce(0) { n, msg in
            n + ((msg["content"] as? [[String: Any]])?.filter(ReplyBlock.isThinking).count ?? 0)
        }
        let thinking = obj["thinking"] as? [String: Any]
        guard thinking != nil || echoed > 0 else { return nil }
        let model = obj["model"] as? String ?? ""
        var parts: [String] = []
        if let thinking {
            let type = thinking["type"] as? String ?? "?"
            parts.append(type)
            if type == "adaptive" {
                if thinking["display"] as? String == "summarized" {
                    parts.append("摘要")
                } else {
                    parts.append(ModelLineage.displayDefaultOmitted(model) ? "不要摘要" : "摘要（模型默认）")
                }
                if let effort = (obj["output_config"] as? [String: Any])?["effort"] as? String {
                    parts.append("effort \(effort)")
                } else {
                    parts.append("effort 默认(\(ModelLineage.defaultEffort(model)))")
                }
            } else if let budget = thinking["budget_tokens"] as? Int {
                parts.append("budget_tokens \(budget)")
            }
        } else {
            parts.append("不发")
        }
        if let max = obj["max_tokens"] as? Int { parts.append("max_tokens \(max)") }
        var line = "思考：" + parts.joined(separator: " · ")
        if echoed > 0 { line += " · 回传思考块 \(echoed) 个" }
        return line
    }
}
