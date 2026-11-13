#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import Metal

/// chat11.js `paint`: every time here is relative to the successful first send, not page mount.
struct TutuChatIntroPhase {
    static let duration = 2.75
    static let finalZoom = 1.4286

    let zoom: Double
    let bottom: Double
    let top: Double
    let chromeOpacity: Double
    let shadeOpacity: Double
    let dateOpacity: Double
    let feltRiseProgress: Double
    let feltScale: Double
    let feltOpacity: Double
    let recallOpacity: Double
    /// Source CSS mask: opaque through this percentage, transparent fifteen percentage points later.
    let laceMaskEndPercent: Double
    let finished: Bool

    init(elapsed: Double) {
        zoom = 1 + (Self.finalZoom - 1) * Self.inOut(Self.span(elapsed, 0, 2.4))
        bottom = Self.span(elapsed, 0.15, 1.55)
        top = Self.span(elapsed, 0.65, 2.1)
        chromeOpacity = Self.smooth(Self.span(elapsed, 0, 0.32))
        shadeOpacity = Self.smooth(Self.span(elapsed, 0.1, 1.0))
        dateOpacity = Self.smooth(Self.span(elapsed, 0.05, 0.45))
        let rise = 1 - pow(1 - Self.span(elapsed, 0, 0.62), 3)
        feltRiseProgress = rise
        feltScale = 0.7 + 0.3 * rise
        feltOpacity = Self.smooth(Self.span(elapsed, 0, 0.18))
        recallOpacity = Self.smooth(Self.span(elapsed, 0.65, 0.65 + 0.3))
        laceMaskEndPercent = 115 * Self.inOut(Self.span(elapsed, 0.8, 0.8 + 1.1)) - 15
        finished = elapsed >= Self.duration
    }

    private static func span(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(1, max(0, (t - a) / (b - a)))
    }

    private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private static func inOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

/// A single intro owns its captured M1 frame, locked tone and one precompiled output format.
/// No command submission, waiting, texture allocation or pipeline creation happens in `encode`.
/// The owner serializes encoding and releases this object when the intro ends or is interrupted;
/// normal retained-reference command buffers keep already-encoded resources alive until completion.
final class TutuChatIntroRenderer {
    enum Failure: LocalizedError {
        case shader(String), targetFormat(MTLPixelFormat), encoder

        var errorDescription: String? {
            switch self {
            case .shader(let name): return "兔兔进场着色器缺失：\(name)"
            case .targetFormat(let format): return "兔兔进场不支持输出格式：\(format.rawValue)"
            case .encoder: return "兔兔进场无法创建 Metal 绘制编码器"
            }
        }
    }

    private struct Uniforms {
        var geometry: SIMD4<Float> // target pixels (x/y), zoom, bottom light
        var printing: SIMD4<Float> // top light, MAXC, source-point screen (width/height)
        var silver: SIMD4<Float>
    }

    private let pipeline: MTLRenderPipelineState
    private let pixelFormat: MTLPixelFormat
    private let cath: MTLTexture
    private let tone: MTLTexture
    private let maxCoverage: Float
    private let silver: SIMD4<Float>
    private let pass = MTLRenderPassDescriptor()

    init(device: MTLDevice, library: MTLLibrary, cath: MTLTexture, tone: MTLTexture, mode: String,
         pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let vertex = library.makeFunction(name: "tutuChatIntroVertex") else {
            throw Failure.shader("tutuChatIntroVertex")
        }
        guard let fragment = library.makeFunction(name: "tutuChatIntroFragment") else {
            throw Failure.shader("tutuChatIntroFragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        // Offscreen reference capture may use RGBA, but never changes fragment values or swizzles RGB.
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.pixelFormat = pixelFormat
        self.cath = cath
        self.tone = tone
        maxCoverage = mode == "night" ? 0.28 : 0.30
        let value: Float = mode == "night" ? 108 : 111
        silver = SIMD4(value / 255, (value - 4) / 255, (value - 9) / 255, 0)
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
    }

    func encode(commandBuffer: MTLCommandBuffer, target: MTLTexture, elapsed: Double,
                pointSize: CGSize = CGSize(width: 390, height: 844)) throws {
        guard target.pixelFormat == pixelFormat else { throw Failure.targetFormat(target.pixelFormat) }
        let phase = TutuChatIntroPhase(elapsed: elapsed)
        var uniforms = Uniforms(
            geometry: SIMD4(Float(target.width), Float(target.height), Float(phase.zoom), Float(phase.bottom)),
            printing: SIMD4(Float(phase.top), maxCoverage, Float(pointSize.width), Float(pointSize.height)), silver: silver)
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        // Do not retain the previous drawable between frames or after the transition is released.
        defer { attachment.texture = nil }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.encoder }
        encoder.label = "Tutu chat intro"
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))
        encoder.setFragmentTexture(cath, index: 0)
        encoder.setFragmentTexture(tone, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
#endif
#endif
