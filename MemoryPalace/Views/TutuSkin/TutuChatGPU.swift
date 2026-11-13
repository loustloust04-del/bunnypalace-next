#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Metal

struct TutuChatRaster {
    let texture: MTLTexture
    let rect: CGRect
    var allocatedBytes: Int { texture.allocatedSize }
}

enum TutuChatError: LocalizedError {
    case allocation, shader(String), image(URL), font(URL), command(String)
    case textureSize
    var errorDescription: String? {
        switch self {
        case .allocation: return "兔兔聊天的 Metal 资源未能分配"
        case .shader(let name): return "兔兔聊天着色器缺失：\(name)"
        case .image(let url): return "兔兔聊天素材无法读取：\(url.lastPathComponent)"
        case .font(let url): return "兔兔聊天字体无法注册：\(url.lastPathComponent)"
        case .command(let message): return "兔兔聊天绘制失败：\(message)"
        case .textureSize: return "兔兔聊天材质超出当前设备的纹理尺寸限制"
        }
    }
}

struct TutuChatPixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TutuChatError.image(url) }
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw TutuChatError.image(url) }
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[offset + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 { bytes[offset + channel] = UInt8(min(255, (Int(bytes[offset + channel]) * 255 + alpha / 2) / alpha)) }
            }
        }
        rgba = bytes
    }
}

