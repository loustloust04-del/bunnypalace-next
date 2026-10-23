import SwiftUI

#if os(macOS)

/// mac 设置 › 关于：版本 + 开源致谢入口 + 源码链接。头卡（标题 / 副标题 / 图标）由 `MacSettingsPage` 画。
/// 报告问题走开发调试页，检查更新在菜单「记忆花园 › 检查更新…」，这里不重复。
struct MacAboutPage: View {
    private static let repositoryURL = URL(string: "https://github.com/replica882/mneme-atrium")!

    var body: some View {
        SettingsSectionList {
            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.versionLine)
                        Text(FeedbackStore.buildDateString)
                    }
                    .font(ShellStyle.secondaryFont)
                    .foregroundStyle(ShellStyle.secondaryText)
                    .textSelection(.enabled)
                }

                SettingsNavRow(.acknowledgements) {
                    MacAcknowledgementsPage()
                } label: {
                    Text("开源致谢")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Link(destination: Self.repositoryURL) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text(verbatim: "replica882/mneme-atrium")
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }
                    Text("本项目以 AGPL-3.0 发布，源码见此")
                }
            }
        }
    }

    private static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// mac 设置 › 关于 › 开源致谢（`SettingsRoute.acknowledgements`）。数据与 iOS 共用 `Acknowledgements.current`，只列 mac 包里有的。
struct MacAcknowledgementsPage: View {
    var body: some View {
        SettingsSectionList {
            Section {
                Text(Acknowledgements.intro)
                    .font(ShellStyle.secondaryFont)
                    .foregroundStyle(ShellStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Acknowledgements.current) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        LicenseRow(entry: entry)
                    }
                }
            }
        }
    }
}

#endif
