import SwiftUI

/// 一条第三方组件的许可信息。
/// `textFileName` 指向包内资源 `<name>.<textFileExtension>`（一般是 `Resources/Licenses/<name>.txt`）；nil 表示本仓库没有该组件的许可证全文副本。
/// `platform` 标这个组件进哪个包：致谢页只列本平台包里真有的（两端共用这一份数据）。
struct LicenseEntry: Identifiable {
    enum Platform { case both, iOS, mac }

    let id = UUID()
    let name: String
    let licenseType: String
    let copyright: String?
    let repositoryURL: String?
    let textFileName: String?
    var textFileExtension = "txt"
    var platform: Platform = .both
}

/// 折叠行：收起只显示组件名 + 许可类型，展开才读全文。
struct LicenseRow: View {
    let entry: LicenseEntry

    @State private var isExpanded = false
    @State private var licenseText: String?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let copyright = entry.copyright {
                    Text(copyright)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                }

                if let urlString = entry.repositoryURL, let url = URL(string: urlString) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text(urlString.replacingOccurrences(of: "https://", with: ""))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.branchIndicator)
                    }
                }

                if let licenseText {
                    Text(licenseText)
                        .font(.system(size: Theme.SettingsFont.caption, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.mainBg.opacity(0.6))
                        )
                } else if entry.textFileName == nil {
                    Text("许可证全文见上方仓库链接。")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Text(entry.name)
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(entry.licenseType)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .tint(Theme.textMuted)
        .task(id: isExpanded) {
            guard isExpanded, licenseText == nil, let file = entry.textFileName else { return }
            licenseText = Acknowledgements.loadText(file, extension: entry.textFileExtension)
        }
    }
}

struct LicenseSection: Identifiable {
    let id = UUID()
    let title: String
    let entries: [LicenseEntry]
}

/// 开源致谢数据，iOS（`IOSAcknowledgementsPage`）和 mac（`MacAcknowledgementsPage`）共用。
enum Acknowledgements {
    static let intro = "记忆花园以 AGPL-3.0 发布，并使用了下列开源组件。版权声明与许可证全文均照录自各组件自带的许可文件。"

    /// 本平台包里真有的条目；滤空的节不出现。
    /// 必须 `static let` 只算一次：`LicenseSection.id` 是 `UUID()`，每次重建会换身份，页面重绘时整节被当新视图、展开状态丢掉。
    static let current: [LicenseSection] = {
        #if os(iOS)
        let excluded = LicenseEntry.Platform.mac
        #else
        let excluded = LicenseEntry.Platform.iOS
        #endif
        return sections.compactMap { section in
            let entries = section.entries.filter { $0.platform != excluded }
            return entries.isEmpty ? nil : LicenseSection(title: section.title, entries: entries)
        }
    }()

