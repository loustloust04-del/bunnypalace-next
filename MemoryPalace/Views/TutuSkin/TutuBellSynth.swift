#if PERSONAL_APPS
#if os(iOS)
import Foundation
import Accelerate
import Synchronization

/// The Bell in unlock-gl.js, shared by the source node and the offline WAV harness.
/// One producer calls enqueue; one audio consumer calls render. Everything used by render
/// (including the command ring, oscillators, FFTs and convolution history) is allocated here.
final class TutuBellSynth: @unchecked Sendable {
    enum Event: UInt32 {
        case dang = 0
        case ding = 1

        init?(name: String) {
            switch name {
            case "dang": self = .dang
            case "ding": self = .ding
            default: return nil
            }
        }

        var tailSeconds: Double { self == .dang ? 10.41 : 4.31 }
    }

    struct Partial {
        let ratio: Double
        let amplitude: Double
        let decay: Double
        init(_ ratio: Double, _ amplitude: Double, _ decay: Double) {
            self.ratio = ratio
            self.amplitude = amplitude
            self.decay = decay
        }
    }

    static let dangPartials = [
        Partial(0.5, 0.55, 7.5), Partial(0.503, 0.25, 6.5),
        Partial(1.0, 0.5, 4.5), Partial(1.2, 0.42, 3.8),
        Partial(1.5, 0.18, 2.6), Partial(2.0, 0.5, 3.2),
        Partial(2.006, 0.22, 3.0), Partial(2.51, 0.14, 1.6),
        Partial(2.66, 0.12, 1.4), Partial(3.01, 0.16, 1.2),
        Partial(4.07, 0.09, 0.8), Partial(5.2, 0.06, 0.35),
        Partial(6.8, 0.04, 0.2),
    ]
    static let dingPartials = [
        Partial(1.0, 0.5, 1.4), Partial(1.004, 0.2, 1.2),
        Partial(2.76, 0.18, 0.6), Partial(5.4, 0.08, 0.3),
    ]

    let sampleRate: Double
    /// WebAudio ConvolverNode.normalize defaults to true. This implementation uses
    /// the legacy rounded calibration 0.00125 (about -58.06 dB, not exactly -58 dB),
    /// with the 44100 / IR sample-rate compensation. Keep its existing audible gain.
    let impulseNormalization: Float
    let impulseFrames: Int
    private let reverb: TutuBellConvolution
    private let definitions: UnsafeMutablePointer<Voice>
    private let voices: UnsafeMutablePointer<Voice>
    private let commands: UnsafeMutablePointer<Command>
    private let commandWrite = Atomic<Int>(0)
    private let commandRead = Atomic<Int>(0)
    private static let commandCapacity = 128
    private static let voiceCapacity = 416 // 32 simultaneous thirteen-partial strikes.
    private var voiceCount = 0
    private var frame: Int64 = 0

    private struct Command {
        var event: UInt32 = 0
        var frame: Int64 = -1
    }

    private struct Voice {
        var start: Int64 = 0
        var age: Int = 0
        var stopAge = 0
        var attackFrames: Double = 0
        var decayFrames: Double = 0
        var peak: Double = 0
        var envelope: Double = 0
        var envelopeStep: Double = 0
        var firstDecayEnvelope: Double = 0
        var firstDecayAge = 0
        var sine: Double = 0
        var cosine: Double = 1
        var sineStep: Double = 0
        var cosineStep: Double = 1
    }

