#if os(iOS)
import SwiftUI

enum Page2VisualStyle {
    static let ink = Color(red: 0.22, green: 0.25, blue: 0.23)
    static let rose = Color(red: 0.66, green: 0.40, blue: 0.45)
    static let sage = Color(red: 0.36, green: 0.48, blue: 0.41)
    static func tint(_ name: String) -> Color {
        switch name {
        case "rose": return rose
        case "plum": return Color(red: 0.47, green: 0.40, blue: 0.49)
        case "graphite": return ink
        default: return sage
        }
    }
}

struct Page2DesktopLabel: ViewModifier {
    @State private var appearance = Page2AppearanceStore.shared
    private var lightWallpaper: Bool {
        appearance.displayed.wantsDarkForeground
    }
    func body(content: Content) -> some View {
        content.foregroundStyle(lightWallpaper ? Color.black.opacity(0.8) : .white)
            .shadow(color: lightWallpaper ? .clear : .black.opacity(0.55), radius: 2, y: 1)
    }
}

struct Page2RemoveBadge: View {
    static let originOffset: CGFloat = -19
    let label: String
    var editing = true
    var action: () -> Void
    @State private var retainingExit = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var symbol: some View {
        Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.8))
            .frame(width: 26, height: 26)
    }
    var body: some View {
        ZStack {
            if editing || retainingExit { badge }
        }
        .frame(width: 44, height: 44)
        .task(id: editing) {
            if editing { retainingExit = true }
            else {
                if !reduceMotion {
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled else { return }
                }
                retainingExit = false
            }
        }
    }

    private var badge: some View {
        GlassEffectContainer(spacing: 0) {
            Group {
                if reduceTransparency { symbol.background(Color(white: 0.86), in: Circle()) }
                else { symbol.glassEffect(.regular, in: .circle) }
            }
        }
        .compositingGroup()
        .modifier(Page2BadgeScale(scale: editing || reduceMotion ? 1 : 0).ignoredByLayout())
        .opacity(editing ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: editing)
        .frame(width: 44, height: 44).contentShape(Rectangle())
        .allowsHitTesting(editing)
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(!editing)
        .accessibilityLabel(label).accessibilityAddTraits(.isButton)
        .accessibilityAction { if editing { action() } }
    }
}

struct Page2EditingButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.1, *) { content.buttonStyle(GlassButtonStyle(.clear)) }
        else { content.buttonStyle(.glass) }
    }
}

struct Page2DockSurface: View {
    var cornerRadius: CGFloat = 37
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            } else {
                Color.clear.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct Page2AppIcon: View {
    let tool: RightPanelTool
    var side: CGFloat = 56
    var label = true
    var followsIconSize = true
    var interactive = true
    var editing = false
    var usesGlass = true
    var decorative = false
    var action: () -> Void = {}
    @State private var appearance = Page2AppearanceStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.page2Date) private var date
    /// 小芽外观提案的试穿预览：直接传入改前 / 改后的值，不走全局 preview（astra A4/B6）；nil = 读全局
    var appearanceOverride: Page2Appearance? = nil
    private var shown: Page2Appearance { appearanceOverride ?? appearance.displayed }

    private var clearAppearance: Bool { shown.rendering == "clear" && !reduceTransparency }
    private var iconGlass: Glass {
        (clearAppearance ? Glass.clear : .regular).interactive(interactive && !editing)
    }
    private var renderedSide: CGFloat { side + (followsIconSize && shown.largeIcons ? 12 : 0) }
    private var custom: Page2IconOverride? { shown.icons[tool.id] }

    @ViewBuilder var body: some View {
        if decorative {
            iconSurface.accessibilityHidden(true)
        } else {
            VStack(spacing: 5) {
                iconSurface
                if label && !shown.largeIcons {
                    Text(tool.name)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .modifier(Page2DesktopLabel())
                }
            }
            .modifier(Page2EditingMotion(enabled: editing, seed: tool.order, pivotHeight: renderedSide))
            .contentShape(Rectangle())
            .onTapGesture { if interactive { action() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tool.name)
            .accessibilityIdentifier("page2.app.\(tool.id)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if interactive { action() } }
        }
    }

    @ViewBuilder private var iconSurface: some View {
        if usesGlass {
            glyph
                .shadow(color: clearAppearance ? .black.opacity(0.24) : .clear, radius: 0.6, x: 0.3, y: 0.8)
                .frame(width: renderedSide, height: renderedSide)
                .glassEffect(iconGlass, in: .rect(cornerRadius: renderedSide * 0.26))
        } else {
            glyph.frame(width: renderedSide, height: renderedSide)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: renderedSide * 0.26))
        }
    }

    private var glyphColor: Color {
        if clearAppearance { return .white.opacity(0.94) }
        if shown.rendering == "tinted" {
            return Color(hue: shown.tintHue, saturation: shown.tintSaturation, brightness: 0.8)
        }
        return custom.map { Page2VisualStyle.tint($0.tint) } ?? .primary
    }
    /// 没自定义过才用本地默认图（Debug 包且本机拷进了图）
    private var localDefaultIcon: Image? {
        #if DEBUG
        custom == nil ? LocalDefaultIcon.image(for: tool.id) : nil
        #else
        nil
        #endif
    }
    @ViewBuilder private var glyph: some View {
        if tool.id == "calendar" && custom == nil {
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: renderedSide * 0.16, weight: .semibold))
                    .foregroundStyle(clearAppearance ? glyphColor : .red)
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: renderedSide * 0.58, weight: .light))
                    .foregroundStyle(glyphColor)
            }.frame(width: renderedSide * 0.82, height: renderedSide * 0.82)
        } else if let image = appearance.image(named: custom?.imageFile) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: renderedSide - 4, height: renderedSide - 4)
                .clipShape(RoundedRectangle(cornerRadius: renderedSide * 0.23))
        } else if let local = localDefaultIcon {
            local.resizable().scaledToFill()
                .frame(width: renderedSide - 4, height: renderedSide - 4)
                .clipShape(RoundedRectangle(cornerRadius: renderedSide * 0.23))
        } else {
            let name = custom?.symbol ?? tool.icon
            if AppIconView.isAssetName(name) {
                AppIconView(name: name, size: renderedSide * 0.48, tint: glyphColor)
            } else {
                Image(systemName: name).resizable().scaledToFit()
                    .frame(width: renderedSide * 0.56, height: renderedSide * 0.56)
                    .foregroundStyle(glyphColor)
            }
        }
    }

}

