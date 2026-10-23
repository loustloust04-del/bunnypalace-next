import SwiftUI
import SwiftData

// MARK: - 文件夹图标

/// 文件夹图标：`symbol` 非空画 SF Symbol（带色），否则画 emoji。tab / 菜单 / 文件夹头共用。
struct FolderIconView: View {
    let tag: ConversationTag
    var size: CGFloat = 14

    var body: some View {
        if tag.symbol.isEmpty {
            Text(tag.emoji)
                .font(.system(size: size))
        } else {
            Image(systemName: tag.symbol)
                .font(.system(size: size * 0.9, weight: .medium))
                .foregroundColor(FolderPalette.color(tag.colorHex))
        }
    }
}

// MARK: - 文件夹卡片底边的点点小花

/// 和开屏同一套点点花（四叶草 / 郁金香 / 绒球 / 铃铛、点点茎、同一组颜色）。
/// 按文件夹 id 定随机：同一个文件夹每次都是这 1–3 朵，不同文件夹各不一样。只长在右半边、贴着底边。
struct FolderFlowers: View {
    let seed: String

    private static let palette: [UInt] = [0x7FA58D, 0xD99AA5, 0xE3A9B0, 0xC98F9E, 0x8FA9C9, 0xB3A2CC, 0xD9A07F, 0xC7B27A]
    private static let kinds = [clover, clover, tulip, pom, bell]

