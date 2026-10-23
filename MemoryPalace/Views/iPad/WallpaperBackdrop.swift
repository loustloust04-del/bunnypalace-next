#if os(iOS)
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 宽屏下铺满整个 ContentView 的壁纸底层（图 + 渐变，静态、不吃触摸），让桌面格子底下也是壁纸。
/// 翻页容器被 `DockedInsetHost` 推窄后自己那层壁纸跟着窄、两侧露底色；宽屏下把它的 config 置空，
/// 壁纸只由这一层画，避免两份裁切不同在边界出缝。画法照抄 `PagingViewController.applyWallpaper`。
extension WallpaperConfig {
    /// 什么都不画：宽屏下翻页容器用这个，壁纸由 WallpaperBackdrop 画
    static let cleared = WallpaperConfig(fill: .clear, imageURL: nil, saturation: 1, opacity: 1,
                                         offsetX: 0, offsetY: 0, gradientColors: [])
}

struct WallpaperBackdrop: UIViewRepresentable {
    let config: WallpaperConfig

    func makeUIView(context: Context) -> WallpaperBackdropView { WallpaperBackdropView() }
    func updateUIView(_ view: WallpaperBackdropView, context: Context) { view.apply(config) }
}

final class WallpaperBackdropView: UIView {
    private let imageView = UIImageView()
    private let gradient = CAGradientLayer()
    private var last: WallpaperConfig?
    private var lastImageURL: URL?
    private var lastSaturation: CGFloat = 1
    private static let ciContext = CIContext()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        #if DEBUG
        // 探针：键盘弹起时这层不许跟着缩放（SwiftUI .background 会，见 research-wallpaper-uikit-layer）
        print("[PROBE backdrop] bounds=\(bounds.size)")
        #endif
    }

    func apply(_ config: WallpaperConfig) {
        guard config != last else { return }
        defer { last = config }
        backgroundColor = UIColor(config.fill)
        if config.imageURL != lastImageURL || config.saturation != lastSaturation {
            lastImageURL = config.imageURL
            lastSaturation = config.saturation
            if let url = config.imageURL, let raw = UIImage(contentsOfFile: url.path) {
                imageView.image = Self.saturated(raw, config.saturation)
                imageView.isHidden = false
            } else {
                imageView.image = nil
                imageView.isHidden = true
            }
        }
        imageView.alpha = config.opacity
        imageView.transform = CGAffineTransform(translationX: config.offsetX, y: config.offsetY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = config.gradientColors.map { $0.cgColor }
        CATransaction.commit()
    }

    private static func saturated(_ image: UIImage, _ saturation: CGFloat) -> UIImage {
        guard abs(saturation - 1) > 0.001, let ci = CIImage(image: image) else { return image }
        let f = CIFilter.colorControls()
        f.inputImage = ci
        f.saturation = Float(saturation)
        guard let out = f.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}
#endif
