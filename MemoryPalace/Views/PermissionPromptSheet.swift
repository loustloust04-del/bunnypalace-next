import SwiftUI

/// askOnce 权限弹卡（plan-权限管理 §2）：域名 + 说明 + 允许/不允许。
/// 露脸后 30s 不答 PermissionPromptCenter 按超时收口（不落档）；拖拽关闭 = 拒。
/// **计时从 `onAppear` 才起**（T6c ①）——卡还没 present 就烧秒数是 BUG-9 的根因。
struct PermissionPromptSheet: View {
    let request: PermissionPromptCenter.Request

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.branchIndicator)
                .padding(.top, 26)
            Text(copy.title)
                .font(.system(size: Theme.F.body, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(copy.summary)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let detail = request.detail {
                // 命令预览：只给第一行、截 80 字（长命令挤走按钮是 Minis 踩过的坑）
                Text(detail)
                    .font(.system(size: Theme.F.caption, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 24)
            }
            HStack(spacing: 12) {
                Button {
                    PermissionPromptCenter.shared.respond(to: request.id, allowed: false)
                } label: {
                    Text(copy.deny)
                        .font(.system(size: Theme.F.body))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                Button {
                    PermissionPromptCenter.shared.respond(to: request.id, allowed: true)
                } label: {
                    Text(copy.allow)
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            Text(copy.footer)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: 420)
        .background(Theme.mainBg)
        // CC 改文件的那种：标题和脚注各多一行
        .presentationDetents([.height(request.folderChange == nil ? 300 : 350)])
        .presentationDragIndicator(.visible)
        // 卡片内容真的上屏 → 作答计时从这一刻开始
        .onAppear { PermissionPromptCenter.shared.markPresented(request.id) }
    }

    /// 卡上文案：普通权限卡照旧；加密值确认卡（plan-secure-ask，secretLabels 非 nil）换一套
    private var copy: (title: String, summary: String, deny: String, allow: String, footer: String) {
        if let labels = request.secretLabels {
            return ("把加密值\(labels)交给 AI 使用？",
                    "AI 只看到占位，执行时由 app 换成真值；结果回给 AI 前会擦掉。",
                    "不允许", "允许这一次", "每次使用都会问你")
        }
        // CC 在电脑上改了记忆文件夹里的文件：说清第几处、动的是哪一份；划走 = 以后再说
        if let change = request.folderChange {
            return ("CC 在电脑上改了 \(change.total) 处，这是第 \(change.index) 处。允许动「\(request.domain.displayName)」吗？", change.what,
                    "这次不要", "允许这一次", "划走 = 以后再说，这一笔会一直等着；也可以到 设置→权限 把这一档改成自动允许。")
        }
        // 一笔一问的域（记忆条目）：这张只管这一次，不说「本对话记住」
        if request.domain.asksEveryCall {
            return ("允许 AI 这一次动「\(request.domain.displayName)」吗？", request.domain.summary,
                    "这次不要", "允许这一次", "每一笔都会问你；档位在 设置→权限 随时改。")
        }
        return ("允许 AI 在本对话使用「\(request.domain.displayName)」吗？",
                request.domain.summary,
                "本次不要", "允许", "本对话记住这次选择；档位在 设置→权限 随时改。")
    }
}
