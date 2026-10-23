import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Anthropic server-side web search 收集到的 sources，气泡底部横排 chip。
/// 点击 chip 打开真实 URL；超过 maxVisible 条折叠成「+N 更多」。
struct WebSearchSourcesChipRow: View {
    let sources: [WebSearchSource]
    var maxVisible: Int = 5
    @State private var expanded: Bool = false

    private var visible: [WebSearchSource] {
        expanded ? sources : Array(sources.prefix(maxVisible))
    }
    private var hiddenCount: Int {
        max(0, sources.count - maxVisible)
    }

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("引用源")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                    HStack(spacing: 6) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { _, src in
                            chip(for: src)
                        }
                        if !expanded, hiddenCount > 0 {
                            Button {
                                expanded = true
                            } label: {
                                Text("+\(hiddenCount) 更多")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Theme.textMuted)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Theme.mainBg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func chip(for src: WebSearchSource) -> some View {
        Button {
            openURL(src.url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 9))
                Text(displayTitle(for: src))
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.mainBg))
        }
        .buttonStyle(.plain)
        .help(src.url)
    }

    private func displayTitle(for src: WebSearchSource) -> String {
        let t = src.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t.count > 28 ? String(t.prefix(28)) + "…" : t }
        // fallback：拿 host
        if let host = URL(string: src.url)?.host { return host }
        return src.url
    }

    private func openURL(_ s: String) {
        guard let url = URL(string: s) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
