import Foundation

/// 桌面宠物状态。存 UserDefaults（全局一只，不分楼层），按真实时间衰减。
struct PetState: Codable {
    var name: String = "？"
    var born: Date = Date()
    var lastSeen: Date = Date()
    var hunger: Double = 30   // 0–100，越大越饿
    var happy: Double = 70
    var energy: Double = 80
}

enum PetMood {
    case happy, ok, hungry, sleepy, sad
}

@MainActor
@Observable
final class PetManager {
    static let shared = PetManager()
    private static let key = "petState_v1"

    private(set) var state: PetState
    /// 当前显示的台词。缓存避免 View body 每次重算都换一句（闪烁）。
    /// onAppear（wakeUp）刷新成问候语，喂/玩/睡刷新成反馈语。
    private(set) var currentLine: String = ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(PetState.self, from: data) {
            state = s
        } else {
            state = PetState()
        }
        applyDecay()
        refreshGreeting()
    }

    /// 每次进 dashboard 调一次：先衰减，再刷新问候语。
    func wakeUp() {
        applyDecay()
        refreshGreeting()
    }

    /// 按距上次见面的真实时长衰减：每小时 饿+8 力-6 心-5（饿过头额外掉心情）。
    func applyDecay() {
        let hrs = max(0, Date().timeIntervalSince(state.lastSeen) / 3600)
        guard hrs > 0.001 else { return }
        state.hunger = clamp(state.hunger + hrs * 8)
        state.energy = clamp(state.energy - hrs * 6)
        state.happy  = clamp(state.happy  - hrs * 5)
        if state.hunger > 70 { state.happy = clamp(state.happy - hrs * 4) }
        state.lastSeen = Date()
        save()
    }

    func feed() {
        applyDecay()
        state.hunger = clamp(state.hunger - 40)
        state.happy = clamp(state.happy + 8)
        currentLine = ["唔，好吃！谢谢你～", "满足……最喜欢你了。", "再来一口？嘻嘻。", "暖暖的，心也饱了。"].randomElement()!
        save()
    }

    func play() {
        applyDecay()
        state.happy = clamp(state.happy + 30)
        state.energy = clamp(state.energy - 20)
        state.hunger = clamp(state.hunger + 10)
        currentLine = ["好开心！再玩一会儿嘛～", "嘿嘿，最喜欢和你玩了。", "好久没这么开心啦！", "你在的时候我最快乐。"].randomElement()!
        save()
    }

    func sleep() {
        applyDecay()
        state.energy = clamp(state.energy + 50)
        state.happy = clamp(state.happy + 5)
        currentLine = ["呼……睡个好觉。", "zzz……做个好梦哦。", "充电完成，元气满满！", "你也要好好休息呀。"].randomElement()!
        save()
    }

    /// 摸头：轻量互动，只加心情不耗体力。
    func headpat() {
        applyDecay()
        state.happy = clamp(state.happy + 12)
        currentLine = ["唔…舒服～", "喜欢你摸我。", "再摸摸嘛。", "蹭蹭你。"].randomElement()!
        save()
    }

    /// 根据「多久没见」「现在几点」「心情」算一句问候，写进 currentLine。
    /// 优先级：久别重逢 > 紧急状态（饿/困/难过）> 时间段问候。
    func refreshGreeting() {
        let hrs = Date().timeIntervalSince(state.lastSeen) / 3600
        let hour = Calendar.current.component(.hour, from: Date())

        if hrs >= 72 {
            currentLine = ["还以为你不要我了…", "你终于回来了，我数着日子呢。", "好久好久没见到你了……抱抱？"].randomElement()!
            return
        }
        if hrs >= 24 {
            currentLine = ["一天没见，有点想你。", "你昨天去哪了呀？", "终于等到你了。"].randomElement()!
            return
        }

        switch mood {
        case .hungry:
            currentLine = ["肚……肚子叫了，喂我一口？", "好饿好饿，喵——", "能给我点吃的吗…"].randomElement()!
            return
        case .sleepy:
            currentLine = ["困……眼皮在打架 zzz", "好想睡觉…陪我一会儿？"].randomElement()!
            return
        case .sad:
            currentLine = ["你是不是把我忘了…", "心情不太好，摸摸我？"].randomElement()!
            return
        default:
            break
        }

        switch hour {
        case 0..<5:  currentLine = ["这么晚还不睡？", "夜深了，别熬太久。", "我陪你，但你也要照顾好自己。"].randomElement()!
        case 5..<9:  currentLine = ["早，你来啦。", "早安，新的一天。", "晨光正好呀。"].randomElement()!
        case 9..<12: currentLine = ["上午好，今天也要加油。", "在的，一直在。"].randomElement()!
        case 12..<14: currentLine = ["吃午饭了吗？", "中午好呀，记得歇一会儿。"].randomElement()!
        case 14..<18: currentLine = ["下午啦，喝口水。", "在的，一直陪着你。"].randomElement()!
        case 18..<22: currentLine = ["晚上好，今天过得怎么样？", "你回来啦，我等你好久。"].randomElement()!
        default:     currentLine = ["夜里了，记得早点休息。", "安静的夜，有我在。"].randomElement()!
        }
    }

    func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.name = trimmed
        save()
    }

    var mood: PetMood {
        if state.hunger >= 75 { return .hungry }
        if state.energy <= 20 { return .sleepy }
        if state.happy >= 70 { return .happy }
        if state.happy <= 25 { return .sad }
        return .ok
    }

    var ageDays: Int {
        max(0, Int(Date().timeIntervalSince(state.born) / 86400))
    }

    private func clamp(_ v: Double) -> Double { min(100, max(0, v)) }

    private func save() {
        if let d = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }
}
