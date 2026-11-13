#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Observation

struct TutuChatCardArrival {
    private(set) var times: [Double] = []
    mutating func receive(count: Int, at time: Double) {
        while times.count < count { times.append(max(time, (times.last ?? (time - 0.34)) + 0.34)) }
    }
    mutating func settle(count: Int, at time: Double) {
        while times.count > count { times.removeLast() }
        for index in times.indices { times[index] = time - 1.1 }
        while times.count < count { times.append(time - 1.1) }
    }
    func lift(index: Int, at time: Double) -> Double {
        guard times.indices.contains(index) else { return 1 }
        return pow(1 - TutuChatAnimation.span(time, times[index], times[index] + 0.42), 3)
    }
    func opacity(index: Int, at time: Double) -> Double {
        guard times.indices.contains(index) else { return 0 }
        return TutuChatAnimation.smooth(TutuChatAnimation.span(time, times[index], times[index] + 0.1))
    }
}

enum TutuChatAnimation {
    static func span(_ time: Double, _ begin: Double, _ end: Double) -> Double { min(1, max(0, (time - begin) / (end - begin))) }
    static func smooth(_ value: Double) -> Double { value * value * (3 - 2 * value) }
    static func outCubic(_ value: Double) -> Double { 1 - pow(1 - value, 3) }
    static func inOut(_ value: Double) -> Double { value < 0.5 ? 4 * value * value * value : 1 - pow(-2 * value + 2, 3) / 2 }
    static func rounded(_ value: Double) -> Double { floor(value * 100 + 0.5) / 100 }
}

@MainActor @Observable
final class TutuChatAnimationTimeline {
    static let shared = TutuChatAnimationTimeline()
    struct Entry {
        var sentAt: Double?
        var intro = false
        var recallAt: Double?
        var cards = TutuChatCardArrival()
        var settled = false
        var laceAt: Double? {
            if intro, let sentAt { return sentAt + 0.8 }
            return cards.times.first.map { $0 - 0.25 }
        }
        var deadline: Double {
            max((sentAt ?? -Double.infinity) + 0.62,
                max((cards.times.last ?? -Double.infinity) + 0.42, (laceAt ?? -Double.infinity) + 1.1))
        }
    }
    private(set) var conversationID: String?
    private(set) var entries: [String: Entry] = [:]
    private var seen = Set<String>()
    private var introSendAt: Double?

    func mount(conversationID: String?, existingIDs: [String]) {
        guard self.conversationID != conversationID else { return }
        self.conversationID = conversationID
        entries.removeAll(); seen = Set(existingIDs); introSendAt = nil
    }
    func sent(conversationID: String, existingIDs: Set<String>, userID: String, assistantIDs: [String], at time: Double, intro: Bool) {
        if self.conversationID != conversationID {
            self.conversationID = conversationID
            entries.removeAll(); seen = existingIDs
        }
        seen.insert(userID)
        entries[userID] = Entry(sentAt: time, intro: intro)
        introSendAt = intro ? time : nil
        for id in assistantIDs { allowAssistant(id: id, at: time) }
    }
    func allowAssistant(id: String, at time: Double) {
        guard seen.insert(id).inserted else { return }
        entries[id] = Entry(sentAt: introSendAt, intro: introSendAt != nil)
    }
    func receive(_ message: TutuChatMessageSnapshot, at time: Double) {
        guard var entry = entries[message.id], !entry.settled, !message.isUser else { return }
        if message.hasRecall, entry.recallAt == nil {
            entry.recallAt = time
            entries[message.id] = entry
        }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.isRich else { return }
        let count = message.isRich ? 1 : TutuChatContent.cards(message.text).count
        guard count > entry.cards.times.count else { return }
        entry.cards.receive(count: count, at: time)
        entries[message.id] = entry
    }
    func resume(_ message: TutuChatMessageSnapshot, at time: Double) {
        guard var entry = entries[message.id], entry.settled else { return }
        let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let count = message.isUser ? 0 : (message.isRich ? 1 : (hasText ? TutuChatContent.cards(message.text).count : 0))
        entry.cards.settle(count: count, at: time)
        entry.sentAt = nil; entry.intro = false
        entry.recallAt = message.hasRecall ? time - 0.35 : nil
        entry.settled = false; entries[message.id] = entry
    }
    func settle(nodeID: String) {
        guard var entry = entries[nodeID], !entry.settled else { return }
        entry.settled = true; entries[nodeID] = entry
    }
    func settleAll() {
        for id in entries.keys { settle(nodeID: id) }
        introSendAt = nil
    }
    func finishIntro() { introSendAt = nil }
    func leave() {
        conversationID = nil; entries.removeAll(); seen.removeAll(); introSendAt = nil
    }
}

#endif
#endif
