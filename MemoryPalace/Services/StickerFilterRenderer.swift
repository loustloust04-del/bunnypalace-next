import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 贴纸滤镜样式
enum FilterStyle: String, CaseIterable, Codable {
    case none
    case vintage
    case holographic
    case pixel
    case comic

    var displayName: String {
        switch self {
        case .none: return "原图"
        case .vintage: return "复古"
        case .holographic: return "全息"
        case .pixel: return "像素"
        case .comic: return "漫画"
        }
    }
}

/// 贴纸滤镜渲染引擎
enum StickerFilterRenderer {

    /// 对图片应用滤镜，返回新 PNG Data
    static func applyFilter(on imageData: Data, style: FilterStyle) throws -> Data {
        guard style != .none else { return imageData }
        guard let ciImage = CIImage(data: imageData) else {
            throw FilterError.invalidImage
        }

        let filtered: CIImage
        switch style {
        case .none:
            filtered = ciImage
        case .vintage:
            filtered = applyVintage(ciImage)
        case .holographic:
            filtered = applyHolographic(ciImage)
        case .pixel:
            filtered = applyPixel(ciImage)
        case .comic:
            filtered = applyComic(ciImage)
        }

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(filtered, from: filtered.extent) else {
            throw FilterError.renderFailed
        }
        return try renderPNG(from: cgImage)
    }

    // MARK: - Filters

    /// 复古做旧：暖色偏移 + 低饱和度 + 轻微褪色
    private static func applyVintage(_ image: CIImage) -> CIImage {
        let sepia = CIFilter.sepiaTone()
        sepia.inputImage = image
        sepia.intensity = 0.4

        guard let sepiaOutput = sepia.outputImage else { return image }

        let color = CIFilter.colorControls()
        color.inputImage = sepiaOutput
        color.saturation = 0.7
        color.brightness = 0.05
        color.contrast = 1.1

        return color.outputImage ?? sepiaOutput
    }

    /// 全息彩虹：色相偏移 + 对比增强 + 饱和度拉高
    private static func applyHolographic(_ image: CIImage) -> CIImage {
        let hue = CIFilter.hueAdjust()
        hue.inputImage = image
        hue.angle = 1.2 // ~70° 色相偏移

        guard let hueOutput = hue.outputImage else { return image }

        let color = CIFilter.colorControls()
        color.inputImage = hueOutput
        color.saturation = 1.8
        color.contrast = 1.3
        color.brightness = 0.05

        return color.outputImage ?? hueOutput
    }

    /// 像素化
    private static func applyPixel(_ image: CIImage) -> CIImage {
        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = image
        pixellate.scale = max(4, Float(image.extent.width) / 40) // 约 40 像素宽

        return pixellate.outputImage ?? image
    }

    /// 漫画半调
    private static func applyComic(_ image: CIImage) -> CIImage {
        let comic = CIFilter.comicEffect()
        comic.inputImage = image
        return comic.outputImage ?? image
    }

    // MARK: - Helpers

    enum FilterError: LocalizedError {
        case invalidImage
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法解析图片"
            case .renderFailed: return "滤镜渲染失败"
            }
        }
    }

    private static func renderPNG(from cgImage: CGImage) throws -> Data {
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw FilterError.renderFailed
        }
        return pngData
        #else
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else {
            throw FilterError.renderFailed
        }
        return pngData
        #endif
    }
}
