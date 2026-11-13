import SwiftUI
import SwiftStreamingMarkdown
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// page2 浏览器主页（docs/plan-garden-browser-identities.md §2，设计稿第 1 / 3 / 6 张）：
/// 身份胶囊 + 设置 / 搜索或网址 / 收藏网格（网站图标 + 已登录小圆点）/ 最近（同网址一条）
struct BrowserHome: View {
    @Binding var identity: BrowserIdentity
    var onPick: (URL) -> Void

    @State private var identities: [BrowserIdentity] = []
    @State private var favorites: [BrowserFavorite] = []
    @State private var history: [BrowsingHistoryEntry] = []
    @State private var cookieDomains: Set<String> = []
    @State private var query = ""
    @State private var showSettings = false
    @State private var showEditFavorites = false
    @State private var showAddFavorite = false
    @State private var editingIdentity: BrowserIdentity?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topBar
                searchField
                favoritesSection
                if !history.isEmpty { recentSection }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolPageBackground()
        .task(id: identity.id) { await reload() }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await reload() } }) {
            BrowserSettingsSheet(current: $identity)
        }
        .sheet(isPresented: $showEditFavorites, onDismiss: { favorites = BrowserFavoritesStore.load(identity: identity.id) }) {
            FavoritesEditSheet(identity: identity)
        }
        .sheet(isPresented: $showAddFavorite) {
            AddFavoriteSheet(identityName: identity.name) { favorite in
                favorites.append(favorite)
                BrowserFavoritesStore.save(favorites, identity: identity.id)
            }
        }
        .sheet(item: $editingIdentity, onDismiss: { Task { await reload() } }) { draft in
            BrowserIdentityEditSheet(draft: draft, isNew: true) { saved in
                BrowserIdentityStore.setCurrent(saved.id)
                identity = saved
            }
        }
    }

    @MainActor
    private func reload() async {
        identities = BrowserIdentityStore.load()
        if let fresh = identities.first(where: { $0.id == identity.id }), fresh != identity { identity = fresh }
        favorites = BrowserFavoritesStore.load(identity: identity.id)
        history = BrowsingHistoryStore.load(identity: identity.id)
        cookieDomains = await BrowserIdentityStore.cookieDomains(identity)
    }

    // MARK: 顶上：身份 + 设置

    private var topBar: some View {
        HStack {
            Menu {
                ForEach(identities) { other in
                    Button {
                        BrowserIdentityStore.setCurrent(other.id)
                        identity = other
                    } label: {
                        if other.id == identity.id {
                            Label(other.name, systemImage: "checkmark")
                        } else {
                            Text(other.name)
                        }
                    }
                }
                Divider()
                Button {
                    let n = identities.count
                    editingIdentity = BrowserIdentity(id: UUID(), name: "身份 \(n + 1)",
                                                      colorHex: BrowserIdentityStore.palette[(n - 1) % BrowserIdentityStore.palette.count],
                                                      desktopUA: false)
                } label: { Label("新身份", systemImage: "plus") }
                Button { showSettings = true } label: { Label("管理身份", systemImage: "person.2") }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(identity.color).frame(width: 10, height: 10)
                    Text(identity.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(height: 36)
                .background(Capsule().fill(Theme.mainBg))
                .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.08)))
            }
            .accessibilityLabel("切换身份，当前：\(identity.name)")
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.mainBg))
                    .overlay(Circle().strokeBorder(Theme.textPrimary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("浏览器设置")
        }
    }

    // MARK: 搜索或网址

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textMuted)
            TextField("搜索或输入网址", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
                #if os(iOS)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { if let url = AddressInput.url(for: query) { onPick(url) } }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(Capsule().fill(Theme.mainBg).shadow(color: Theme.textPrimary.opacity(0.07), radius: 10, y: 4))
        .overlay(Capsule().strokeBorder(Theme.textPrimary.opacity(0.06)))
    }

    // MARK: 收藏

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("收藏").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("编辑") { showEditFavorites = true }
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.branchIndicator)
                    .buttonStyle(.plain)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(favorites) { f in
                    Button {
                        if let url = URL(string: f.url) { onPick(url) }
                    } label: {
                        VStack(spacing: 7) {
                            ZStack(alignment: .topTrailing) {
                                FaviconTile(url: f.url, name: f.name, size: 34)
                                    .frame(width: 60, height: 60)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.mainBg)
                                        .shadow(color: Theme.textPrimary.opacity(0.06), radius: 4, y: 2))
                                if BrowserIdentityStore.hasCookies(host: f.host, in: cookieDomains) {
                                    Circle()
                                        .fill(Theme.branchIndicator)
                                        .frame(width: 12, height: 12)
                                        .overlay(Circle().strokeBorder(Theme.sidebarBg, lineWidth: 2))
                                        .offset(x: 2, y: -2)
                                        .accessibilityLabel("已登录")
                                }
                            }
                            Text(f.name)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            favorites.removeAll { $0.id == f.id }
                            BrowserFavoritesStore.save(favorites, identity: identity.id)
                        } label: { Label("从收藏移除", systemImage: "trash") }
                    }
                }
                Button { showAddFavorite = true } label: {
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.textMuted.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: 60, height: 60)
                            .overlay(Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(Theme.textMuted))
                        Text("添加").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加收藏")
            }
        }
    }

    // MARK: 最近

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("清空") {
                    BrowsingHistoryStore.clear(identity: identity.id)
                    history = []
                }
                .font(.system(size: 15))
                .foregroundStyle(Theme.branchIndicator)
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                let recent = Array(history.prefix(10))
                ForEach(recent) { entry in
                    Button {
                        if let u = URL(string: entry.url) { onPick(u) }
                    } label: {
                        HStack(spacing: 12) {
                            FaviconTile(url: entry.url, name: entry.title, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title.isEmpty ? entry.url : entry.title)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(URL(string: entry.url)?.host() ?? entry.url)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(entry.date.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            BrowsingHistoryStore.remove(id: entry.id, identity: identity.id)
                            history.removeAll { $0.id == entry.id }
                        } label: { Label("删除这条", systemImage: "trash") }
                    }
                    if entry.id != recent.last?.id {
                        Divider().padding(.leading, 56).opacity(0.5)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.mainBg))
        }
    }
}

