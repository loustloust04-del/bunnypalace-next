import SwiftUI

// MARK: - 小芽引导卡 · 分派（P4 剧本引擎按消息上的 XiaoyaCardState 画卡）
// 卡片对外只发 onAnswer；会写数据的两处（key 卡落盘、扫码落地）由调用方通过 context 注入。

struct XiaoyaCardContext {
    /// key 卡的内存草稿：调用方持有（剧本引擎看它的 phase 换舞台表情），同一张 key 卡全程用同一个
    var keyModel: XiaoyaKeyCardModel
    /// 「就用这个」：P4 接 CredentialCommitter.commit(draft, key:, existing: nil, adopt: .model(modelId), providerManager:)
    var commitKey: XiaoyaKeyCardModel.Commit
    /// 导卡时「卡里的 {{user}} 会叫你「X」」：默认称呼，空 → 「你」
    var userName: String
    #if os(iOS)
    /// 扫码落地：P4 接 XiaoyaPairOutcome.applying(providerManager:)（= CCPairingApply.apply）
    var applyPairing: @MainActor (CCPairPayload) async -> XiaoyaPairOutcome
    #endif
    /// 挑名字卡随机时躲开的名字（楼层里已有的 Ta 名 / 称呼）
    var takenNames: [String] = []
    /// 挑头像卡收起后：相册选的图从当前楼层读回来画
    var avatarData: (XiaoyaFaceTarget) -> Data? = { _ in nil }
    /// Tip 卡底的「懂了，下一条 / 以后再看」：对话里最新那张 tip 才给（§12-B）
    var showsTipChips = false
}

struct XiaoyaCardView: View {
    let state: XiaoyaCardState
    let context: XiaoyaCardContext
    let onAnswer: (XiaoyaCardAnswer) -> Void

    var body: some View {
        switch state.card {
        case .choice(let payload):
            XiaoyaChoiceCardView(payload: payload, answer: state.answer, onAnswer: onAnswer)
        case .keyForm:
            XiaoyaKeyCardView(model: context.keyModel, answer: state.answer, commit: context.commitKey, onAnswer: onAnswer)
        case .importCard:
            XiaoyaImportCardView(answer: state.answer, userName: context.userName, onAnswer: onAnswer)
        case .nameForm:
            XiaoyaNameCardView(answer: state.answer, prefillUserName: context.userName, onAnswer: onAnswer)
        case .floorExit(let payload):
            XiaoyaFloorExitCardView(payload: payload, answer: state.answer, onAnswer: onAnswer)
        case .goTa(let ta):
            XiaoyaGoTaCardView(ta: ta, onAnswer: onAnswer)
        case .pair:
            #if os(iOS)
            XiaoyaPairCardView(answer: state.answer, apply: context.applyPairing, onAnswer: onAnswer)
            #else
            EmptyView()     // mac 不出扫码卡
            #endif
        case .todo(let items):
            XiaoyaTodoCardView(items: items)
        case .info:
            XiaoyaInfoCardView()
        case .makeTa:
            XiaoyaMakeTaCardView(answer: state.answer, onAnswer: onAnswer)
        case .face(let target):
            XiaoyaFaceCardView(target: target, answer: state.answer, context: context, onAnswer: onAnswer)
        case .tip(let ref):
            XiaoyaTipCardView(ref: ref, answer: state.answer, showsChips: context.showsTipChips, onAnswer: onAnswer)
        case .survey(let name):
            XiaoyaSurveyCardView(prefillName: name, answer: state.answer, onAnswer: onAnswer)
        case .unsupported:
            EmptyView()     // 新版的卡：只显示消息 text 兜底
        }
    }
}