    init(sampleRate: Double = 48_000, seed: UInt32 = 1) {
        precondition(sampleRate.isFinite && sampleRate >= 24_000)
        self.sampleRate = sampleRate
        let length = Int(floor(sampleRate * 2.8))
        impulseFrames = length
        let left = TutuBellFloatStorage(length)
        let right = TutuBellFloatStorage(length)
        var state = seed == 0 ? 1 : seed
        var power = 0.0
        // A seeded uniform source makes the native capture reproducible; the original
        // uses Math.random, so independently generated IRs are not sample-identical.
        for channel in 0..<2 {
            let destination = channel == 0 ? left.pointer : right.pointer
            for index in 0..<length {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                let random = Double(state) / 4_294_967_296
                let value = Float((random * 2 - 1) * pow(1 - Double(index) / Double(length), 3.2))
                destination[index] = value
                power += Double(value) * Double(value)
            }
        }
        let rms = max(0.000125, sqrt(power / Double(2 * length)))
        let normalization = Float((1 / rms) * 0.00125 * 44_100 / sampleRate)
        impulseNormalization = normalization
        var multiplier = normalization
        vDSP_vsmul(left.pointer, 1, &multiplier, left.pointer, 1, vDSP_Length(length))
        vDSP_vsmul(right.pointer, 1, &multiplier, right.pointer, 1, vDSP_Length(length))
        reverb = TutuBellConvolution(left: left.pointer, right: right.pointer, count: length)

        definitions = .allocate(capacity: 17)
        definitions.initialize(repeating: Voice(), count: 17)
        voices = .allocate(capacity: Self.voiceCapacity)
        voices.initialize(repeating: Voice(), count: Self.voiceCapacity)
        commands = .allocate(capacity: Self.commandCapacity)
        commands.initialize(repeating: Command(), count: Self.commandCapacity)
        for (offset, table, frequency, gain) in [
            (0, Self.dangPartials, 165.0, 0.3),
            (13, Self.dingPartials, 2093.0, 0.12),
        ] {
            for (index, partial) in table.enumerated() {
                let peak = partial.amplitude * gain
                let step = log(0.0001 / peak) / ((partial.decay - 0.004) * sampleRate)
                let attackFrames = sampleRate * 0.004
                let firstDecayAge = ceil(attackFrames)
                let phase = 2 * Double.pi * frequency * partial.ratio / sampleRate
                definitions[offset + index] = Voice(
                    stopAge: Int(ceil((partial.decay + 0.1) * sampleRate)),
                    attackFrames: attackFrames,
                    decayFrames: partial.decay * sampleRate,
                    peak: peak,
                    envelopeStep: exp(step),
                    firstDecayEnvelope: peak * exp(step * (firstDecayAge - attackFrames)),
                    firstDecayAge: Int(firstDecayAge),
                    sineStep: sin(phase),
                    cosineStep: cos(phase)
                )
            }
        }
    }

    deinit {
        definitions.deinitialize(count: 17)
        definitions.deallocate()
        voices.deinitialize(count: Self.voiceCapacity)
        voices.deallocate()
        commands.deinitialize(count: Self.commandCapacity)
        commands.deallocate()
    }

    /// atFrame is the instant Bell.dang/ding is called; the original 10ms onset is
    /// added by the consumer. Offline commands must be enqueued chronologically.
    /// False means the fixed command ring is full (never block the audio thread).
    @discardableResult
    func enqueue(event: Event, atFrame: Int64? = nil) -> Bool {
        let write = commandWrite.load(ordering: .relaxed)
        let read = commandRead.load(ordering: .acquiring)
        guard write - read < Self.commandCapacity else { return false }
        commands[write % Self.commandCapacity] = Command(event: event.rawValue, frame: atFrame ?? -1)
        commandWrite.store(write + 1, ordering: .releasing)
        return true
    }

    /// The caller owns noninterleaved output storage. Optional dry is the mono signal
    /// after the original dry gain and output gain, before the convolution return.
    func render(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        dry: UnsafeMutablePointer<Float>? = nil
    ) {
        let write = commandWrite.load(ordering: .acquiring)
        var read = commandRead.load(ordering: .relaxed)
        for index in 0..<frameCount {
            while read < write {
                let command = commands[read % Self.commandCapacity]
                guard command.frame < 0 || command.frame <= frame else { break }
                strike(command)
                read += 1
            }
            var mono = 0.0
            var voiceIndex = 0
            while voiceIndex < voiceCount {
                let voice = voices.advanced(by: voiceIndex)
                if frame < voice.pointee.start {
                    voiceIndex += 1
                    continue
                }
                if voice.pointee.age >= voice.pointee.stopAge {
                    voiceCount -= 1
                    voices[voiceIndex] = voices[voiceCount]
                    continue
                }
                let age = voice.pointee.age
                let envelope: Double
                if Double(age) < voice.pointee.attackFrames {
                    envelope = voice.pointee.peak * Double(age) / voice.pointee.attackFrames
                } else if Double(age) >= voice.pointee.decayFrames {
                    envelope = 0.0001
                } else if age == voice.pointee.firstDecayAge {
                    envelope = voice.pointee.firstDecayEnvelope
                } else {
                    envelope = voice.pointee.envelope * voice.pointee.envelopeStep
                }
                voice.pointee.envelope = envelope
                mono += voice.pointee.sine * envelope
                let sine = voice.pointee.sine
                let cosine = voice.pointee.cosine
                voice.pointee.sine = sine * voice.pointee.cosineStep + cosine * voice.pointee.sineStep
                voice.pointee.cosine = cosine * voice.pointee.cosineStep - sine * voice.pointee.sineStep
                voice.pointee.age += 1
                voiceIndex += 1
            }
            let input = Float(mono) * 0.85
            let wet = reverb.process(input)
            left[index] = (input + wet.0 * 0.32) * 0.6
            right[index] = (input + wet.1 * 0.32) * 0.6
            dry?[index] = input * 0.6
            frame += 1
        }
        commandRead.store(read, ordering: .releasing)
    }

