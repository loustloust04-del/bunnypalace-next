#if os(iOS)
import SwiftUI
import PhotosUI

/// 设置 → 书房（= 书房右上 ⚙ 弹的 sheet）的书房 / 书摘两段（plan-reading-study-3 §3）。
/// AI 读书模型那段在 ReadingSettingsTab 里。
struct StudySettingsSections: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @AppStorage("study.layout") private var layoutRaw = StudyLayout.study.rawValue
    @AppStorage("study.noteStyle") private var noteStyleRaw = StudyNoteStyle.clip.rawValue
    @AppStorage("quotes.style") private var quoteStyleRaw = QuoteStyle.exhibit.rawValue
    @AppStorage("quotes.artSource") private var artSourceRaw = QuoteArtSource.garden.rawValue
    @State private var myImages: [URL] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importing = false
    @AppStorage(HighlightPalette.customKey) private var customColorsRaw = ""

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        Section {
            Picker("布局", selection: $layoutRaw) {
                ForEach(StudyLayout.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .searchAnchor("leaf-study-layout")
            Picker("书摘便签", selection: $noteStyleRaw) {
                ForEach(StudyNoteStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(layoutRaw != StudyLayout.study.rawValue)
        } header: {
            Text("书房")
        } footer: {
            Text(layoutRaw == StudyLayout.study.rawValue
                 ? "书房：木板书架上的 3D 书，墙上挂书摘便签。"
                 : "书格 / 书单不挂便签，书摘入口在标题旁。")
        }
        .listRowBackground(Theme.mainBg)

        Section {
            HStack(spacing: 12) {
                ForEach(QuoteStyle.allCases, id: \.rawValue) { style in
                    Button { quoteStyleRaw = style.rawValue } label: {
                        VStack(spacing: 6) {
                            QuoteStyleThumb(style: style)
                                .frame(height: 96)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(quoteStyleRaw == style.rawValue ? Theme.branchIndicator : .clear, lineWidth: 2))
                            Text(style.title)
                                .font(.system(size: 12, weight: quoteStyleRaw == style.rawValue ? .semibold : .regular))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .searchAnchor("leaf-study-quote-style")
            Picker("底图", selection: $artSourceRaw) {
                ForEach(QuoteArtSource.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .searchAnchor("leaf-study-quote-art")
        } header: {
            Text("书摘")
        } footer: {
            Text("底图每次进书摘都会换一换；名画都是公版作品。")
        }
        .listRowBackground(Theme.mainBg)

        Section {
            // 色板挪到了「外观 › 划线颜色」（聊天等处也用它），这里留个入口
            NavigationLink {
                HighlightColorsPage()
            } label: {
                HStack {
                    Text("划线颜色")
                    Spacer()
                    HStack(spacing: -4) {
                        ForEach(HighlightPalette.all(customRaw: customColorsRaw).prefix(5), id: \.self) { hex in
                            Circle().fill(HighlightPalette.color(hex)).frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(Theme.mainBg, lineWidth: 1.5))
                        }
                    }
                }
            }
        }
        .listRowBackground(Theme.mainBg)

        Section {
            if !myImages.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(myImages, id: \.self) { url in
                        Group {
                            if let img = MyQuoteImages.image(at: url) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Theme.accent
                            }
                        }
                        .frame(height: 70)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                MyQuoteImages.remove(url)
                                myImages = MyQuoteImages.list(profileId: profileId)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                Label(importing ? "导入中…" : "从照片导入", systemImage: "photo.badge.plus")
            }
            .disabled(importing)
            .searchAnchor("leaf-study-my-images")
        } header: {
            Text("我的图片")
        } footer: {
            Text("导入的图放在文件库的「书摘底图」里，跟着 iCloud 同步到别的设备。长按一张可以删。底图选「我的图片」或「全部混着来」时会用到。")
        }
        .listRowBackground(Theme.mainBg)
        .onAppear { myImages = MyQuoteImages.list(profileId: profileId) }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        try? MyQuoteImages.add(img, profileId: profileId)
                    }
                }
                myImages = MyQuoteImages.list(profileId: profileId)
                pickerItems = []
                importing = false
            }
        }
    }
}

/// 三种书摘样式的小缩略图（设置里点选用）
private struct QuoteStyleThumb: View {
    let style: QuoteStyle

    var body: some View {
        ZStack {
            switch style {
            case .exhibit:
                QuoteArt(variant: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Color(hex: 0x6B6258)).frame(width: 22, height: 2)
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color(hex: 0xC9C0B3)).frame(height: 2) }
                }
                .padding(6)
                .background(Color(hex: 0xFBF9F4))
                .frame(width: 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(6)
            case .page:
                Color(hex: 0xE9E3D8)
                VStack(spacing: 4) {
                    QuoteArt(variant: 3).frame(height: 30).clipped().padding(2).background(.white)
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(Color(hex: 0x8EBD9F, alpha: 0.5)).frame(height: 3) }
                }
                .padding(7)
                .background(Color(hex: 0xFCF8F0))
                .padding(8)
            case .bookmark:
                StudyPaper.wall
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { k in
                        VStack(spacing: 0) {
                            QuoteArt(variant: k + 1).frame(height: 26).clipped()
                            Color(hex: 0xFBF7EE)
                        }
                        .frame(width: k == 1 ? 18 : 13, height: k == 1 ? 74 : 64)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
#endif