final class TutuChatGPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let resourceURL: URL
    /// Metal has no maxTextureSize2D property in the current SDK.
    /// https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf (Resources)
    var maxTextureSize2D: Int {
        if #available(iOS 26.0, macOS 26.0, *), device.supportsFamily(.apple10) { return 32_768 }
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac2) { return 16_384 }
        return 8_192
    }

    static func checkedDimension(_ value: CGFloat, limit: Int) throws -> Int {
        guard value.isFinite, value >= 1, value <= CGFloat(limit) else { throw TutuChatError.textureSize }
        return Int(value)
    }

    static func checkSize(width: Int, height: Int, limit: Int) throws {
        guard width > 0, height > 0, width <= limit, height <= limit else { throw TutuChatError.textureSize }
    }

    /// Run immediately after layout, before creating any message workset.
    @discardableResult
    func preflight(item: TutuChatItemLayout, scale: CGFloat) throws -> TutuLaceRenderer.Geometry? {
        for card in item.cards {
            _ = try TutuCardRenderer.preflight(size: card.layout.size, scale: scale, gpu: self, origin: card.origin)
        }
        for felt in item.felts {
            _ = try TutuFeltRenderer.preflight(size: felt.size, ears: felt.ears, tail: felt.tail,
                emoji: felt.emoji, scale: scale, gpu: self, origin: felt.origin)
        }
        if !item.cards.isEmpty {
            return try TutuLaceRenderer.geometry(cards: item.cards.map { CGRect(origin: $0.origin, size: $0.layout.size) },
                index: item.turnIndex, scale: scale, limit: maxTextureSize2D)
        }
        return nil
    }

    private static let lock = NSLock()
    private static var queues: [UInt64: MTLCommandQueue] = [:]
    private static var texturePipelines: [UInt64: MTLRenderPipelineState] = [:]

    static func commandQueue(device: MTLDevice) throws -> MTLCommandQueue {
        lock.lock(); defer { lock.unlock() }
        if let queue = queues[device.registryID] { return queue }
        guard let queue = device.makeCommandQueue() else { throw TutuChatError.allocation }
        queues[device.registryID] = queue
        return queue
    }

    static func texturePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        lock.lock(); defer { lock.unlock() }
        return texturePipelines[device.registryID]
    }

    init(device: MTLDevice, library: MTLLibrary, resourceURL: URL) throws {
        self.device = device; self.library = library; self.resourceURL = resourceURL
        queue = try Self.commandQueue(device: device)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if Self.texturePipelines[device.registryID] == nil {
            let descriptor = MTLRenderPipelineDescriptor()
            guard let vertex = library.makeFunction(name: "tutuChatTextureVertex"),
                  let fragment = library.makeFunction(name: "tutuChatTextureFragment") else {
                throw TutuChatError.shader("tutuChatTextureFragment")
            }
            descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .sourceAlpha; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            Self.texturePipelines[device.registryID] = try device.makeRenderPipelineState(descriptor: descriptor)
        }
    }

    func pipeline(_ name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else { throw TutuChatError.shader(name) }
        return try device.makeComputePipelineState(function: function)
    }

    func texture(width: Int, height: Int, format: MTLPixelFormat = .rgba8Unorm,
                 storage: MTLStorageMode = .shared) throws -> MTLTexture {
        try Self.checkSize(width: width, height: height, limit: maxTextureSize2D)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = storage
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw TutuChatError.allocation }
        TutuChatRenderTrace.emit("texture.allocate", "\(width)x\(height)", Double(texture.allocatedSize))
        TutuChatRenderTrace.allocated(texture)
        return texture
    }

    func image(_ name: String) throws -> MTLTexture {
        let pixels = try TutuChatPixels(url: resourceURL.appendingPathComponent(name))
        TutuChatRenderTrace.emit("texture.upload.begin", name)
        defer { TutuChatRenderTrace.emit("texture.upload.end", name) }
        let target = try texture(width: pixels.width, height: pixels.height)
        pixels.rgba.withUnsafeBytes { bytes in
            target.replace(region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: pixels.width * 4)
        }
        return target
    }

    #if TUTU_SCROLL_COUNTERS
    private var counterSamples: [ObjectIdentifier: [(String, MTLCounterSampleBuffer)]] = [:]
    #endif

    func computeEncoder(_ command: MTLCommandBuffer, label: String) throws -> MTLComputeCommandEncoder? {
        #if TUTU_SCROLL_COUNTERS
        guard device.supportsCounterSampling(.atStageBoundary),
              let counters = device.counterSets?.first(where: { $0.name == "timestamp" }) else {
            throw TutuChatError.command("测量宿主缺少 Metal stage-boundary timestamp counters")
        }
        let samples = MTLCounterSampleBufferDescriptor()
        samples.counterSet = counters; samples.storageMode = .shared; samples.sampleCount = 2
        let buffer = try device.makeCounterSampleBuffer(descriptor: samples)
        let pass = MTLComputePassDescriptor()
        pass.sampleBufferAttachments[0].sampleBuffer = buffer
        pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = 0
        pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = 1
        counterSamples[ObjectIdentifier(command), default: []].append((label, buffer))
        return command.makeComputeCommandEncoder(descriptor: pass)
        #else
        return command.makeComputeCommandEncoder()
        #endif
    }

    func complete(_ buffer: MTLCommandBuffer) throws {
        TutuChatRenderTrace.emit("gpu.submit", buffer.label ?? "unlabelled")
        buffer.commit(); buffer.waitUntilCompleted()
        TutuChatRenderTrace.emit("gpu.complete", buffer.label ?? "unlabelled", max(0, buffer.gpuEndTime - buffer.gpuStartTime))
        guard buffer.status == .completed else { throw TutuChatError.command(buffer.error?.localizedDescription ?? "GPU command incomplete") }
        #if TUTU_SCROLL_COUNTERS
        for (label, samples) in counterSamples.removeValue(forKey: ObjectIdentifier(buffer)) ?? [] {
            guard let data = try samples.resolveCounterRange(0..<2), data.count >= 2 * MemoryLayout<MTLCounterResultTimestamp>.stride else {
                throw TutuChatError.command("Metal timestamp counter resolve 失败")
            }
            let seconds = try data.withUnsafeBytes { bytes -> Double in
                let values = bytes.bindMemory(to: MTLCounterResultTimestamp.self)
                guard values[0].timestamp != UInt64.max, values[1].timestamp != UInt64.max, values[1].timestamp >= values[0].timestamp else {
                    throw TutuChatError.command("Metal timestamp counter 无效")
                }
                return Double(values[1].timestamp - values[0].timestamp) / 1_000_000_000
            }
            TutuChatRenderTrace.emit("gpu.encoder", label, seconds)
        }
        #endif
    }
}

struct TutuChatRandom {
    private var state: UInt32
    private var spare: Double?
    init(seed: Int) {
        state = UInt32(truncatingIfNeeded: seed) &* 0x9E3779B1
        for _ in 0..<4 { _ = random() }
    }
    mutating func random() -> Double {
        state &+= 0x6D2B79F5
        var value = (state ^ (state >> 15)) &* (1 | state)
        value = (value &+ ((value ^ (value >> 7)) &* (61 | value))) ^ value
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * random() }
    mutating func integer(_ n: Int) -> Int { Int(floor(random() * Double(n))) }
    mutating func exponential(_ scale: Double) -> Double { -log(1 - random()) * scale }
    mutating func normal(_ mean: Double, _ deviation: Double) -> Double {
        if let saved = spare { spare = nil; return mean + deviation * saved }
        let first = max(random(), 1e-12), second = random(), magnitude = sqrt(-2 * log(first))
        spare = magnitude * sin(2 * .pi * second)
        return mean + deviation * magnitude * cos(2 * .pi * second)
    }
}
#endif
#endif
