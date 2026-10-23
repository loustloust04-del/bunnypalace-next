import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 设备工具结果卡（plan-设备工具 §-0.5）：只给「产生/指向系统实体」的结果出卡，
/// 其余工具维持原来的折叠行。数据来自工具 envelope 的可选 `card` 字段——
/// 模型协议零改动，老对话没有该字段自然走折叠行。
struct DeviceToolCard: Equatable {
    let type: String
    let title: String
    let subtitle: String?
    let detail: String?
    let icon: String
    let deeplink: String?
    let imagePath: String?
    /// 有 event_id 就能弹系统原生事件卡（iOS）；没有才回落深链跳 app。
    let eventId: String?
    let occurrence: Date?

    /// 从工具结果文本里解析。不是设备工具 / 没有 card 字段 → nil。
    static func parse(_ resultText: String?) -> DeviceToolCard? {
        guard let text = resultText,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true,
              let c = obj["card"] as? [String: Any],
              let type = c["type"] as? String,
              let title = c["title"] as? String,
              let icon = c["icon"] as? String
        else { return nil }
        return DeviceToolCard(
            type: type, title: title,
            subtitle: c["subtitle"] as? String, detail: (c["detail"] as? String)?.nilIfBlank,
            icon: icon, deeplink: c["deeplink"] as? String, imagePath: c["image_path"] as? String,
            eventId: (c["event_id"] as? String)?.nilIfBlank,
            occurrence: DeviceToolIO.parseDate(c["occurrence"] as? String)
        )
    }

    /// 深链白名单：只放行跳系统 app 的这几个 scheme。渲染层直开不经模型，
    /// 与 `open_url` 工具（http(s)+settings，模型可调）是两套面，故白名单不同。
    var safeDeeplink: URL? {
        guard let d = deeplink, let url = URL(string: d), let s = url.scheme?.lowercased(),
              ["calshow", "x-apple-reminderkit"].contains(s) else { return nil }
        return url
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}

struct DeviceToolCardView: View {
    let card: DeviceToolCard
    let profileId: String
    @State private var showSystemEvent = false

    /// 点击有没有效果：能开系统卡 或 有合法深链
    private var isTappable: Bool { canOpenSystemSheet || card.safeDeeplink != nil }
    private var canOpenSystemSheet: Bool {
        #if os(iOS)
        card.type == "calendar_event" && card.eventId != nil
        #else
        false
        #endif
    }

    var body: some View {
        Button {
            #if os(iOS)
            if canOpenSystemSheet { showSystemEvent = true; return }
            #endif
            if let url = card.safeDeeplink { open(url) }
        } label: {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.system(size: Theme.F.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                    if let sub = card.subtitle {
                        Text(sub)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    if let detail = card.detail {
                        Text(detail)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if isTappable {
                    Image(systemName: canOpenSystemSheet ? "chevron.right" : "arrow.up.forward.app")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
        #if os(iOS)
        // 系统原生事件卡：苹果自己画的详情界面，自带编辑/删除/加提醒
        .sheet(isPresented: $showSystemEvent) {
            if let id = card.eventId {
                SystemEventSheet(eventIdentifier: id, occurrenceDate: card.occurrence) { showSystemEvent = false }
                    .ignoresSafeArea()
            }
        }
        #endif
    }

    @ViewBuilder private var thumbnail: some View {
        if let path = card.imagePath, let img = loadImage(path) {
            img.resizable().aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: card.icon)
                .font(.system(size: 20, weight: .light))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
        }
    }

    private func loadImage(_ path: String) -> Image? {
        guard let data = try? FileLibraryStore.readData(path, profileId: profileId) else { return nil }
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #else
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #endif
    }

    private func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}
