import Foundation

// MARK: - 小芽 · 拼贴贴纸规则（plan-onboarding-xiaoya-impl §12-A「小样定稿」；小样 design-onboarding-xiaoya-v3.html 6）
// 贴纸只是点缀：她那句话右上角外侧偶尔一张（问号 = 在问你、感叹号 = 重要、爱心 = 完成），完成一步在卡角「啪」拍一枚星爆。
// 哪句贴什么、哪张卡拍星爆、一屏几张，全写在这一处（XiaoyaV3Tests 有断言）。画法在 Views/Assistant/XiaoyaPaperSticker.swift。

/// 贴纸库（小样 SHAPES）
enum XiaoyaStickerKind: String, CaseIterable {
    case burst, heart, ques, excl, bubble, bolt, bulb
}

/// 一条消息上的点缀
enum XiaoyaDecor: Equatable {
    /// 她那句话右上角外侧
    case line(XiaoyaStickerKind)
    /// 卡角「啪」的星爆
    case stamp
}

enum XiaoyaStickerRule {
    /// 一屏最多几张：只给最近的这几处贴（旧的往上滚走了就不贴，屏上永远不超过它）
    static let limit = 2
    /// 往回最多看几条消息找贴纸
    private static let lookback = 24

    /// 剧本台词贴什么：完成 > 重要 > 在问你；都不是就不贴
    static func sticker(forLine text: String) -> XiaoyaStickerKind? {
        let L = XiaoyaScriptLines.self
        if text == L.end || text.hasPrefix("钥匙好使") { return .heart }
        if text == L.ghost.last || text == L.keySkipped || text.hasPrefix("没建成") || text.hasPrefix("没导进去") { return .excl }
        if text.hasSuffix("？") || text.hasSuffix("?") { return .ques }
        return nil
    }

    /// 完成一步的卡：答案是这几种才拍星爆
    static func stamps(_ answer: XiaoyaCardAnswer) -> Bool {
        switch answer {
        case .keySaved, .imported, .named, .face, .paired: return true
        default: return false
        }
    }

    static func decor(_ message: AssistantChatMessage) -> XiaoyaDecor? {
        guard !message.isUser, message.source == .script else { return nil }
        if let state = message.card {
            guard let answer = state.answer, stamps(answer) else { return nil }
            return .stamp
        }
        return sticker(forLine: message.text).map(XiaoyaDecor.line)
    }

    /// 这一屏贴哪几处：从最新往回数，最多 limit 处
    static func decorations(_ messages: [AssistantChatMessage]) -> [UUID: XiaoyaDecor] {
        var out: [UUID: XiaoyaDecor] = [:]
        for message in messages.suffix(lookback).reversed() {
            guard out.count < limit else { break }
            if let decor = decor(message) { out[message.id] = decor }
        }
        return out
    }
}
