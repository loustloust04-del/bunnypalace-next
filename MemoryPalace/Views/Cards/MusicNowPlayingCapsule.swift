import SwiftData
import SwiftUI

/// 切到别的对话后音乐继续放，聊天页顶上浮一个小玻璃胶囊：黑胶 + 歌名 + 暂停 / 继续；点胶囊回到那首歌所在的对话、滚到那张卡（粟粟 09-27）。
/// iOS 26 玻璃教训：glassEffect(.interactive()) 套在 Button 里会吞点按——用普通视图 + onTapGesture。
struct MusicNowPlayingCapsule: View {
    let viewModel: ConversationViewModel
    /// 全局挂着（聊天页以外的页面）：只要在放就显示，不看当前是不是那首歌的对话（粟粟 09-28）
    var alwaysShow = false
    /// 回到那首歌的对话之后（全局胶囊用它翻回聊天页）
    var afterGoBack: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var player: MusicCardPlayer { .shared }

    var body: some View {
        let show = alwaysShow ? (player.isActive && player.origin != nil)
            : MusicNowPlaying.shouldShow(origin: player.origin, isActive: player.isActive,
                                         currentConversationId: viewModel.selectedConversation?.id)
        ZStack {
            if show, let origin = player.origin, let key = player.currentKey {
                capsule(origin: origin, playing: [.playing, .loading].contains(player.phase(for: key)))
                    .transition(ChatCardMotion.contentTransition(reduceMotion: reduceMotion)
                        .combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .animation(ChatCardMotion.animation(ChatCardMotion.morph, reduceMotion: reduceMotion), value: show)
    }

    private func capsule(origin: MusicOrigin, playing: Bool) -> some View {
        HStack(spacing: 8) {
            VinylCover(spinning: playing && !reduceMotion)
                .frame(width: 24, height: 24)
                .clipShape(Circle())
            Text(origin.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            PlayPauseShape(morph: playing ? 1 : 0)
                .fill(Color.primary.opacity(0.85))
                .frame(width: 14, height: 14)
                .animation(ChatCardMotion.animation(ChatCardMotion.snappy, reduceMotion: reduceMotion), value: playing)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .onTapGesture { player.togglePauseCurrent() }
                .accessibilityLabel(playing ? "暂停" : "继续播放")
                .accessibilityAddTraits(.isButton)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 36)
        .modifier(GlassCapsule())
        .contentShape(Capsule())
        .onTapGesture { goBack(to: origin) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("正在播放：\(origin.title)，点按回到那个对话")
    }

    private func goBack(to origin: MusicOrigin) {
        let id = origin.conversationId
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let conversation = try? modelContext.fetch(descriptor).first else { return }
        if viewModel.selectedConversation?.id != conversation.id {
            viewModel.loadConversation(conversation, context: modelContext,
                                       scrollTargetNodeId: origin.nodeId.isEmpty ? nil : origin.nodeId)
        }
        afterGoBack()
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.glassEffect(.regular, in: Capsule())
        #else
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.ultraThinMaterial))
        }
        #endif
    }
}