// MARK: - 网站图标（站点自己的 apple-touch-icon / favicon，拿不到画首字）

@MainActor
final class FaviconCache {
    static let shared = FaviconCache()
    private var memory: [String: Data] = [:]
    private var misses: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("browser-favicons", isDirectory: true)
    }

    func data(host: String) async -> Data? {
        if let d = memory[host] { return d }
        if misses.contains(host) { return nil }
        let file = directory.appendingPathComponent(host)
        if let d = try? Data(contentsOf: file) { memory[host] = d; return d }
        if let running = inFlight[host] { return await running.value }
        let task = Task<Data?, Never> { await Self.fetch(host: host) }
        inFlight[host] = task
        let d = await task.value
        inFlight[host] = nil
        if let d {
            memory[host] = d
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? d.write(to: file, options: .atomic)
        } else {
            misses.insert(host)
        }
        return d
    }

    private nonisolated static func fetch(host: String) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            guard let url = URL(string: "https://\(host)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.setValue(WebUserAgent.platformDefault, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 64, PlatformImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }
}

struct FaviconTile: View {
    let url: String
    let name: String
    var size: CGFloat

    @State private var image: PlatformImage?

    private var host: String {
        let h = URL(string: url)?.host() ?? ""
        return h.lowercased()
    }

    /// 首字：名字第一个字（英文大写），没有就用域名
    private var mark: String {
        let source = name.trimmingCharacters(in: .whitespaces).isEmpty ? host.replacingOccurrences(of: "www.", with: "") : name
        return source.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "·"
    }

