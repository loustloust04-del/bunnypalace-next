import SwiftUI

/// 等待回复时轮换的文案。三个包：CC 动词（从 Claude Code 二进制里偷的 spinnerVerbs）/ 造世界（饥荒生成世界风）/ 自定义（一行一条，让用户的 AI 生成好贴进来）。
enum ThinkingPhrasePack: String, CaseIterable {
    case cc, worldgen, custom

    static let storageKey = "thinkingPhrasePack"
    static let customStorageKey = "thinkingCustomPhrases"

    var displayName: String {
        switch self {
        case .cc: return "CC 动词"
        case .worldgen: return "造世界"
        case .custom: return "自定义"
        }
    }

    /// 当前包的文案池（自定义为空时回落 CC）。每条末尾补「…」。
    static func pool(pack raw: String, custom: String) -> [String] {
        let pack = ThinkingPhrasePack(rawValue: raw) ?? .cc
        let base: [String]
        switch pack {
        case .cc: base = ccVerbs
        case .worldgen: base = worldgenLines
        case .custom:
            let lines = custom.split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            base = lines.isEmpty ? ccVerbs : lines
        }
        return base.map { $0.hasSuffix("…") || $0.hasSuffix("...") ? $0 : $0 + "…" }
    }

    static let ccVerbs: [String] = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'", "Befuddling",
        "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping", "Bootstrapping", "Brewing",
        "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing", "Cascading", "Catapulting", "Cerebrating",
        "Channeling", "Choreographing", "Churning", "Clauding", "Coalescing", "Cogitating", "Combobulating", "Composing",
        "Computing", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting", "Creating", "Crunching",
        "Crystallizing", "Cultivating", "Deciphering", "Deliberating", "Determining", "Dilly-dallying", "Discombobulating", "Doing",
        "Doodling", "Drizzling", "Ebbing", "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning",
        "Fermenting", "Fiddle-faddling", "Finagling", "Flambéing", "Flibbertigibbeting", "Flowing", "Flummoxing", "Fluttering",
        "Forging", "Forming", "Frolicking", "Frosting", "Gallivanting", "Galloping", "Garnishing", "Generating",
        "Gesticulating", "Germinating", "Gitifying", "Grooving", "Gusting", "Harmonizing", "Hashing", "Hatching",
        "Herding", "Honking", "Hullaballooing", "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating",
        "Inferring", "Infusing", "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening", "Levitating",
        "Lollygagging", "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting", "Moonwalking", "Moseying",
        "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Newspapering", "Noodling", "Nucleating",
        "Orbiting", "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing", "Philosophising", "Photosynthesizing",
        "Pollinating", "Pondering", "Pontificating", "Pouncing", "Precipitating", "Prestidigitating", "Processing", "Proofing",
        "Propagating", "Puttering", "Puzzling", "Quantumizing", "Razzle-dazzling", "Razzmatazzing", "Recombobulating", "Reticulating",
        "Roosting", "Ruminating", "Sautéing", "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing",
        "Shimmying", "Simmering", "Skedaddling", "Sketching", "Slithering", "Smooshing", "Sock-hopping", "Spelunking",
        "Spinning", "Sprouting", "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing",
        "Tempering", "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Topsy-turvying", "Transfiguring", "Transmuting",
        "Twisting", "Undulating", "Unfurling", "Unravelling", "Vibing", "Waddling", "Wandering", "Warping",
        "Whatchamacalliting", "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting",
        "Zigzagging",
    ]

    static let worldgenLines: [String] = [
        "正在生成世界", "正在铺地图", "正在种树", "正在摆石头", "正在挖兔子洞",
        "正在放萤火虫", "正在调昼夜", "正在腌制想法", "正在酝酿", "正在打草稿",
        "正在搓句子", "正在排列词语", "正在给逗号找位置", "正在翻旧账", "正在挖记忆",
        "正在数星星", "正在织毛线", "正在烧开水", "正在等面团发起来", "正在拧螺丝",
        "正在校准罗盘", "正在画等高线", "正在召唤灵感", "正在拾掇碎片", "正在把念头串起来",
        "正在慢炖", "正在磨墨", "正在铺路", "正在修剪枝叶", "正在攒词",
        "正在打捞句子", "正在把云揉开", "正在摇晃雪花球", "正在掂量", "正在绕远路",
        "正在走神", "正在回神", "正在翻箱倒柜", "正在把字摆正", "正在烘焙",
    ]
}

/// 轮换 shimmer 文案：每 2.6s 换一条（随机顺序），淡入淡出。
struct RotatingShimmerLabel: View {
    @AppStorage(ThinkingPhrasePack.storageKey) private var packRaw = ThinkingPhrasePack.cc.rawValue
    @AppStorage(ThinkingPhrasePack.customStorageKey) private var custom = ""
    @State private var order: [String] = []
    @State private var start = Date()

    private let interval: TimeInterval = 2.6

    var body: some View {
        TimelineView(.periodic(from: start, by: interval)) { tl in
            let idx = max(0, Int(tl.date.timeIntervalSince(start) / interval))
            let phrase = order.isEmpty ? "…" : order[idx % order.count]
            ZStack(alignment: .leading) {
                ShimmerText(text: phrase)
                    .id(phrase)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: idx)
        }
        .onAppear {
            order = ThinkingPhrasePack.pool(pack: packRaw, custom: custom).shuffled()
            start = Date()
        }
    }
}

/// 设置页：文案包三选 + 自定义编辑框（一行一条）。
struct ThinkingPhrasePackPicker: View {
    let fontSize: CGFloat
    @AppStorage(ThinkingPhrasePack.storageKey) private var packRaw = ThinkingPhrasePack.cc.rawValue
    @AppStorage(ThinkingPhrasePack.customStorageKey) private var custom = ""

    var body: some View {
        Picker("", selection: $packRaw) {
            ForEach(ThinkingPhrasePack.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if packRaw == ThinkingPhrasePack.custom.rawValue {
            TextEditor(text: $custom)
                .font(.system(size: fontSize + 1))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.5)))
            Text("一行一条，末尾不用加省略号。可以让你的 AI 写一批贴进来。")
                .font(.system(size: fontSize))
                .foregroundColor(Theme.textMuted)
        }
    }
}
