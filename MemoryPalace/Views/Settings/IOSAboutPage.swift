import SwiftUI

#if os(iOS)

struct IOSAboutPage: View {
    @State private var feedbackPayload: FeedbackPayload?

    private static let repositoryURL = URL(string: "https://github.com/replica882/mneme-atrium")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("AboutLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Text("记忆花园 · Mneme Atrium")
                        .font(.system(size: Theme.SettingsFont.label, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)

                    Text("原生 AI 对话浏览器与聊天客户端，数据全本地")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Theme.mainBg)

                HStack {
                    Text("版本")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.versionLine)
                        Text(FeedbackStore.buildDateString)
                    }
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
                }
                .listRowBackground(Theme.mainBg)

                NavigationLink {
                    IOSAcknowledgementsPage()
                } label: {
                    Text("开源致谢")
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textPrimary)
                }
                .listRowBackground(Theme.mainBg)

                Button {
                    presentFeedback()
                } label: {
                    HStack {
                        Text("报告问题")
                            .font(.system(size: Theme.SettingsFont.body))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
            } footer: {
                VStack(spacing: 6) {
                    Link(destination: Self.repositoryURL) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text(verbatim: "replica882/mneme-atrium")
                        }
                        .font(.system(size: Theme.SettingsFont.caption, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                    }

                    Text("本项目以 AGPL-3.0 发布，源码见此")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("关于记忆花园")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $feedbackPayload) { payload in
            FeedbackSheet(payload: payload)
                .presentationDetents([.large])
                .presentationBackground(Theme.mainBg)
        }
    }

    private func presentFeedback() {
        var ctx = FeedbackStore.Context()
        ctx.pageDescription = "设置 › 关于记忆花园"
        feedbackPayload = FeedbackPayload(screenshot: FeedbackStore.captureScreenshot(), context: ctx)
    }

    // MARK: - 版本信息

    private static var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#endif
