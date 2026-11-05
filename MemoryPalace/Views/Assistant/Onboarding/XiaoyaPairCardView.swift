#if os(iOS)
import SwiftUI

// MARK: - 扫码卡（小样 pairCard：⑫ 技术线「有 Mac 吗 → 有，连上」）
// 相机走设置页同一个 CCPairScannerSheet；扫到之后的落地由调用方注入（P4 接 CCPairingApply.apply，和设置页扫码同一份），
// 卡片自己不写钥匙串 / 地址。mac 上没有这张卡（相机扫码是手机的事）。

/// 扫到码之后的落地结果
enum XiaoyaPairOutcome: Equatable {
    case paired(String)     // 「已配对 ✓ LAN+Tailscale」
    case failed(String)     // 「二维码里的地址不合法」
}

enum XiaoyaPairPhase: Equatable {
    case idle
    case pairing
    case paired(String)
    case failed(String)
}

struct XiaoyaPairCardView: View {
    let answer: XiaoyaCardAnswer?
    let apply: (CCPairPayload) -> XiaoyaPairOutcome
    let onAnswer: (XiaoyaCardAnswer) -> Void

    @State private var phase: XiaoyaPairPhase
    @State private var scanning = false

    init(answer: XiaoyaCardAnswer?, initialPhase: XiaoyaPairPhase = .idle,
         apply: @escaping (CCPairPayload) -> XiaoyaPairOutcome,
         onAnswer: @escaping (XiaoyaCardAnswer) -> Void) {
        self.answer = answer
        self.apply = apply
        self.onAnswer = onAnswer
        _phase = State(initialValue: initialPhase)
    }

    var body: some View {
        XiaoyaCardFrame(kicker: "连电脑", question: "扫个码，Mac 上的 Claude Code / Codex / 终端就连上了") {
            switch answer {
            case .paired(let summary)?:
                okBar(summary)
                    .padding(.top, -12)
            case .later?:
                XiaoyaCardSummary(text: XiaoyaCardAnswer.later.summary) { EmptyView() }
            default:
                live
            }
        }
        .sheet(isPresented: $scanning) {
            CCPairScannerSheet { payload in
                phase = .pairing
                // 等扫码页关掉再落地，结果条和相机不抢同一帧
                DispatchQueue.main.async {
                    switch apply(payload) {
                    case .paired(let summary):
                        phase = .paired(summary)
                        onAnswer(.paired(summary))
                    case .failed(let why):
                        phase = .failed(why)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var live: some View {
        switch phase {
        case .idle, .failed:
            XiaoyaSkinReader { skin in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(skin.ink.opacity(0.85))
                        .frame(width: 96, height: 96)
                        .background(skin.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(skin.line, lineWidth: 1))
                    Text("① Mac 上打开记忆花园 → 设置 › 让手机连这台 Mac，会出一个二维码\n② 点下面按钮用相机扫它")
                        .font(.system(size: XiaoyaCardFont.hint))
                        .foregroundStyle(skin.inkMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .failed(let why) = phase {
                XiaoyaResultBar(tone: .bad, badge: "!", title: "没配上") {
                    Text(why).fixedSize(horizontal: false, vertical: true)
                }
            }
            XiaoyaCardActions {
                Button(phase == .idle ? "打开相机扫码" : "再扫一次") { scanning = true }
                    .buttonStyle(.xiaoya(.primary))
                Button("以后再说") { onAnswer(.later) }
                    .buttonStyle(.xiaoya(.text))
            }
        case .pairing:
            XiaoyaResultBar(tone: .wait, title: "在配对…")
                .padding(.top, -12)
        case .paired(let summary):
            okBar(summary)
                .padding(.top, -12)
        }
    }

    private func okBar(_ summary: String) -> some View {
        XiaoyaResultBar(tone: .ok, badge: "✓", title: summary) {
            Text("Claude Code、Codex、终端在 gardenOS 桌面上能用了。和设置页扫码是同一份配置。")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension XiaoyaPairOutcome {
    /// P4 接线用：落地走 CCPairingApply.apply（和设置页扫码同一份）。apply 只回一句话，成功那句以「已配对」开头
    static func applying(providerManager: ProviderManager?) -> (CCPairPayload) -> XiaoyaPairOutcome {
        { payload in
            let line = CCPairingApply.apply(payload, providerManager: providerManager)
            return line.hasPrefix("已配对") ? .paired(line) : .failed(line)
        }
    }
}
#endif
