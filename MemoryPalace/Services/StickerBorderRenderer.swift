import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 贴纸描边样式
enum BorderStyle: String, CaseIterable, Codable {
    case none
    case solidWhite = "solid_white"
    case solidBlack = "solid_black"
    case gradientRainbow = "gradient_rainbow"
    case laser
    case lace
    case glitter
    case neon

    var displayName: String {
        switch self {
        case .none: return "无描边"
        case .solidWhite: return "白色描边"
        case .solidBlack: return "黑色描边"
        case .gradientRainbow: return "彩虹渐变"
        case .laser: return "镭射"
        case .lace: return "蕾丝"
        case .glitter: return "闪光"
        case .neon: return "霓虹"
        }
    }
}

/// 贴纸描边渲染引擎
/// 对透明 PNG 的 alpha 通道做膨胀，生成描边区域，填充样式后合成
enum StickerBorderRenderer {

    /// 给贴纸添加描边，返回新 PNG Data
    /// 在后台线程调用
    static func renderBorder(on imageData: Data, style: BorderStyle, width: CGFloat) throws -> Data {
        guard style != .none else { return imageData }

        guard let ciImage = CIImage(data: imageData) else {
            throw BorderError.invalidImage
        }

        // 1. 提取 alpha → 膨胀得到描边 mask
        let borderMask = generateBorderMask(from: ciImage, width: width)

        // 2. 根据样式创建填充
        let borderFill = createBorderFill(style: style, extent: ciImage.extent)

        // 3. 合成：描边层（borderMask * borderFill）+ 原图
        let result = compositeWithBorder(original: ciImage, borderMask: borderMask, borderFill: borderFill)

        // 4. 渲染 PNG
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(result, from: result.extent) else {
            throw BorderError.renderFailed
        }

        return try renderPNG(from: cgImage)
    }

    // MARK: - Border Mask Generation

    /// 从透明 PNG 提取 alpha，膨胀后减去原始 alpha，得到纯描边区域
    private static func generateBorderMask(from image: CIImage, width: CGFloat) -> CIImage {
        // 提取 alpha 通道：用 colorMatrix 把 alpha 映射到 RGB
        let alphaExtract = CIFilter.colorMatrix()
        alphaExtract.inputImage = image
        alphaExtract.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        alphaExtract.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        alphaExtract.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        alphaExtract.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        // alpha → luminance: 把 alpha 值也写入 RGB
        let alphaToLum = CIFilter.colorMatrix()
        alphaToLum.inputImage = alphaExtract.outputImage
        alphaToLum.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        alphaToLum.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        alphaToLum.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        alphaToLum.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        guard let alphaMask = alphaToLum.outputImage else { return image }

        // 膨胀 alpha（多次迭代，每次 radius 有限）
        var dilated = alphaMask
        var remaining = width
        while remaining > 0 {
            let step = min(remaining, 10)
            let dilateFilter = CIFilter.morphologyMaximum()
            dilateFilter.inputImage = dilated
            dilateFilter.radius = Float(step)
            if let result = dilateFilter.outputImage {
                dilated = result
            }
            remaining -= step
        }

        // 描边 = 膨胀后的 - 原始的（差集）
        // 用 subtractBlendMode: dilated - original alpha
        let subtract = CIFilter.subtractBlendMode()
        subtract.inputImage = alphaMask
        subtract.backgroundImage = dilated
        guard let borderOnly = subtract.outputImage else { return dilated }

        return borderOnly
    }

    // MARK: - Border Fill

    /// 根据样式创建描边填充图层
    private static func createBorderFill(style: BorderStyle, extent: CGRect) -> CIImage {
        switch style {
        case .none:
            return CIImage.empty()

        case .solidWhite:
            return CIImage(color: CIColor.white).cropped(to: extent.insetBy(dx: -20, dy: -20))

        case .solidBlack:
            return CIImage(color: CIColor.black).cropped(to: extent.insetBy(dx: -20, dy: -20))

        case .gradientRainbow:
            return createRainbowGradient(extent: extent)

        case .laser:
            return createLaserGradient(extent: extent)

        case .lace:
            // 蕾丝效果：淡粉白交替
            return createLacePattern(extent: extent)

        case .glitter:
            // 闪光：用 randomGenerator 噪波模拟
            return createGlitterFill(extent: extent)

        case .neon:
            // 霓虹：明亮青绿色
            return CIImage(color: CIColor(red: 0.2, green: 1.0, blue: 0.8)).cropped(to: extent.insetBy(dx: -20, dy: -20))
        }
    }