    private static func shape(_ test: (CGFloat, CGFloat) -> Bool) -> [CGPoint] {
        var pts: [CGPoint] = []
        for iy in 0...8 {
            for ix in 0...8 {
                let x = -1.2 + CGFloat(ix) * 0.3, y = -1.2 + CGFloat(iy) * 0.3
                if test(x, y) { pts.append(CGPoint(x: x, y: y)) }
            }
        }
        return pts
    }
    private static func inC(_ x: CGFloat, _ y: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Bool {
        (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
    }
    private static let clover = shape { x, y in
        inC(x, y, 0.5, 0, 0.52) || inC(x, y, -0.5, 0, 0.52) || inC(x, y, 0, 0.5, 0.52) || inC(x, y, 0, -0.5, 0.52)
    }
    private static let tulip = shape { x, y in
        (inC(x, y, 0, 0.15, 0.72) && y > -0.25) || inC(x, y, -0.42, -0.42, 0.3) || inC(x, y, 0, -0.62, 0.3) || inC(x, y, 0.42, -0.42, 0.3)
    }
    private static let pom = shape { x, y in inC(x, y, 0, 0, 0.82) && !inC(x, y, 0, 0, 0.25) }
    private static let bell = shape { x, y in
        (inC(x, y, 0, -0.1, 0.6) && y > -0.5) || (y >= 0.3 && y < 0.7 && abs(x) < 0.75 - (y - 0.3) * 0.2)
    }

    /// FNV-1a：跨启动稳定（`hashValue` 每次启动都变）
    private static func fnv(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for u in s.unicodeScalars { h = (h ^ u.value) &* 16777619 }
        return h
    }

    private static func index(_ unit: CGFloat, count: Int) -> Int {
        min(count - 1, Int(unit * CGFloat(count)))
    }

    /// mulberry32，[0, 1)
    private struct RNG {
        var s: UInt32
        mutating func next() -> CGFloat {
            s = s &+ 0x6D2B79F5
            var t = s
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return CGFloat(t ^ (t >> 14)) / 4294967296
        }
    }

    var body: some View {
        Canvas { ctx, size in
            var rng = RNG(s: Self.fnv(seed))
            let count = 1 + Int(rng.next() * 3)
            var used: [CGFloat] = []
            for _ in 0..<count {
                var picked: CGFloat?
                for _ in 0..<20 {
                    let c = size.width * (0.46 + rng.next() * 0.4)
                    if used.allSatisfy({ abs($0 - c) > 34 }) { picked = c; break }
                }
                guard let x = picked else { continue }
                used.append(x)
                let sc = 0.9 + rng.next() * 0.35
                let stemH = (17 + rng.next() * 11) * sc
                let headR = (8.5 + rng.next() * 3.5) * sc
                let r = 1.3 * sc, sp = 2.5 * sc
                let kind = Self.kinds[Self.index(rng.next(), count: Self.kinds.count)]
                let hex: UInt = Self.palette[Self.index(rng.next(), count: Self.palette.count)]
                let color = Color(hex: hex)
                let base = size.height + 1, lean = (rng.next() - 0.5) * 6

                var stem = Path()
                let steps = Int(stemH / sp)
                for j in 0...max(steps, 1) {
                    let fr = CGFloat(j) / CGFloat(max(steps, 1))
                    let p = CGPoint(x: x + lean * fr * fr, y: base - CGFloat(j) * sp)
                    stem.addEllipse(in: CGRect(x: p.x - r * 0.75, y: p.y - r * 0.75, width: r * 1.5, height: r * 1.5))
                }
                if rng.next() < 0.6 {
                    let ly = base - stemH * 0.35
                    for j in 1...2 {
                        let side: CGFloat = rng.next() < 0.5 ? -1 : 1
                        let p = CGPoint(x: x + side * CGFloat(j) * sp * 0.9, y: ly - CGFloat(j) * sp * 0.55)
                        stem.addEllipse(in: CGRect(x: p.x - r * 0.85, y: p.y - r * 0.85, width: r * 1.7, height: r * 1.7))
                    }
                }
                ctx.fill(stem, with: .color(Color(hex: 0x8FAE9B).opacity(0.8)))

                let head = CGPoint(x: x + lean, y: base - stemH)
                var petals = Path()
                for p in kind {
                    let c = CGPoint(x: head.x + p.x * headR, y: head.y + p.y * headR)
                    petals.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                }
                ctx.fill(petals, with: .color(color.opacity(0.85)))
                if kind == Self.clover {
                    ctx.fill(Path(ellipseIn: CGRect(x: head.x - r * 1.5, y: head.y - r * 1.5, width: r * 3, height: r * 3)),
                             with: .color(Color(hex: 0xFBF8EE)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

enum FolderPalette {
    /// 暖奶白底上的低饱和色；不用蓝、不用黄（粟粟点名）
    static let hexes = ["#7FB39A", "#CF9A8A", "#B79CC0", "#D4A5A5", "#A89080", "#9A9D98"]

    static let symbols = [
        "folder", "tray.full", "chevron.left.forwardslash.chevron.right", "terminal", "hammer", "wrench.and.screwdriver",
        "book", "books.vertical", "text.book.closed", "pencil", "highlighter", "doc.text",
        "lightbulb", "brain", "sparkles", "star", "heart", "moon",
        "sun.max", "leaf", "camera.macro", "cup.and.saucer", "fork.knife", "cart",
        "dollarsign.circle", "chart.line.uptrend.xyaxis", "briefcase", "graduationcap", "globe.asia.australia", "airplane",
        "house", "music.note", "gamecontroller", "paintpalette", "photo", "film",
        "bubble.left.and.bubble.right", "person.2", "pawprint", "gift",
    ]

    static func color(_ hex: String) -> Color {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt(digits, radix: 16) else { return Theme.textMuted }
        return Color(hex: value)
    }
}

// MARK: - 新建 / 编辑文件夹

struct FolderEditSheet: View {
    let profileId: String
    /// nil = 新建
    let tag: ConversationTag?
    var onCreated: ((ConversationTag) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum IconKind { case emoji, symbol }

    @State private var kind: IconKind = .emoji
    @State private var emoji = "📁"
    @State private var symbol = "folder"
    @State private var colorHex = FolderPalette.hexes[0]
    @State private var name = ""
    @State private var instructions = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("图标类型", selection: $kind) {
                        Text("Emoji").tag(IconKind.emoji)
                        Text("图标").tag(IconKind.symbol)
                    }
                    .pickerStyle(.segmented)
                    if kind == .emoji {
                        TextField("点这里，切到 emoji 键盘挑一个", text: $emoji)
                            .onChange(of: emoji) { _, new in
                                // 只留最后一个字位（系统 emoji 键盘点一下就替换）
                                if new.count > 1, let last = new.last { emoji = String(last) }
                            }
                    } else {
                        symbolGrid
                        colorRow
                    }
                } header: {
                    preview
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                }

                Section("名字") {
                    TextField("文件夹名字", text: $name)
                }

                Section {
                    TextField("比如：这里都是写代码的对话，回答直接给专业级方案", text: $instructions, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("文件夹说明")
                } footer: {
                    Text("这个文件夹里的 API 对话都会带上这段话。连着 Code 的对话暂时不会带。群聊不会带。")
                }
            }
            .navigationTitle(tag == nil ? "新建文件夹" : "编辑文件夹")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 560)
        #endif
        .onAppear(perform: load)
    }

    /// 同文件夹卡片：白底圆角方块 + 淡阴影，图标原色落在白底上（不深绿套浅绿）
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 6)
            if kind == .symbol {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(FolderPalette.color(colorHex))
            } else {
                Text(emoji.isEmpty ? "📁" : emoji).font(.system(size: 30))
            }
        }
        .frame(width: 64, height: 64)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(FolderPalette.symbols, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: 15))
                    .foregroundColor(symbol == name ? FolderPalette.color(colorHex) : Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(symbol == name ? Color.clear : Color.primary.opacity(0.04))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.branchIndicator.opacity(symbol == name ? 0.6 : 0), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { symbol = name }
            }
        }
        .padding(.vertical, 4)
    }

    private var colorRow: some View {
        HStack(spacing: 14) {
            ForEach(FolderPalette.hexes, id: \.self) { hex in
                Circle()
                    .fill(FolderPalette.color(hex))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(colorHex == hex ? 0.45 : 0), lineWidth: 2).padding(-4))
                    .contentShape(Circle())
                    .onTapGesture { colorHex = hex }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func load() {
        guard let tag else { return }
        name = tag.name
        instructions = tag.instructions
        emoji = tag.emoji
        if !tag.symbol.isEmpty {
            kind = .symbol
            symbol = tag.symbol
            if !tag.colorHex.isEmpty { colorHex = tag.colorHex }
        }
    }

    private func save() {
        let target: ConversationTag
        if let tag {
            target = tag
        } else {
            let pid = profileId
            let count = (try? modelContext.fetchCount(FetchDescriptor<ConversationTag>(
                predicate: #Predicate<ConversationTag> { $0.profileId == pid }))) ?? 0
            target = ConversationTag(name: trimmedName, order: count, profileId: profileId)
            modelContext.insert(target)
        }
        target.name = trimmedName
        target.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        target.emoji = emoji.isEmpty ? "📁" : emoji
        target.symbol = kind == .symbol ? symbol : ""
        target.colorHex = kind == .symbol ? colorHex : ""
        try? modelContext.save()
        // C4 写点：SidebarView 的 tag 列表是显式 fetch，靠通知刷新
        NotificationCenter.default.post(name: .conversationTagsChanged, object: nil)
        if tag == nil { onCreated?(target) }
        dismiss()
    }
}

// MARK: - 头像 + 名字胶囊（气泡模式顶栏 / 文件夹头共用）

#if os(iOS)
/// 大圆头像悬浮 + 底下贴一个紧身玻璃名字胶囊（X chat 式上下结构）。
struct AvatarNameCapsule<Avatar: View>: View {
    let name: String
    var chevron: Bool = false
    @ViewBuilder let avatar: Avatar

    var body: some View {
        VStack(spacing: -8) {
            avatar
            HStack(spacing: 3) {
                Text(name)
                    .lineLimit(1)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule)
            // maxWidth 在 glass 外面：frame 贪婪撑宽但只是隐形容器，胶囊本体紧贴文字；超长名截断
            .frame(maxWidth: 170)
        }
    }
}
#endif
