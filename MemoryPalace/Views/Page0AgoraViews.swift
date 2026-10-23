#if os(iOS)
import SwiftUI

struct Page0UnreadBadge: View {
    let count: Int
    var body: some View {
        Text(Page0LocalState.unreadLabel(count))
            .font(.system(size: Theme.F.badge, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(ConversationRow.unreadTint))
            .fixedSize()
    }
}

struct Page0AgoraRow: View {
    let room: AgoraRoomSummary
    let viewModel: AgoraViewModel
    let detailed: Bool
    /// 纯净模式：只显示群名
    var pure: Bool = false
    let isSelected: Bool
    let unread: Int
    let open: () -> Void

    private var subtitle: String {
        if room.isDM {
            let peer = room.members.first { $0.actorId == room.dmPeerActorId }
                ?? room.members.first { $0.role == .member }
            return peer.map { "@\($0.handle) · 私信" } ?? "私信"
        }
        let names = room.members.map(\.displayName).joined(separator: "、")
        return names.isEmpty ? "\(room.memberCount) 位成员" : "\(names) · \(room.memberCount) 位成员"
    }
    private var titleLine: some View {
        HStack(spacing: detailed ? 8 : 10) {
            Text(viewModel.displayTitle(for: room))
                .font(.system(size: Theme.F.label, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 2)
            if !pure {
                Text(ConversationRow.smartDate(room.updatedAt))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                    .fixedSize()
            }
        }
    }
    var body: some View {
        Button(action: open) {
            VStack(spacing: 0) {
                HStack(alignment: detailed ? .top : .center, spacing: 10) {
                    if !pure {
                    Group {
                        if viewModel.appearance(for: room).kind == .members {
                            Image(systemName: room.isDM ? "bubble.left" : "person.2")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textMuted)
                                .frame(width: 20)
                        } else {
                            GroupAvatarView(room: room, appearance: viewModel.appearance(for: room),
                                            imageData: viewModel.avatarData(for: room), size: 20)
                        }
                    }
                    .padding(.top, detailed ? 2 : 0)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        titleLine
                        if detailed {
                            HStack(spacing: 6) {
                                Text(subtitle)
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if unread > 0 { Page0UnreadBadge(count: unread) }
                            }
                            .frame(height: 17)
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if !detailed && !pure {
                        Circle().fill(ConversationRow.unreadTint)
                            .frame(width: 6, height: 6)
                            .opacity(unread > 0 ? 1 : 0)
                            .frame(width: 10, height: 10)
                            .offset(x: 11)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, detailed ? 10 : 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.45) : Color.clear))
                .padding(.horizontal, 4)
                if !isSelected { Divider().opacity(0.15).padding(.leading, 16) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(viewModel.displayTitle(for: room))，\(subtitle)\(unread > 0 ? "，\(unread) 条未读" : "")")
    }
}

struct Page0AgoraAvatar: View {
    let room: AgoraRoomSummary
    let viewModel: AgoraViewModel
    let unread: Int
    let open: () -> Void
    private let mint = Color(red: 127 / 255, green: 165 / 255, blue: 141 / 255)
    // 横向 ScrollView 里 Button 的点按会被滚动手势吞（swiftui-ui 规则）→ onTapGesture
    var body: some View {
        VStack(spacing: 7) {
            GroupAvatarView(room: room, appearance: viewModel.appearance(for: room),
                            imageData: viewModel.avatarData(for: room), size: 52)
            .overlay {
                Circle().stroke(mint.opacity(room.updatedAt > Date().addingTimeInterval(-600) ? 1 : 0), lineWidth: 0.75)
            }
            .overlay(alignment: .topTrailing) {
                if unread > 0 { Page0UnreadBadge(count: unread).offset(x: 7, y: -3) }
            }
            Text(viewModel.displayTitle(for: room))
                .font(.system(size: 11))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: 68)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(viewModel.displayTitle(for: room))\(unread > 0 ? "，\(unread) 条未读" : "")")
    }
}
/// 成员簇沿用头像条的 52pt 坐标；预览和列表小圆共用同一份外观。
struct GroupAvatarView: View {
    let room: AgoraRoomSummary
    let appearance: GroupAppearance
    let imageData: Data?
    let size: CGFloat
    private var members: [AgoraMember] {
        if room.isDM {
            return Array(room.members.filter { $0.actorId == room.dmPeerActorId || (room.dmPeerActorId == nil && $0.role == .member) }.prefix(1))
        }
        return Array(room.members.prefix(3))
    }
    static func memberColor(_ actorId: String) -> Color {
        let palette: [UInt32] = [0x7FA58D, 0xD99AA5, 0x8FA9C9, 0xB3A2CC, 0xD9A07F]
        // Swift Hasher 每次进程随机种子；使用固定 UTF8 hash 保证跨启动颜色一致。
        let hash = actorId.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let hex = palette[Int(hash % UInt64(palette.count))]
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private func offset(_ index: Int) -> CGSize {
        guard !room.isDM, members.count > 1 else { return .zero }
        return [CGSize(width: -10, height: -7), CGSize(width: 10, height: -7), CGSize(width: 0, height: 10)][index]
    }
    /// 中文名取最后一个字（「小×」这类名字首字都是「小」，叠在一起分不出），其余取首字母
    static func initial(_ name: String) -> String {
        guard let last = name.last, let first = name.first else { return "" }
        let isCJK = last.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
        return isCJK ? String(last) : String(first).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(.white)
                .shadow(color: .black.opacity(0.07), radius: 5, y: 3)
                .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
            switch appearance.kind {
            case .members:
                memberCluster
            case .image:
                if let imageData, let image = PlatformImage(data: imageData) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: size * 0.4))
                        .foregroundColor(Theme.textMuted)
                }
            case .emoji:
                Text(appearance.emoji.isEmpty ? "💬" : appearance.emoji)
                    .font(.system(size: size * 0.55))
            case .symbol:
                Image(systemName: appearance.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundColor(FolderPalette.color(appearance.colorHex))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var memberCluster: some View {
        ZStack {
            if members.isEmpty {
                Image(systemName: room.isDM ? "bubble.left" : "person.2")
                    .foregroundColor(Color(red: 127 / 255, green: 165 / 255, blue: 141 / 255))
            }
            ForEach(Array(members.enumerated()), id: \.element.actorId) { index, member in
                Text(Self.initial(member.displayName))
                    .font(.system(size: room.isDM ? 19 : 11, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: room.isDM ? 38 : 24, height: room.isDM ? 38 : 24)
                    .background(Circle().fill(Self.memberColor(member.actorId)))
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(offset(index))
            }
        }
        .frame(width: 52, height: 52)
        .scaleEffect(size / 52)
        .frame(width: size, height: size)
    }
}
#endif