    private func strike(_ command: Command) {
        let first = command.event == Event.dang.rawValue ? 0 : 13
        let count = command.event == Event.dang.rawValue ? 13 : 4
        // The original creates unbounded oscillators. The native realtime pool is
        // deliberately bounded; the unlock choreography never approaches this limit.
        guard voiceCount + count <= Self.voiceCapacity else { return }
        let start = (command.frame < 0 ? frame : command.frame) + Int64(ceil(sampleRate * 0.01))
        for index in 0..<count {
            var voice = definitions[first + index]
            voice.start = start
            voices[voiceCount] = voice
            voiceCount += 1
        }
    }
}

private final class TutuBellFloatStorage {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int
    init(_ count: Int) {
        self.count = count
        pointer = .allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
    }
    deinit {
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }
}

/// Zero-latency nonuniform partitioning: taps 0...127 are direct FIR, taps
/// 128...1023 use 128-frame partitions, and the rest use 1024-frame partitions.
/// Each FFT tail starts one whole block into its IR, so it is completely computed
/// before its first output sample is needed; neither wet nor dry is delayed.
private final class TutuBellConvolution {
    private static let headSize = 128
    private let history = TutuBellFloatStorage(256)
    private let headLeft = TutuBellFloatStorage(128)
    private let headRight = TutuBellFloatStorage(128)
    private let early: TutuBellConvolutionTail
    private let late: TutuBellConvolutionTail
    private var cursor = 0

    init(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        for index in 0..<Self.headSize {
            headLeft.pointer[index] = left[Self.headSize - 1 - index]
            headRight.pointer[index] = right[Self.headSize - 1 - index]
        }
        early = TutuBellConvolutionTail(blockSize: 128, left: left + 128, right: right + 128, count: min(count, 1024) - 128)
        late = TutuBellConvolutionTail(blockSize: 1024, left: left + 1024, right: right + 1024, count: count - 1024)
    }

    func process(_ input: Float) -> (Float, Float) {
        history.pointer[cursor] = input
        history.pointer[cursor + Self.headSize] = input
        let samples = history.pointer + cursor + 1
        var left: Float = 0
        var right: Float = 0
        vDSP_dotpr(samples, 1, headLeft.pointer, 1, &left, vDSP_Length(Self.headSize))
        vDSP_dotpr(samples, 1, headRight.pointer, 1, &right, vDSP_Length(Self.headSize))
        cursor = (cursor + 1) % Self.headSize
        let earlyOutput = early.process(input)
        let lateOutput = late.process(input)
        return (left + earlyOutput.0 + lateOutput.0, right + earlyOutput.1 + lateOutput.1)
    }
}

/// Uniform overlap-add for an IR whose first tap is blockSize samples late.
/// Full complex FFTs keep DC/Nyquist scaling explicit and use vDSP for all the
/// partition multiply-adds. No pointer escapes and no storage changes in process.
private final class TutuBellConvolutionTail {
    private let blockSize: Int
    private let fftSize: Int
    private let fftLog2: vDSP_Length
    private let partitionCount: Int
    private let fft: FFTSetup
    private let kernelsLeftReal: TutuBellFloatStorage
    private let kernelsLeftImag: TutuBellFloatStorage
    private let kernelsRightReal: TutuBellFloatStorage
    private let kernelsRightImag: TutuBellFloatStorage
    private let inputReal: TutuBellFloatStorage
    private let inputImag: TutuBellFloatStorage
    private let accumulationReal: TutuBellFloatStorage
    private let accumulationImag: TutuBellFloatStorage
    private let productReal: TutuBellFloatStorage
    private let productImag: TutuBellFloatStorage
    private let outputLeft: TutuBellFloatStorage
    private let outputRight: TutuBellFloatStorage
    private let overlapLeft: TutuBellFloatStorage
    private let overlapRight: TutuBellFloatStorage
    private var sampleCursor = 0
    private var blockCursor = 0