    static func loadText(_ fileName: String, extension ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 数据

    private static let sections: [LicenseSection] = [
        LicenseSection(title: "本应用", entries: [
            LicenseEntry(
                name: "记忆花园 · Mneme Atrium",
                licenseType: "AGPL-3.0",
                copyright: nil,
                repositoryURL: "https://github.com/replica882/mneme-atrium",
                textFileName: "agpl-3.0"
            ),
        ]),

        LicenseSection(title: "本机语音运行库", entries: [
            LicenseEntry(name: "sherpa-onnx", licenseType: "Apache-2.0",
                         copyright: "Copyright (c) 2023 Xiaomi Corporation",
                         repositoryURL: "https://github.com/k2-fsa/sherpa-onnx", textFileName: "sherpa-onnx"),
            LicenseEntry(name: "ONNX Runtime", licenseType: "MIT",
                         copyright: "Copyright (c) Microsoft Corporation",
                         repositoryURL: "https://github.com/microsoft/onnxruntime", textFileName: "onnxruntime"),
            LicenseEntry(name: "└ ONNX Runtime 第三方声明", licenseType: "多种许可",
                         copyright: nil, repositoryURL: "https://github.com/microsoft/onnxruntime/blob/v1.28.2/ThirdPartyNotices.txt",
                         textFileName: "onnxruntime-notices"),
        ]),

        LicenseSection(title: "渲染与解析", entries: [
            LicenseEntry(
                name: "swift-cmark",
                licenseType: "BSD-2-Clause",
                copyright: "Copyright (c) 2014, John MacFarlane；另含 Vicent Martí、Karl Dubost 等多项声明，见全文",
                repositoryURL: "https://github.com/swiftlang/swift-cmark",
                textFileName: "swift-cmark"
            ),
            LicenseEntry(
                name: "swift-markdown",
                licenseType: "Apache-2.0",
                copyright: "Copyright (c) 2021 Apple Inc. and the Swift project authors",
                repositoryURL: "https://github.com/swiftlang/swift-markdown",
                textFileName: "swift-markdown"
            ),
            LicenseEntry(
                name: "└ swift-markdown NOTICE",
                licenseType: "全文",
                copyright: nil,
                repositoryURL: nil,
                textFileName: "swift-markdown-notice"
            ),
            LicenseEntry(
                name: "SwiftStreamingMarkdown",
                licenseType: "MIT",
                copyright: "Copyright (c) Microsoft Corporation.",
                repositoryURL: "https://github.com/microsoft/SwiftStreamingMarkdown",
                textFileName: "swiftstreamingmarkdown"
            ),
            LicenseEntry(
                name: "Mermaid",
                licenseType: "MIT",
                copyright: "Copyright (c) 2014 - 2022 Knut Sveidqvist",
                repositoryURL: "https://github.com/mermaid-js/mermaid",
                textFileName: "mermaid"
            ),
            LicenseEntry(
                name: "HighlightSwift",
                licenseType: "MIT",
                copyright: "Copyright (c) 2023 Stefan Britton",
                repositoryURL: "https://github.com/appstefan/highlightswift",
                textFileName: "highlightswift"
            ),
            LicenseEntry(
                name: "└ highlight.js 11.9.0",
                licenseType: "BSD-3-Clause",
                copyright: "Copyright (c) 2006, Ivan Sagalaev.",
                repositoryURL: "https://github.com/highlightjs/highlight.js",
                textFileName: "highlightjs"
            ),
            LicenseEntry(
                name: "iosMath",
                licenseType: "MIT",
                copyright: "Copyright (c) 2013 MathChat",
                repositoryURL: "https://github.com/maitbayev/iosMath",
                textFileName: "iosmath"
            ),
            LicenseEntry(
                name: "└ Latin Modern Math 字体",
                licenseType: "GUST Font License",
                copyright: "Copyright 2012--2014 for the Latin Modern math extensions by B. Jackowski, P. Strzelczyk and P. Pianowski (on behalf of TeX Users Groups).",
                repositoryURL: nil,
                textFileName: "gust-font-license"
            ),
            LicenseEntry(
                name: "└ TeX Gyre Termes Math 字体",
                licenseType: "GUST Font License",
                copyright: "Copyright 2012--2014 for the TeX Gyre math extensions by B. Jackowski, P. Strzelczyk and P. Pianowski (on behalf of TeX Users Groups).",
                repositoryURL: nil,
                textFileName: "gust-font-license"
            ),
            LicenseEntry(
                name: "└ XITS Math 字体",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2001-2010 by the STI Pub Companies（STIX Fonts）；Portions copyright (c) 1998-2003 by MicroPress, Inc.；Portions copyright (c) 1990 by Elsevier, Inc.；Portions copyright (c) 2009-2012 by Khaled Hosny，见全文",
                repositoryURL: nil,
                textFileName: "font-xits-math"
            ),
            LicenseEntry(
                name: "equatable",
                licenseType: "Apache-2.0",
                copyright: "许可文件为 Apache-2.0 标准模板，未标注版权持有人",
                repositoryURL: "https://github.com/ordo-one/equatable",
                textFileName: "apache-2.0"
            ),
            LicenseEntry(
                name: "SwiftSoup",
                licenseType: "MIT",
                copyright: "Copyright (c) 2009-2025 Jonathan Hedley；Copyright (c) 2016-2025 Nabil Chatbi（Swift port）",
                repositoryURL: "https://github.com/scinfu/SwiftSoup",
                textFileName: "swiftsoup"
            ),
        ]),

        LicenseSection(title: "字体", entries: [
            LicenseEntry(
                name: "霞鹜文楷 LXGW WenKai",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright 2021-2026 LXGW；Copyright 2020 The Klee Project Authors",
                repositoryURL: "https://github.com/lxgw/LxgwWenKai",
                textFileName: "font-lxgwwenkai"
            ),
            LicenseEntry(
                name: "思源宋体 Source Han Serif",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright 2017-2022 Adobe，保留字体名 “Source”",
                repositoryURL: "https://github.com/adobe-fonts/source-han-serif",
                textFileName: "font-sourcehanserif"
            ),
            LicenseEntry(
                name: "龙藏体 Long Cang",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright 2018 The Long Cang Project Authors",
                repositoryURL: "https://github.com/googlefonts/longcang",
                textFileName: "font-longcang"
            ),
            LicenseEntry(
                name: "站酷快乐体 ZCOOL KuaiLe",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright 2018 The ZCOOL KuaiLe Project Authors",
                repositoryURL: "https://github.com/googlefonts/zcool-kuaile",
                textFileName: "font-zcoolkuaile"
            ),
            LicenseEntry(
                name: "Silkscreen",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright 2001 The Silkscreen Project Authors",
                repositoryURL: "https://github.com/googlefonts/silkscreen",
                textFileName: "font-silkscreen"
            ),
            LicenseEntry(
                name: "IM FELL English / English SC / DW Pica",
                licenseType: "SIL OFL 1.1",
                copyright: "Copyright (c) 2010, Igino Marini (mail@iginomarini.com)",
                repositoryURL: "https://github.com/google/fonts/tree/main/ofl/imfellenglish",
                textFileName: "IMFell-LICENSE"
            ),
        ]),

        LicenseSection(title: "终端", entries: [
            LicenseEntry(
                name: "SwiftTerm",
                licenseType: "MIT",
                copyright: "Copyright (c) 2019-2022 Miguel de Icaza；含 xterm.js authors、SourceLair、Christopher Jeffrey 的声明，见全文",
                repositoryURL: "https://github.com/migueldeicaza/SwiftTerm",
                textFileName: "swiftterm"
            ),
            LicenseEntry(
                name: "rootshell",
                licenseType: "MIT",
                copyright: "Copyright (c) 2026 Rootshell LLC, Kit Knox；终端键盘工具条与设置搜索的部分代码改编自 rootshell",
                repositoryURL: "https://github.com/kitknox/rootshell",
                textFileName: "rootshell"
            ),
        ]),

        LicenseSection(title: "离线沙箱", entries: [
            LicenseEntry(
                name: "iSH（ARM64 fork）",
                licenseType: "GPL-3.0",
                copyright: "iSH 的许可说明；本应用未修改 iSH 本身，源码见上游公开仓库",
                repositoryURL: "https://github.com/OpenMinis/ish-arm64",
                textFileName: "ish",
                platform: .iOS
            ),
            LicenseEntry(
                name: "└ GNU 通用公共许可证 第 3 版",
                licenseType: "全文",
                copyright: nil,
                repositoryURL: nil,
                textFileName: "gpl-3.0",
                platform: .iOS
            ),
            LicenseEntry(
                name: "└ iSH App Store 分发附加条款",
                licenseType: "全文",
                copyright: nil,
                repositoryURL: nil,
                textFileName: "ish-ios",
                platform: .iOS
            ),
            LicenseEntry(
                name: "OpenMinis（离线沙箱胶水代码）",
                licenseType: "GPL-3.0",
                copyright: "沙箱的 iSH 胶水代码与 rootfs 生成脚本改编自 OpenMinis，按 GPL-3.0 分发；许可全文同上",
                repositoryURL: "https://github.com/OpenMinis/OpenMinis",
                textFileName: "gpl-3.0",
                platform: .iOS
            ),
            LicenseEntry(
                name: "Alpine Linux minirootfs 3.21.0",
                licenseType: "聚合许可",
                copyright: "由 15 个软件包各自的许可证聚合而成（BusyBox、apk-tools 等 GPL-2.0，musl MIT，OpenSSL Apache-2.0 等）；包清单、源码获取方式与 GPL-2.0 书面承诺见全文",
                repositoryURL: "https://alpinelinux.org",
                textFileName: "alpine-rootfs",
                platform: .iOS
            ),
            LicenseEntry(
                name: "└ GNU 通用公共许可证 第 2 版",
                licenseType: "全文",
                copyright: nil,
                repositoryURL: nil,
                textFileName: "gpl-2.0",
                platform: .iOS
            ),
        ]),

        LicenseSection(title: "本地模型", entries: [
            LicenseEntry(
                name: "mlx-swift",
                licenseType: "MIT",
                copyright: "Copyright (c) 2023 ml-explore；内含 mlx（Copyright © 2023 Apple Inc.）、mlx-c、fmt、nlohmann json、PocketFFT 的声明，见全文",
                repositoryURL: "https://github.com/ml-explore/mlx-swift",
                textFileName: "mlx-swift"
            ),
            LicenseEntry(
                name: "└ metal-cpp",
                licenseType: "Apache-2.0",
                copyright: "Copyright © 2024 Apple Inc.",
                repositoryURL: "https://developer.apple.com/metal/cpp/",
                textFileName: "apache-2.0"
            ),
            LicenseEntry(
                name: "mlx-swift-lm",
                licenseType: "MIT",
                copyright: "Copyright (c) 2024 ml-explore",
                repositoryURL: "https://github.com/ml-explore/mlx-swift-lm",
                textFileName: "mlx-swift"
            ),
            LicenseEntry(
                name: "swift-transformers",
                licenseType: "Apache-2.0",
                copyright: "Copyright 2022 Hugging Face SAS.",
                repositoryURL: "https://github.com/huggingface/swift-transformers",
                textFileName: "apache-2.0"
            ),
            LicenseEntry(
                name: "swift-jinja",
                licenseType: "Apache-2.0",
                copyright: "Copyright 2022 Hugging Face SAS.",
                repositoryURL: "https://github.com/huggingface/swift-jinja",
                textFileName: "apache-2.0"
            ),
            LicenseEntry(
                name: "swift-huggingface",
                licenseType: "Apache-2.0",
                copyright: "Copyright 2025 Hugging Face SAS.",
                repositoryURL: "https://github.com/huggingface/swift-huggingface",
                textFileName: "apache-2.0"
            ),
            LicenseEntry(
                name: "swift-crypto",
                licenseType: "Apache-2.0",
                copyright: "Copyright 2019 The SwiftCrypto Project；Copyright (c) 2019-2020 Apple Inc. and the SwiftCrypto project authors",
                repositoryURL: "https://github.com/apple/swift-crypto",
                textFileName: "apache-2.0"
            ),
            LicenseEntry(
                name: "└ swift-crypto NOTICE",
                licenseType: "全文",
                copyright: nil,
                repositoryURL: nil,
                textFileName: "swift-crypto-notice"
            ),
            LicenseEntry(
                name: "swift-collections",
                licenseType: "Apache-2.0",
                copyright: "Copyright (c) 2021 - 2026 Apple Inc. and the Swift project authors；含 Runtime Library Exception",
                repositoryURL: "https://github.com/apple/swift-collections",
                textFileName: "apache-2.0-runtime-library-exception"
            ),
            LicenseEntry(
                name: "swift-numerics",
                licenseType: "Apache-2.0",
                copyright: "Copyright (c) 2019-2025 Apple Inc. and the Swift Numerics project authors；含 Runtime Library Exception",
                repositoryURL: "https://github.com/apple/swift-numerics",
                textFileName: "apache-2.0-runtime-library-exception"
            ),
            LicenseEntry(
                name: "EventSource",
                licenseType: "MIT",
                copyright: "Copyright 2025 Mattt (https://mat.tt)",
                repositoryURL: "https://github.com/mattt/EventSource",
                textFileName: "eventsource"
            ),
            LicenseEntry(
                name: "yyjson",
                licenseType: "MIT",
                copyright: "Copyright (c) 2020 YaoYuan <ibireme@gmail.com>",
                repositoryURL: "https://github.com/ibireme/yyjson",
                textFileName: "yyjson"
            ),
        ]),

        LicenseSection(title: "界面与数据", entries: [
            LicenseEntry(
                name: "Grape",
                licenseType: "MIT",
                copyright: "Copyright (c) 2023 Zhen Li",
                repositoryURL: "https://github.com/swiftgraphs/Grape",
                textFileName: "grape"
            ),
            LicenseEntry(
                name: "VariableBlur",
                licenseType: "MIT",
                copyright: "Copyright (c) 2012-2023 Nikita Starshinov, Scott Chacon, and others",
                repositoryURL: "https://github.com/nikstar/VariableBlur",
                textFileName: "variableblur",
                platform: .iOS
            ),
            LicenseEntry(
                name: "DeviceKit",
                licenseType: "MIT",
                copyright: "Copyright (c) 2015 Dennis Weissmann",
                repositoryURL: "https://github.com/devicekit/DeviceKit",
                textFileName: "devicekit",
                platform: .iOS
            ),
            LicenseEntry(
                name: "Tux 企鹅形象",
                licenseType: "署名",
                copyright: "Larry Ewing <lewing@isc.tamu.edu> 用 The GIMP 绘制；终端首页的小企鹅照这个形象重画",
                repositoryURL: "https://isc.tamu.edu/~lewing/linux/",
                textFileName: nil,
                platform: .iOS
            ),
            LicenseEntry(
                name: "ZIPFoundation",
                licenseType: "MIT",
                copyright: "Copyright (c) 2017-2025 Thomas Zoechling",
                repositoryURL: "https://github.com/weichsel/ZIPFoundation",
                textFileName: "zipfoundation"
            ),
            LicenseEntry(
                name: "ThinkingOrbsKit",
                licenseType: "MIT",
                copyright: "Copyright (c) 2026 Jakub Antalik",
                repositoryURL: "https://github.com/Jakubantalik/Libraries",
                textFileName: "thinkingorbskit"
            ),
            LicenseEntry(
                name: "Pixelarticons",
                licenseType: "MIT",
                copyright: "Copyright (c) 2019 Gerrit Halfmann；4 个图形改写为代码内的点阵",
                repositoryURL: "https://github.com/halfmage/pixelarticons",
                textFileName: "pixelarticons"
            ),
            LicenseEntry(
                name: "Remix Icon",
                licenseType: "Remix Icon License v1.0",
                copyright: "Copyright (c) 2017–2026 Remix Design；15 个 ri-* 图标按此许可单独授权，不受 AGPL-3.0 约束。品牌 logo 的商标归各自所有人，仅用于标识对应服务",
                repositoryURL: "https://github.com/Remix-Design/RemixIcon",
                textFileName: "remix-icon"
            ),
            LicenseEntry(
                name: "simple-icons",
                licenseType: "CC0-1.0",
                copyright: "ri-openrouter、ri-moonshotai、ri-ollama 三个图标取自 simple-icons。品牌 logo 的商标归各自所有人，仅用于标识对应服务",
                repositoryURL: "https://github.com/simple-icons/simple-icons",
                textFileName: "cc0-1.0"
            ),
            LicenseEntry(
                name: "NGSL 系列词表",
                licenseType: "CC BY-SA 4.0",
                copyright: "Browne, C., Culligan, B., Phillips, J. 等；9 个词表的署名原文见全文",
                repositoryURL: "http://www.newgeneralservicelist.org",
                textFileName: "ngsl"
            ),
        ]),

        LicenseSection(title: "打进应用的脚本与资源", entries: [
            LicenseEntry(
                name: "CodeMirror 6",
                licenseType: "MIT",
                copyright: "Copyright (C) 2018-2021 by Marijn Haverbeke and others",
                repositoryURL: "https://codemirror.net",
                textFileName: "codemirror"
            ),
            LicenseEntry(
                name: "Readability.js",
                licenseType: "Apache-2.0",
                copyright: "Copyright (c) 2010 Arc90 Inc",
                repositoryURL: "https://github.com/mozilla/readability",
                textFileName: "apache-2.0"
            ),
            LicenseEntry(
                name: "Turndown",
                licenseType: "MIT",
                copyright: "Copyright (c) 2017 Dom Christie",
                repositoryURL: "https://github.com/mixmark-io/turndown",
                textFileName: "turndown"
            ),
            LicenseEntry(
                name: "jQuery 3.5.1（卡里网页的内置库）",
                licenseType: "MIT",
                copyright: "Copyright OpenJS Foundation and other contributors",
                repositoryURL: "https://jquery.com",
                textFileName: "cardlib-jquery"
            ),
            LicenseEntry(
                name: "lodash 4.17.23（卡里网页的内置库）",
                licenseType: "MIT",
                copyright: "Copyright OpenJS Foundation and other contributors；Based on Underscore.js, copyright Jeremy Ashkenas, DocumentCloud and Investigative Reporters & Editors",
                repositoryURL: "https://lodash.com",
                textFileName: "cardlib-lodash"
            ),
            LicenseEntry(
                name: "Font Awesome Free 6.5.2（卡里网页的内置库）",
                licenseType: "OFL 1.1 / CC BY 4.0 / MIT",
                copyright: "Copyright 2024 Fonticons, Inc.；字体 SIL OFL 1.1、图标 CC BY 4.0、代码 MIT",
                repositoryURL: "https://fontawesome.com",
                textFileName: "cardlib-fontawesome"
            ),
            LicenseEntry(
                name: "ECDICT",
                licenseType: "MIT",
                copyright: "Copyright (c) 2025 Linwei",
                repositoryURL: "https://github.com/skywind3000/ECDICT",
                textFileName: "ecdict"
            ),
        ]),

        LicenseSection(title: "仅 Mac 版", entries: [
            LicenseEntry(
                name: "Wake",
                licenseType: "MIT",
                copyright: "Copyright (c) 2026 Corey Chiu；编程会话库的模型、解析规则与工具输出格式改编自 Wake v0.6.3",
                repositoryURL: "https://github.com/iAmCorey/Wake",
                textFileName: "wake",
                platform: .mac
            ),
            LicenseEntry(
                name: "Sparkle",
                licenseType: "MIT",
                copyright: "Copyright (c) 2006-2013 Andy Matuschak 等；另含 bsdiff（BSD-2-Clause）、sais-lite（MIT）、ed25519（Zlib）、SUSignatureVerifier（BSD-2-Clause）的声明，见全文",
                repositoryURL: "https://github.com/sparkle-project/Sparkle",
                textFileName: "sparkle",
                platform: .mac
            ),
            LicenseEntry(
                name: "zstd",
                licenseType: "BSD-3-Clause",
                copyright: "Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.；双许可 BSD-3-Clause / GPL-2.0-only，本应用选用 BSD-3-Clause",
                repositoryURL: "https://github.com/facebook/zstd",
                textFileName: "zstd",
                platform: .mac
            ),
            // ATTRIBUTION.md 是 project.yml 单文件 resources，拷在包根 Contents/Resources/（不在 cc-bridge/ 子目录）
            LicenseEntry(
                name: "cc-bridge",
                licenseType: "见 ATTRIBUTION.md",
                copyright: "Mac 端桥接进程，随 Mac 版打包；其中 Bun 与各 npm 依赖的版权和许可见下方全文；架构最初参考 Shitsuten / cc-self-hosting-guide，此处致谢",
                repositoryURL: "https://github.com/replica882/mneme-atrium",
                textFileName: "ATTRIBUTION",
                textFileExtension: "md",
                platform: .mac
            ),
        ]),
    ]
}