struct Page2WidgetSurface: ViewModifier {
    @State private var appearance = Page2AppearanceStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder func body(content: Content) -> some View {
        if appearance.displayed.rendering == "clear" && !reduceTransparency {
            content.environment(\.colorScheme, appearance.displayed.isPaleGlass && appearance.displayed.luminosity != "dark" ? .light : .dark).saturation(0)
                .glassEffect(.clear, in: .rect(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else if appearance.displayed.rendering == "tinted" {
            content.environment(\.colorScheme, .dark).saturation(0)
                .colorMultiply(Color(hue: appearance.displayed.tintHue, saturation: appearance.displayed.tintSaturation, brightness: 0.8))
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

struct Page2WallpaperView: UIViewRepresentable {
    let appearance: Page2Appearance
    /// 只有主屏传 true：花园四季的细节会动（#039）；其余实例只放静帧。常量，不随状态变
    var animated = false

    func makeUIView(context: Context) -> WallpaperCanvas {
        let view = WallpaperCanvas()
        view.animated = animated
        return view
    }
    func updateUIView(_ view: WallpaperCanvas, context: Context) { view.apply(appearance) }

    final class WallpaperCanvas: UIView {
        private let imageView = UIImageView()
        private let wash = CAGradientLayer()
        private var configuration: Page2Appearance?
        private var loadedImage: String?
        private var garden: GardenWallpaperView?
        var animated = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            isUserInteractionEnabled = false
            imageView.contentMode = .scaleAspectFill
            addSubview(imageView)
            layer.addSublayer(wash)
        }
        required init?(coder: NSCoder) { nil }

        func apply(_ value: Page2Appearance) {
            guard configuration != value else { return }
            configuration = value
            let wp = value.resolvedWallpaper
            if wp == "garden" {
                if garden == nil {
                    let view = GardenWallpaperView()
                    view.animated = animated
                    insertSubview(view, aboveSubview: imageView)
                    garden = view
                }
                imageView.isHidden = true
                imageView.image = nil
                loadedImage = nil
                wash.colors = nil
                backgroundColor = UIColor(red: 0.98, green: 0.98, blue: 0.95, alpha: 1)
                setNeedsLayout()
                return
            }
            garden?.removeFromSuperview()
            garden = nil
            let bundledImage = wp == "ios26" ? "page2-ios26-wallpaper" : (wp == "flora" ? "page2-flora" : nil)
            let imageKey = bundledImage ?? (wp == "photo" ? value.imageFile : nil)
            if loadedImage != imageKey {
                loadedImage = imageKey
                if let bundledImage { imageView.image = UIImage(named: bundledImage) }
                else if let url = Page2AppearanceStore.shared.assetURL(value.imageFile) { imageView.image = UIImage(contentsOfFile: url.path) }
                else { imageView.image = nil }
            }
            imageView.isHidden = imageKey == nil
            let dark = wp == "dusk"
            backgroundColor = dark ? UIColor(red: 0.10, green: 0.15, blue: 0.13, alpha: 1) : UIColor(red: 0.98, green: 0.98, blue: 0.95, alpha: 1)
            if wp == "ios26" {
                let shade = UIColor(white: 0, alpha: max(0, value.dimming - 0.15)).cgColor
                wash.colors = [shade, shade]
            } else {
                wash.colors = dark ? [UIColor(white: 0, alpha: 0.05).cgColor, UIColor(red: 0.28, green: 0.22, blue: 0.29, alpha: 0.7).cgColor] :
                    [UIColor(white: 1, alpha: value.dimming).cgColor, UIColor(red: 0.70, green: 0.79, blue: 0.72, alpha: 0.42).cgColor]
            }
            wash.startPoint = CGPoint(x: 0.1, y: 0)
            wash.endPoint = CGPoint(x: 0.9, y: 1)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wash.frame = bounds
            garden?.frame = bounds
            let extra: CGFloat = loadedImage == "page2-ios26-wallpaper" ? 0 : 80
            imageView.frame = bounds.insetBy(dx: -extra, dy: -extra).offsetBy(dx: CGFloat(configuration?.offsetX ?? 0) * extra,
                                                                          dy: CGFloat(configuration?.offsetY ?? 0) * extra)
            CATransaction.commit()
        }
    }
}
#endif