    /// 首字底色：按域名挑一个固定的柔和色（不蓝不黄）
    private var tint: Color {
        let colors: [UInt] = [0x5E9E76, 0xC0703F, 0x7C68A8, 0xC9466E, 0x4F8C8C, 0x8C7F74, 0xB2457E]
        let sum = host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hex: colors[sum % colors.count])
    }

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable().interpolation(.high)
                #else
                Image(uiImage: image).resizable().interpolation(.high)
                #endif
            } else {
                Text(mark)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: size, height: size)
                    .background(tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .task(id: host) {
            guard !host.isEmpty, let d = await FaviconCache.shared.data(host: host) else { return }
            image = PlatformImage(data: d)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 编辑收藏

private struct FavoritesEditSheet: View {
    let identity: BrowserIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var favorites: [BrowserFavorite] = []
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(favorites) { f in
                        HStack(spacing: 12) {
                            FaviconTile(url: f.url, name: f.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                                Text(f.host).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                    .onDelete { favorites.remove(atOffsets: $0); save() }
                    .onMove { favorites.move(fromOffsets: $0, toOffset: $1); save() }
                } footer: {
                    Text("收藏每个身份各有一份，这里改的是「\(identity.name)」的。")
                }
                Section {
                    Button { showAdd = true } label: {
                        Label("添加网站", systemImage: "plus.circle.fill")
                            .foregroundStyle(Theme.branchIndicator)
                    }
                }
            }
            .navigationTitle("编辑收藏")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .task { favorites = BrowserFavoritesStore.load(identity: identity.id) }
        .sheet(isPresented: $showAdd) {
            AddFavoriteSheet(identityName: identity.name) { favorite in
                favorites.append(favorite)
                save()
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 480)
        #endif
    }

    private func save() { BrowserFavoritesStore.save(favorites, identity: identity.id) }
}

// MARK: - 添加网站（照 page1 加密卡 SecureAskSheet 的版式，粟粟 11-10 批注）

private struct AddFavoriteSheet: View {
    let identityName: String
    let onAdd: (BrowserFavorite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""

    private var url: URL? {
        guard AddressInput.kind(of: address) == .url else { return nil }
        return AddressInput.url(for: address)
    }

    var body: some View {
        BrowserFormSheet(symbol: "heart", title: "添加网站", subtitle: "加到「\(identityName)」的收藏",
                         saveTitle: "保存", canSave: url != nil, onSave: save, onCancel: { dismiss() }) {
            BrowserFormRow(label: "网址") {
                TextField("比如 bilibili.com", text: $address)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
            BrowserFormDivider()
            BrowserFormRow(label: "名字") {
                TextField("不填用网址", text: $name)
            }
        }
    }

    private func save() {
        guard let url else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let host = (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
        onAdd(BrowserFavorite(id: UUID(), url: url.absoluteString, name: trimmed.isEmpty ? host : trimmed))
        dismiss()
    }
}

// MARK: - 浏览器设置（身份管理 + 底栏 / 链接打开方式）

struct BrowserSettingsSheet: View {
    @Binding var current: BrowserIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var identities: [BrowserIdentity] = []
    @State private var editing: BrowserIdentity?
    @State private var creating: BrowserIdentity?
    #if os(iOS)
    @AppStorage(GardenBrowserSettings.layoutKey) private var layout: GardenBrowserToolbarLayout = .compact
    @AppStorage(GardenBrowserSettings.linkOpenModeKey) private var linkOpenMode: GardenLinkOpenMode = .inApp
    @AppStorage(AIOperatorOverlay.cursorColorKey) private var cursorHex = ""
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(identities) { identity in
                        Button { editing = identity } label: {
                            HStack(spacing: 12) {
                                Circle().fill(identity.color).frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(identity.name).foregroundStyle(Theme.textPrimary)
                                    Text(detail(identity)).font(.caption).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                if identity.id == current.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.branchIndicator)
                                }
                            }
                        }
                        .disabled(identity.isMain)
                    }
                    Button {
                        let n = identities.count
                        creating = BrowserIdentity(id: UUID(), name: "身份 \(n + 1)",
                                                   colorHex: BrowserIdentityStore.palette[(n - 1) % BrowserIdentityStore.palette.count],
                                                   desktopUA: false)
                    } label: {
                        Label("新身份", systemImage: "plus").foregroundStyle(Theme.branchIndicator)
                    }
                } header: {
                    Text("身份")
                } footer: {
                    Text("每个身份的登录、网站数据各存一份，同一个网站可以登不同的号。「主号」就是原来那份。AI 读网页、链接直读、在浏览器里动手都用当前身份。")
                }
                #if os(iOS)
                Section("浏览器") {
                    Picker("底栏布局", selection: $layout) {
                        ForEach(GardenBrowserToolbarLayout.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("链接打开方式", selection: $linkOpenMode) {
                        ForEach(GardenLinkOpenMode.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    cursorColorRow
                } header: {
                    Text("AI 操作时")
                } footer: {
                    Text("AI 在浏览器里动手时那个箭头的颜色；「主题」跟着当前主题的强调色走。")
                }
                #endif
            }
            .navigationTitle("浏览器设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .task { identities = BrowserIdentityStore.load() }
        .sheet(item: $editing, onDismiss: refresh) { identity in
            BrowserIdentityEditSheet(draft: identity, isNew: false) { saved in
                if saved.id == current.id { current = saved }
            } onDelete: {
                if identity.id == current.id { current = .main }
            }
        }
        .sheet(item: $creating, onDismiss: refresh) { draft in
            BrowserIdentityEditSheet(draft: draft, isNew: true) { _ in }
        }
        #if os(macOS)
        .frame(width: 440, height: 480)
        #endif
    }

    private func refresh() { identities = BrowserIdentityStore.load() }

    #if os(iOS)
    /// AI 箭头颜色：主题（空串）+ 四个预设 + 自选（粟粟 11-11「可自选，用现强调色」）
    private var cursorColorRow: some View {
        let presets = ["", "#F28DAA", "#8EBD9F", "#B79BE0", "#F0A274"]
        return HStack(spacing: 12) {
            Text("箭头颜色")
            Spacer()
            ForEach(presets, id: \.self) { hex in
                let c = AIOperatorOverlay.cursorColor(hex)
                Button { cursorHex = hex } label: {
                    Circle().fill(c).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: cursorHex == hex ? 3 : 0))
                        .overlay(Circle().strokeBorder(c, lineWidth: cursorHex == hex ? 1.5 : 0).padding(-2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hex.isEmpty ? "主题强调色" : "这个颜色")
            }
            ColorPicker("自选", selection: Binding(
                get: { AIOperatorOverlay.cursorColor(cursorHex) },
                set: { cursorHex = Self.hex($0) }), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    #endif

    private func detail(_ identity: BrowserIdentity) -> String {
        if identity.isMain { return "原来的登录" }
        return identity.desktopUA ? "桌面版网页" : "手机版网页"
    }
}

// MARK: - 新建 / 编辑身份

struct BrowserIdentityEditSheet: View {
    @State var draft: BrowserIdentity
    let isNew: Bool
    var onSave: (BrowserIdentity) -> Void
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        BrowserFormSheet(symbol: "person.crop.circle", title: isNew ? "新身份" : "编辑身份",
                         subtitle: isNew ? "一份新的登录，网站要重新登" : "改名字、颜色和网页版本",
                         saveTitle: isNew ? "创建" : "保存", canSave: canSave, onSave: save, onCancel: { dismiss() }) {
            BrowserFormRow(label: "名字") { TextField("比如 小号", text: $draft.name) }
            BrowserFormDivider()
            BrowserFormRow(label: "颜色") {
                HStack(spacing: 10) {
                    ForEach(BrowserIdentityStore.palette, id: \.self) { hex in
                        let c = Color(hex: UInt(hex.dropFirst(), radix: 16) ?? 0)
                        Button { draft.colorHex = hex } label: {
                            Circle().fill(c).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: draft.colorHex == hex ? 3 : 0))
                                .overlay(Circle().strokeBorder(c, lineWidth: draft.colorHex == hex ? 1.5 : 0).padding(-2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(draft.colorHex == hex ? "已选这个颜色" : "选这个颜色")
                    }
                }
            }
            BrowserFormDivider()
            Toggle("用桌面版网页", isOn: $draft.desktopUA)
                .tint(Theme.branchIndicator)
                .font(.subheadline)
                .padding(.vertical, 12)
        } footer: {
            if !isNew {
                Button("删除这个身份", role: .destructive) { confirmDelete = true }
                    .font(.subheadline)
                    .padding(.top, 6)
            }
        }
        .confirmationDialog("删除「\(draft.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                BrowserIdentityStore.delete(draft)
                let id = draft.id
                Task { await BrowserIdentityStore.removeDataStore(id) }
                onDelete()
                dismiss()
            }
        } message: {
            Text("这个身份登的号都会退出，它的历史和收藏也一起删掉。")
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if isNew {
            let created = BrowserIdentityStore.add(name: draft.name, colorHex: draft.colorHex, desktopUA: draft.desktopUA)
            onSave(created)
        } else {
            BrowserIdentityStore.update(draft)
            onSave(draft)
        }
        dismiss()
    }
}

// MARK: - 半屏表单（照 SecureAskSheet：白底小图标 / 标题 / 小字 / 白底细边字段组 / 薄荷按钮 + 取消）

struct BrowserFormSheet<Fields: View, Footer: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let saveTitle: String
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let fields: () -> Fields
    @ViewBuilder var footer: () -> Footer
    #if os(iOS)
    @State private var detent: PresentationDetent = .medium
    #endif

    init(symbol: String, title: String, subtitle: String, saveTitle: String, canSave: Bool,
         onSave: @escaping () -> Void, onCancel: @escaping () -> Void,
         @ViewBuilder fields: @escaping () -> Fields, @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.saveTitle = saveTitle
        self.canSave = canSave
        self.onSave = onSave
        self.onCancel = onCancel
        self.fields = fields
        self.footer = footer
    }

    private var groupShape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(Color.primary)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white)
                        .shadow(color: Theme.cardShadow, radius: Theme.cardShadowRadius, y: 1))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.top, 10)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(CodeBlockStyle.label)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
                VStack(alignment: .leading, spacing: 0) { fields() }
                    .padding(.horizontal, 14)
                    .background(groupShape.fill(Color.white))
                    .overlay(groupShape.strokeBorder(CodeBlockStyle.stroke, lineWidth: 1))
                Button(action: onSave) {
                    Text(saveTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.branchIndicator.opacity(canSave ? 1 : 0.45)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .padding(.top, 18)
                Button(action: onCancel) {
                    Text("取消")
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                footer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 28)
            .padding(.bottom, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(CodeBlockStyle.body)
        .environment(\.colorScheme, .light)
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in detent = .large }
        .presentationDragIndicator(.visible)
        .presentationBackground(CodeBlockStyle.body)
        #else
        .frame(width: 420)
        .frame(minHeight: 420)
        #endif
    }
}

struct BrowserFormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(CodeBlockStyle.label)
                .frame(width: 40, alignment: .leading)
            content()
                .font(.system(size: 16))
                .textFieldStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 50)
    }
}

struct BrowserFormDivider: View {
    var body: some View { SecureAskDashedRule() }
}