    /// 镭射渐变（多色角度渐变模拟全息效果）
    private static func createLaserGradient(extent: CGRect) -> CIImage {
        let expandedExtent = extent.insetBy(dx: -20, dy: -20)
        // 用两层渐变叠加模拟镭射色彩
        let grad1 = CIFilter.linearGradient()
        grad1.point0 = CGPoint(x: expandedExtent.minX, y: expandedExtent.maxY)
        grad1.point1 = CGPoint(x: expandedExtent.maxX, y: expandedExtent.minY)
        grad1.color0 = CIColor(red: 0.7, green: 0.3, blue: 1.0)   // 紫
        grad1.color1 = CIColor(red: 0.2, green: 0.9, blue: 0.8)   // 青

        let grad2 = CIFilter.linearGradient()
        grad2.point0 = CGPoint(x: expandedExtent.minX, y: expandedExtent.minY)
        grad2.point1 = CGPoint(x: expandedExtent.maxX, y: expandedExtent.maxY)
        grad2.color0 = CIColor(red: 1.0, green: 0.4, blue: 0.6)   // 粉
        grad2.color1 = CIColor(red: 0.3, green: 0.6, blue: 1.0)   // 蓝

        guard let layer1 = grad1.outputImage?.cropped(to: expandedExtent),
              let layer2 = grad2.outputImage?.cropped(to: expandedExtent) else {
            return CIImage(color: CIColor.white).cropped(to: expandedExtent)
        }

        // 叠加两层
        let blend = CIFilter.additionCompositing()
        blend.inputImage = layer2.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)
        ])
        blend.backgroundImage = layer1

        return blend.outputImage?.cropped(to: expandedExtent)
            ?? CIImage(color: CIColor.white).cropped(to: expandedExtent)
    }

    /// 蕾丝效果（柔和粉白色）
    private static func createLacePattern(extent: CGRect) -> CIImage {
        let expandedExtent = extent.insetBy(dx: -20, dy: -20)
        // 淡粉色基底
        let base = CIImage(color: CIColor(red: 1.0, green: 0.92, blue: 0.95)).cropped(to: expandedExtent)
        return base
    }

    /// 闪光填充（噪波纹理模拟亮片）
    private static func createGlitterFill(extent: CGRect) -> CIImage {
        let expandedExtent = extent.insetBy(dx: -20, dy: -20)
        // 金色基底 + 随机噪波高光
        let gold = CIImage(color: CIColor(red: 1.0, green: 0.85, blue: 0.4)).cropped(to: expandedExtent)

        let noise = CIFilter.randomGenerator()
        guard let noiseOutput = noise.outputImage?.cropped(to: expandedExtent) else { return gold }

        // 提高噪波对比度模拟亮片点
        let contrast = CIFilter.colorControls()
        contrast.inputImage = noiseOutput
        contrast.contrast = 3.0
        contrast.brightness = 0.2
        guard let sparkle = contrast.outputImage else { return gold }

        // 叠加
        let blend = CIFilter.screenBlendMode()
        blend.inputImage = sparkle.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.3)
        ])
        blend.backgroundImage = gold
        return blend.outputImage?.cropped(to: expandedExtent) ?? gold
    }

    /// 彩虹渐变
    private static func createRainbowGradient(extent: CGRect) -> CIImage {
        let expandedExtent = extent.insetBy(dx: -20, dy: -20)

        // 用多段线性渐变模拟彩虹
        // 简化版：对角线渐变，红→橙→黄→绿→蓝→紫
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: expandedExtent.minX, y: expandedExtent.minY)
        gradient.point1 = CGPoint(x: expandedExtent.maxX, y: expandedExtent.maxY)
        gradient.color0 = CIColor(red: 1, green: 0.2, blue: 0.2)   // 红
        gradient.color1 = CIColor(red: 0.5, green: 0.2, blue: 1)   // 紫

        return gradient.outputImage?.cropped(to: expandedExtent)
            ?? CIImage(color: CIColor.white).cropped(to: expandedExtent)
    }

    // MARK: - Composite

    /// 合成：描边层在原图下方
    private static func compositeWithBorder(original: CIImage, borderMask: CIImage, borderFill: CIImage) -> CIImage {
        // borderLayer = borderFill * borderMask (alpha masking)
        let maskFilter = CIFilter.blendWithMask()
        maskFilter.inputImage = borderFill
        maskFilter.maskImage = borderMask
        maskFilter.backgroundImage = CIImage.empty()

        guard let borderLayer = maskFilter.outputImage else { return original }

        // 原图叠在描边层上方
        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = original
        composite.backgroundImage = borderLayer

        return composite.outputImage ?? original
    }

    // MARK: - Helpers

    enum BorderError: LocalizedError {
        case invalidImage
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法解析图片"
            case .renderFailed: return "描边渲染失败"
            }
        }
    }

    private static func renderPNG(from cgImage: CGImage) throws -> Data {
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw BorderError.renderFailed
        }
        return pngData
        #else
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else {
            throw BorderError.renderFailed
        }
        return pngData
        #endif
    }
}