    init(blockSize: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        self.blockSize = blockSize
        fftSize = blockSize * 2
        fftLog2 = vDSP_Length((blockSize * 2).trailingZeroBitCount)
        partitionCount = (count + blockSize - 1) / blockSize
        fft = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2))!
        let spectrumCount = partitionCount * fftSize
        kernelsLeftReal = TutuBellFloatStorage(spectrumCount)
        kernelsLeftImag = TutuBellFloatStorage(spectrumCount)
        kernelsRightReal = TutuBellFloatStorage(spectrumCount)
        kernelsRightImag = TutuBellFloatStorage(spectrumCount)
        inputReal = TutuBellFloatStorage(spectrumCount)
        inputImag = TutuBellFloatStorage(spectrumCount)
        accumulationReal = TutuBellFloatStorage(fftSize)
        accumulationImag = TutuBellFloatStorage(fftSize)
        productReal = TutuBellFloatStorage(fftSize)
        productImag = TutuBellFloatStorage(fftSize)
        outputLeft = TutuBellFloatStorage(blockSize)
        outputRight = TutuBellFloatStorage(blockSize)
        overlapLeft = TutuBellFloatStorage(blockSize)
        overlapRight = TutuBellFloatStorage(blockSize)
        for partition in 0..<partitionCount {
            let offset = partition * fftSize
            let available = min(blockSize, count - partition * blockSize)
            for index in 0..<available {
                kernelsLeftReal.pointer[offset + index] = left[partition * blockSize + index]
                kernelsRightReal.pointer[offset + index] = right[partition * blockSize + index]
            }
            var leftSpectrum = DSPSplitComplex(realp: kernelsLeftReal.pointer + offset, imagp: kernelsLeftImag.pointer + offset)
            var rightSpectrum = DSPSplitComplex(realp: kernelsRightReal.pointer + offset, imagp: kernelsRightImag.pointer + offset)
            vDSP_fft_zip(fft, &leftSpectrum, 1, fftLog2, FFTDirection(FFT_FORWARD))
            vDSP_fft_zip(fft, &rightSpectrum, 1, fftLog2, FFTDirection(FFT_FORWARD))
        }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func process(_ input: Float) -> (Float, Float) {
        let output = (outputLeft.pointer[sampleCursor], outputRight.pointer[sampleCursor])
        inputReal.pointer[blockCursor * fftSize + sampleCursor] = input
        sampleCursor += 1
        if sampleCursor == blockSize {
            finishBlock()
            sampleCursor = 0
        }
        return output
    }

    private func finishBlock() {
        let offset = blockCursor * fftSize
        vDSP_vclr(inputReal.pointer + offset + blockSize, 1, vDSP_Length(blockSize))
        vDSP_vclr(inputImag.pointer + offset, 1, vDSP_Length(fftSize))
        var spectrum = DSPSplitComplex(realp: inputReal.pointer + offset, imagp: inputImag.pointer + offset)
        vDSP_fft_zip(fft, &spectrum, 1, fftLog2, FFTDirection(FFT_FORWARD))
        convolve(real: kernelsLeftReal.pointer, imag: kernelsLeftImag.pointer, output: outputLeft.pointer, overlap: overlapLeft.pointer)
        convolve(real: kernelsRightReal.pointer, imag: kernelsRightImag.pointer, output: outputRight.pointer, overlap: overlapRight.pointer)
        blockCursor = (blockCursor + 1) % partitionCount
    }

    private func convolve(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>, output: UnsafeMutablePointer<Float>, overlap: UnsafeMutablePointer<Float>) {
        vDSP_vclr(accumulationReal.pointer, 1, vDSP_Length(fftSize))
        vDSP_vclr(accumulationImag.pointer, 1, vDSP_Length(fftSize))
        var accumulation = DSPSplitComplex(realp: accumulationReal.pointer, imagp: accumulationImag.pointer)
        var destination = accumulation
        var product = DSPSplitComplex(realp: productReal.pointer, imagp: productImag.pointer)
        for partition in 0..<partitionCount {
            let historyIndex = (blockCursor - partition + partitionCount) % partitionCount
            var input = DSPSplitComplex(realp: inputReal.pointer + historyIndex * fftSize, imagp: inputImag.pointer + historyIndex * fftSize)
            var kernel = DSPSplitComplex(realp: real + partition * fftSize, imagp: imag + partition * fftSize)
            vDSP_zvmul(&input, 1, &kernel, 1, &product, 1, vDSP_Length(fftSize), 1)
            vDSP_zvadd(&accumulation, 1, &product, 1, &destination, 1, vDSP_Length(fftSize))
        }
        vDSP_fft_zip(fft, &accumulation, 1, fftLog2, FFTDirection(FFT_INVERSE))
        var scale = Float(1) / Float(fftSize)
        vDSP_vsmul(accumulationReal.pointer, 1, &scale, accumulationReal.pointer, 1, vDSP_Length(fftSize))
        vDSP_vadd(accumulationReal.pointer, 1, overlap, 1, output, 1, vDSP_Length(blockSize))
        overlap.update(from: accumulationReal.pointer + blockSize, count: blockSize)
    }
}
#endif
#endif
