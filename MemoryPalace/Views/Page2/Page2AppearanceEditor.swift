#if os(iOS)
import SwiftUI
import PhotosUI

struct Page2WallpaperEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = Page2AppearanceStore.shared
    @State private var draft = Page2AppearanceStore.shared.value
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var fileImportTask: Task<Void, Never>?
    @State private var busy = false
    @State private var importedFiles: [String] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack {
                        Page2WallpaperView(appearance: draft)
                        VStack(spacing: 16) {
                            Text("自己的主屏").font(.title3.weight(.semibold))
                            HStack(spacing: 20) {
                                ForEach(RightPanelToolManager.builtInTools.prefix(4)) { tool in
                                    AppIconView(name: tool.icon, size: 24, tint: Page2VisualStyle.sage)
                                        .frame(width: 44, height: 44).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                                }
                            }
                        }
                    }.frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 24))
                    .listRowInsets(EdgeInsets())
                }
                Section("壁纸") {
                    Picker("背景", selection: $draft.wallpaper) {
                        #if PERSONAL_APPS
                        Text("iOS 26 原生").tag("ios26")
                        #endif
                        Text("花园四季").tag("garden")
                        Text("雾白花园").tag("mist")
                        Text("暮色玻璃").tag("dusk")
                        Text("手绘花园").tag("flora")
                        if draft.imageFile != nil { Text("我的照片").tag("photo") }
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label("从相册选择", systemImage: "photo") }
                    Button("从文件选择", systemImage: "folder") { importing = true }
                    if ["photo", "flora"].contains(draft.wallpaper) {
                        VStack(alignment: .leading) { Text("左右位置"); Slider(value: $draft.offsetX, in: -1...1) }
                        VStack(alignment: .leading) { Text("上下位置"); Slider(value: $draft.offsetY, in: -1...1) }
                        VStack(alignment: .leading) { Text("明亮遮罩"); Slider(value: $draft.dimming, in: 0...0.85) }
                    }
                    Button("恢复默认壁纸") {
                        #if PERSONAL_APPS
                        draft.wallpaper = "ios26"
                        #else
                        draft.wallpaper = "garden"
                        #endif
                        draft.imageFile = nil; draft.dimming = 0.15; draft.offsetX = 0; draft.offsetY = 0
                    }
                }
                Section("图标与小组件") {
                    Picker("外观", selection: $draft.rendering) {
                        Text("默认").tag("default")
                        Text("透明").tag("clear")
                        Text("着色").tag("tinted")
                    }.pickerStyle(.segmented)
                    Picker("明暗", selection: $draft.luminosity) {
                        Text("浅色").tag("light"); Text("深色").tag("dark"); Text("自动").tag("auto")
                    }.pickerStyle(.segmented)
                    Toggle("大图标", isOn: $draft.largeIcons)
                }
                if busy { ProgressView("正在处理图片…") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("主屏外观").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { if store.save(draft) { dismiss() } else { error = store.errorMessage } }.disabled(busy) }
            }
            .onDisappear { fileImportTask?.cancel(); store.discardImportedAssets(importedFiles) }
            .task(id: photo) {
                guard let photo else { return }
                await loadPhoto(photo)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                fileImportTask?.cancel()
                fileImportTask = Task {
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        await importData(try Data(contentsOf: url))
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
    private func loadPhoto(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                try Task.checkCancellation()
                await importData(data)
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func importData(_ data: Data) async {
        busy = true
        defer { busy = false }
        do { draft.imageFile = try await store.importImage(data, isIcon: false); if let name = draft.imageFile { importedFiles.append(name) }; draft.wallpaper = "photo"; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct Page2IconEditor: View {
    let tool: RightPanelTool
    @Environment(\.dismiss) private var dismiss
    @State private var store = Page2AppearanceStore.shared
    @FocusState private var editingSymbol: Bool
    @State private var symbol = ""
    @State private var tint = "sage"
    @State private var imageFile: String?
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var importedFiles: [String] = []
    @State private var error: String?
    private let symbols = ["leaf", "sparkles", "heart", "book.closed", "calendar", "brain", "bubble.left", "lightbulb", "folder", "star", "moon", "leaf.circle", "pawprint", "headphones", "terminal", "globe"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 28) { iconPreview(60); iconPreview(44) }
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                } footer: { Text("主屏和 Dock 会一起更新。") }
                Section("图标") {
                    PhotosPicker(selection: $photo, matching: .images) { Label("用自己的图片", systemImage: "photo") }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 16) {
                        ForEach(symbols, id: \.self) { name in
                            Button { symbol = name; imageFile = nil } label: {
                                Image(systemName: name).font(.title3).frame(width: 40, height: 44)
                                    .background(symbol == name && imageFile == nil ? Page2VisualStyle.sage.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel(name)
                        }
                    }
                    TextField("SF Symbol 名称", text: $symbol).focused($editingSymbol).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: symbol) { _, _ in if editingSymbol { imageFile = nil } }
                    Picker("颜色", selection: $tint) {
                        Text("灰绿").tag("sage"); Text("灰玫瑰").tag("rose"); Text("灰紫").tag("plum"); Text("墨色").tag("graphite")
                    }
                    Button("恢复此图标默认值") {
                        var value = store.value
                        value.icons[tool.id] = nil
                        if store.save(value) { dismiss() }
                    }
                }
                if busy { ProgressView("正在处理图片…") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("\(tool.name)图标").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(busy) }
            }
            .onAppear {
                let override = store.value.icons[tool.id]
                symbol = override?.symbol ?? tool.icon
                tint = override?.tint ?? "sage"
                imageFile = override?.imageFile
            }
            .onDisappear { store.discardImportedAssets(importedFiles) }
            .task(id: photo) {
                guard let photo else { return }
                busy = true
                defer { busy = false }
                do {
                    if let data = try await photo.loadTransferable(type: Data.self) {
                        try Task.checkCancellation()
                        let name = try await store.importImage(data, isIcon: true)
                        importedFiles.append(name)
                        imageFile = name
                    }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
    @ViewBuilder private func iconPreview(_ side: CGFloat) -> some View {
        Group {
            if let url = store.assetURL(imageFile), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let local = localDefaultIcon {
                local.resizable().scaledToFill()
            } else { AppIconView(name: symbol.isEmpty ? tool.icon : symbol, size: side * 0.43, tint: Page2VisualStyle.tint(tint)) }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.27))
            .glassEffect(.regular, in: .rect(cornerRadius: side * 0.27))
    }
    /// 没选图、符号还是工具默认的那个 = 停在默认值上：有本地默认图就预览它，保存时也当「恢复默认」
    private var localDefaultIcon: Image? {
        #if DEBUG
        imageFile == nil && (symbol.isEmpty || symbol == tool.icon) ? LocalDefaultIcon.image(for: tool.id) : nil
        #else
        nil
        #endif
    }
    private func save() {
        #if DEBUG
        if localDefaultIcon != nil {
            var value = store.value
            value.icons[tool.id] = nil
            if store.save(value) { dismiss() } else { error = store.errorMessage }
            return
        }
        #endif
        if imageFile == nil && !AppIconView.isAssetName(symbol) && UIImage(systemName: symbol) == nil {
            error = "没有找到这个图标名称，请换一个。"
            return
        }
        var value = store.value
        value.icons[tool.id] = Page2IconOverride(symbol: symbol, imageFile: imageFile, tint: tint)
        if store.save(value) { dismiss() } else { error = store.errorMessage }
    }
}
struct Page2AppearanceEditor: View {
    @State private var store = Page2AppearanceStore.shared
    @State private var draft = Page2AppearanceStore.shared.value
    private let modes = [("默认", "default"), ("深色", "dark"), ("透明", "clear"), ("着色", "tinted")]

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button { draft.dimming = draft.dimming < 0.3 ? 0.5 : 0.1 } label: { Image(systemName: "sun.max").frame(width: 44, height: 44) }
                Spacer()
                Text("自定").font(.headline)
                Spacer()
                Button { draft.largeIcons.toggle() } label: {
                    Image(systemName: draft.largeIcons ? "square.fill" : "square.grid.2x2.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(draft.largeIcons ? "使用小图标" : "使用大图标")
            }
            HStack(spacing: 0) {
                ForEach(modes, id: \.1) { name, mode in
                    Button {
                        draft.rendering = mode
                        if mode == "dark" { draft.luminosity = "dark" }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .font(.system(size: 30, weight: .light))
                                .frame(width: 60, height: 60)
                                .background(mode == "dark" || mode == "tinted" ? Color.black.opacity(0.55) : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 15))
                                .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(mode == "clear" ? 0.6 : 0.15), lineWidth: 0.7))
                            Text(name).font(.subheadline.weight(draft.rendering == mode ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(draft.rendering == mode ? Color.white.opacity(0.16) : .clear, in: Capsule())
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                }
            }
            if draft.rendering == "tinted" {
                VStack(spacing: 8) {
                    Slider(value: $draft.tintHue, in: 0...1).accessibilityLabel("颜色")
                    Slider(value: $draft.tintSaturation, in: 0...1).accessibilityLabel("饱和度")
                }.tint(Color(hue: draft.tintHue, saturation: draft.tintSaturation, brightness: 0.8))
            }
            Picker("明暗", selection: $draft.luminosity) {
                Text("浅色").tag("light"); Text("深色").tag("dark"); Text("自动").tag("auto")
            }.pickerStyle(.segmented).frame(maxWidth: 240)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 28)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).stroke(.white.opacity(0.2), lineWidth: 0.7))
        .padding(.horizontal, 8)
        .onChange(of: draft) { _, value in store.preview(value) }
        .onDisappear { if !store.save(draft) { store.cancelPreview() } }
    }
}
#endif
