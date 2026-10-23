import Foundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Apple Vision Subject Lifting — 一键抠图
enum SubjectLifter {

    enum LiftError: LocalizedError {
        case invalidImage
        case noSubjectFound
        case maskGenerationFailed
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法解析图片"
            case .noSubjectFound: return "未检测到前景主体"
            case .maskGenerationFailed: return "遮罩生成失败"
            case .renderFailed: return "图片渲染失败"
            }
        }
    }

    /// 抠图：输入任意图片，返回透明背景的 PNG Data
    /// 必须在后台线程调用
    static func liftSubject(from imageData: Data) throws -> Data {
        // 1. Data → CIImage
        guard let ciInput = CIImage(data: imageData) else {
            throw LiftError.invalidImage
        }

        // 2. 创建 Vision 请求
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: ciInput, options: [:])

        // 3. 执行（CPU/GPU/Neural Engine）
        try handler.perform([request])

        // 4. 获取遮罩
        guard let observation = request.results?.first else {
            throw LiftError.noSubjectFound
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )

        // 5. CoreImage 合成：前景 + 透明背景
        let maskCI = CIImage(cvPixelBuffer: maskBuffer)

        let blendFilter = CIFilter.blendWithMask()
        blendFilter.inputImage = ciInput
        blendFilter.maskImage = maskCI
        blendFilter.backgroundImage = CIImage.empty()

        guard let outputCI = blendFilter.outputImage else {
            throw LiftError.renderFailed
        }

        // 6. 渲染为 PNG
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(outputCI, from: outputCI.extent) else {
            throw LiftError.renderFailed
        }

        return try renderPNG(from: cgImage)
    }

    // MARK: - PNG Rendering

    private static func renderPNG(from cgImage: CGImage) throws -> Data {
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw LiftError.renderFailed
        }
        return pngData
        #else
        let uiImage = UIImage(cgImage: cgImage)
        guard let pngData = uiImage.pngData() else {
            throw LiftError.renderFailed
        }
        return pngData
        #endif
    }
}
