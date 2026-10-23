import SwiftUI

/// 侧边抽屉。推特点左上角头像拉出来的就是它：顶上是账号（其它账号的小头像点一下就切），
/// 下面是去处。切换账号、书签的入口都挂在这里（粟粟 2026-09-24）。
struct TwitterDrawerView: View {
    let accounts: [TwitterArchiveAccount]
    let active: TwitterArchiveAccount?
    let tweetCount: Int
    let mediaDir: URL
    let accent: Color
    let demoInstalled: Bool
    var onProfile: () -> Void = {}
    var onBookmarks: () -> Void = {}
    var onSwitch: (TwitterArchiveAccount) -> Void = { _ in }
    var onManageAccounts: () -> Void = {}
    var onEditProfile: () -> Void = {}
    var onAccent: () -> Void = {}
    var onImport: () -> Void = {}
    var onRemoveDemo: () -> Void = {}

    private var others: [TwitterArchiveAccount] {
        accounts.filter { $0.persistentModelID != active?.persistentModelID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Button(action: onProfile) {
                    TwitterAvatarView(account: active, mediaDir: mediaDir, size: 44, accent: accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("个人资料")
                Spacer()
                // 其它账号：推特抽屉右上角的小头像，点一下就切
                ForEach(others.prefix(2), id: \.persistentModelID) { acc in
                    Button { onSwitch(acc) } label: {
                        TwitterAvatarView(account: acc, mediaDir: mediaDir, size: 30, accent: accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("切到 \(acc.displayName)")
                }
                Button(action: onManageAccounts) {
                    Image(systemName: others.isEmpty ? "plus" : "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Theme.textMuted.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(others.isEmpty ? "添加账号" : "所有账号")
            }

            Text(active?.displayName ?? "我")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 10)
            if let handle = active?.screenName, !handle.isEmpty {
                Text("@\(handle)").font(.system(size: 15)).foregroundStyle(Theme.textMuted)
            }
            Text("\(tweetCount) 条推文")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 10)

            Divider().opacity(0.4).padding(.vertical, 16)

            row("person", "个人资料", action: onProfile)
            row("bookmark", "书签", action: onBookmarks)

            Divider().opacity(0.4).padding(.vertical, 12)

            row("pencil", "编辑个人资料", small: true, action: onEditProfile)
            row("paintpalette", "强调色", small: true, action: onAccent)
            row("square.and.arrow.down", "导入存档", small: true, action: onImport)
            if demoInstalled {
                row("trash", "清掉示例", small: true, tint: Theme.danger, action: onRemoveDemo)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ icon: String, _ title: String, small: Bool = false, tint: Color? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: small ? 17 : 21))
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: small ? 16 : 20, weight: small ? .regular : .bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint ?? Theme.textPrimary)
            .frame(height: small ? 44 : 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 所有账号：勾当前的，点别的切过去；底下加账号——导另一个账号的存档，或者新建空白账号。
struct TwitterAccountsSheet: View {
    let accounts: [TwitterArchiveAccount]
    let active: TwitterArchiveAccount?
    let mediaDir: URL
    let accent: Color
    let onSwitch: (TwitterArchiveAccount) -> Void
    let onImport: () -> Void
    let onCreate: (String, String) throws -> Void
    let onClose: () -> Void

    @State private var creating = false
    @State private var name = ""
    @State private var handle = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("账号").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("完成", action: onClose).buttonStyle(.plain).foregroundStyle(accent)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(accounts, id: \.persistentModelID) { acc in
                        Button { onSwitch(acc) } label: {
                            HStack(spacing: 12) {
                                TwitterAvatarView(account: acc, mediaDir: mediaDir, size: 40, accent: accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(acc.displayName).font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Theme.textPrimary)
                                    if !acc.screenName.isEmpty {
                                        Text("@\(acc.screenName)").font(.system(size: 14))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                                Spacer()
                                if acc.persistentModelID == active?.persistentModelID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().opacity(0.4).padding(.vertical, 8)

                    Button(action: onImport) {
                        Label("导入另一个账号的存档", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 20)
                    .frame(height: 44)

                    if creating {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("名字", text: $name).textFieldStyle(.roundedBorder)
                            TextField("用户名（可不填）", text: $handle).textFieldStyle(.roundedBorder)
                            HStack {
                                Button("取消") { creating = false; errorText = nil }
                                    .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
                                Spacer()
                                Button("建好") {
                                    do { try onCreate(name, handle) }
                                    catch { errorText = "名字不能为空。" }
                                }
                                .buttonStyle(.borderedProminent).tint(accent)
                            }
                            if let errorText {
                                Text(errorText).font(.footnote).foregroundStyle(Theme.danger)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    } else {
                        Button { creating = true } label: {
                            Label("新建空白账号", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                    }
                    Text("每个账号一条时间线，互不串。导入的存档是哪个账号，就进哪个账号。")
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 20).padding(.top, 8)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(Theme.mainBg)
    }
}
