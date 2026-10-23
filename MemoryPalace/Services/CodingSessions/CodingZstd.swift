#if os(macOS)
import Foundation
import libzstd

/// zstd 多帧流解压（dsh 默认落盘：首帧 header 行、之后每次 append 一帧，帧直接连接）：`ZSTD_decompressStream` 一路解到输入耗尽，
/// 自动跨帧。读完输入时解码器仍停在帧中间 = 末帧半写（写端每次 append 一帧，与扫描天然并发）或坏数据：交出已解出的部分 + torn，
/// 由调用方收尾——不能「再读一次」，Wake 记下的死循环就是这么来的
enum CodingZstd {
    /// 解出上限：坏文件 / 解压炸弹不能把进程内存打满，超出按 torn 收尾
    static let maxOutput = 512 * 1024 * 1024

    static func decompress(_ compressed: Data, stopAtFirstLine: Bool = false) -> (data: Data, torn: Bool) {
        guard let stream = ZSTD_createDStream() else { return (Data(), true) }
        defer { ZSTD_freeDStream(stream) }
        let chunk = ZSTD_DStreamOutSize()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var out = Data()
        // 上一次调用的返回值：0 = 刚好收完一帧，>0 = 帧还没完
        var pending = 0
        let torn = compressed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            while input.pos < input.size {
                let ret = buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                    var output = ZSTD_outBuffer(dst: dst.baseAddress, size: chunk, pos: 0)
                    let ret = ZSTD_decompressStream(stream, &output, &input)
                    if ZSTD_isError(ret) == 0, output.pos > 0, let base = dst.baseAddress {
                        out.append(base.assumingMemoryBound(to: UInt8.self), count: output.pos)
                    }
                    return ret
                }
                if ZSTD_isError(ret) != 0 || out.count > maxOutput { return true }
                pending = ret
                if stopAtFirstLine, out.contains(0x0A) { return false }
            }
            return pending != 0
        }
        return (out, torn)
    }
}
#endif
