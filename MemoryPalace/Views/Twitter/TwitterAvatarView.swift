import SwiftUI

/// 圆头像。存档里有原图就用原图，没有就退回显示名首字。
/// `otherName` 给了 = 这是别人（转推的原作者）：存档里没有别人的头像，画灰底首字。
struct TwitterAvatarView: View {
    let account: TwitterArchiveAccount?
    let mediaDir: URL
    var size: CGFloat = 40
    var accent: Color
    var otherName: String? = nil

    var body: some View {
        Group {
            if let other = otherName {
                letter(other, fill: Theme.textMuted.opacity(0.45))
            } else if let name = account?.avatarFileName {
                TwitterMediaImage(url: mediaDir.appendingPathComponent(name))
            } else {
                letter(account?.displayName ?? "?", fill: accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func letter(_ name: String, fill: Color) -> some View {
        Circle().fill(fill).overlay {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
