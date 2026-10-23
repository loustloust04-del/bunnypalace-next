import Foundation
import Compression

enum TwitterZipError: Error, Equatable {
    case notAZip
    case corrupt(String)
    case unsupportedMethod(UInt16)
    /// 条目路径想写到目标目录外面（`..` / 绝对路径）
    case unsafePath(String)
}

/// 推特导出包专用的解压器。
///
/// **为什么不用 ZIPFoundation**：推特的包每个条目都走 ZIP64（头里大小/偏移全填 0xFFFFFFFF，
/// 真值放扩展字段），而第一个条目 `data/` 的真实偏移是 0。ZIPFoundation 0.9.20 把扩展字段里的
/// 0 当成「没填」，退回 0xFFFFFFFF，第一个条目就读不到，遍历直接结束——读出 0 个文件、也不报错。
/// 粟粟的真存档 2026-09-24 就是这么导不进来的。夹具见 `scripts/make-twitter-zip-fixtures.py`。
///
/// 只实现推特包用得到的：stored / deflate、ZIP64、数据描述符。整个文件走内存映射，
/// 几百 MB 的包也不会整块读进内存。
enum TwitterZipExtractor {

    /// 导入需要的条目：推文/账号/资料几个 js + 推文媒体 + 头像横幅。
    /// **白名单**：私信正文（direct-messages.js）、私信媒体、IP 记录这些绝不解出来——
    /// 用不上，而且落到磁盘上就多一份隐私风险。包外面再套一层文件夹也认。
    static func neededForImport(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        // 从 X 拉的包（Mac 上 scripts/twitter-pull.py 出的）：清单 + 平铺的媒体目录
        if parts.last == TwitterPullImporter.manifestName { return true }
        if parts.count >= 2, parts[parts.count - 2] == TwitterPullImporter.mediaDirName { return true }
        guard let i = parts.firstIndex(of: "data") else { return false }
        let rest = Array(parts[(i + 1)...])
        if rest.count == 1 {
            let name = rest[0]
            return ["tweets.js", "account.js", "profile.js", "note-tweet.js"].contains(name)
                || (name.hasPrefix("tweets-part") && name.hasSuffix(".js"))
        }
        if rest.count == 2 { return ["tweets_media", "profile_media"].contains(rest[0]) }
        return false
    }

    /// 解到 `dest`。`include` 决定要哪些条目（传完整条目路径）；目录条目不单独建，随文件建。
    ///
    /// `budget`（#043 导出包导入用）：在分配内存前按目录里的声明值检查条目数 / 大小 / 压缩比，
    /// 多个包共用一个预算。推特这边不传，行为不变。
    static func extract(_ zip: URL, to dest: URL, include: (String) -> Bool = { _ in true },
                        budget: ZipExtractBudget? = nil,
                        onProgress: ((Double) -> Void)? = nil) throws {
        let data: Data
        do { data = try Data(contentsOf: zip, options: .alwaysMapped) } catch { throw TwitterZipError.notAZip }
        let r = Reader(data: data)
        let entries = try r.centralDirectory(maxEntries: budget?.limits.maxEntries)

        // 先整体过一遍路径：一条可疑就整包拒绝，不留半截
        for e in entries where !isSafe(e.name) { throw TwitterZipError.unsafePath(e.name) }

        let wanted = entries.filter { !$0.name.hasSuffix("/") && include($0.name) }
        if let budget {
            for e in wanted {
                try budget.charge(name: e.name, method: e.method,
                                  compressed: e.compressedSize, uncompressed: e.uncompressedSize)
            }
        }
        // 每条压缩大小在目录解析时已限制在包长以内，这里再饱和相加防溢出
        let total = max(1, wanted.reduce(UInt64(0)) { sum, e in
            let (v, overflow) = sum.addingReportingOverflow(e.compressedSize)
            return overflow ? .max : v
        })
        var done: UInt64 = 0
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        for e in wanted {
            try autoreleasepool {
                let body = try r.contents(of: e)
                let target = dest.appendingPathComponent(e.name)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: target)
            }
            done += e.compressedSize
            onProgress?(Double(done) / Double(total))
        }
        onProgress?(1)
    }

    /// 只把一个条目读进内存、不落盘（导入源里带密钥的配置只取一两个字段用）。没有这个条目返回 nil。
    static func readEntry(_ zip: URL, name: String, maxBytes: UInt64) throws -> Data? {
        let data: Data
        do { data = try Data(contentsOf: zip, options: .alwaysMapped) } catch { throw TwitterZipError.notAZip }
        let r = Reader(data: data)
        guard let e = try r.centralDirectory().first(where: { $0.name == name }) else { return nil }
        guard e.uncompressedSize <= maxBytes else { throw ZipLimitError.entryTooLarge(name) }
        // stored 条目按压缩区原样返回：两个大小不一致就是谎报，别把压缩区整段读进内存
        guard e.method != 0 || e.compressedSize == e.uncompressedSize else { throw ZipLimitError.inconsistent(name) }
        return try r.contents(of: e)
    }

    /// 列条目（#050：ChatGPT 的 Files / Dall-E 分卷不解开，只建索引，写库时按条目读）。路径不安全的整包拒绝
    static func listEntries(_ zip: URL, maxEntries: Int?) throws -> [Entry] {
        let data: Data
        do { data = try Data(contentsOf: zip, options: .alwaysMapped) } catch { throw TwitterZipError.notAZip }
        let entries = try Reader(data: data).centralDirectory(maxEntries: maxEntries)
        for e in entries where !isSafe(e.name) { throw TwitterZipError.unsafePath(e.name) }
        return entries.filter { !$0.name.hasSuffix("/") }
    }

    /// 按 `listEntries` 给的条目读进内存
    static func readEntry(_ zip: URL, entry: Entry, maxBytes: UInt64) throws -> Data {
        guard entry.uncompressedSize <= maxBytes else { throw ZipLimitError.entryTooLarge(entry.name) }
        let data: Data
        do { data = try Data(contentsOf: zip, options: .alwaysMapped) } catch { throw TwitterZipError.notAZip }
        let body = try Reader(data: data).contents(of: entry)
        // stored 条目直接返回压缩体：声明的解压大小撒谎就绕过上限（sol #9）
        guard UInt64(body.count) == entry.uncompressedSize else { throw ZipLimitError.inconsistent(entry.name) }
        return body
    }

    private static func isSafe(_ name: String) -> Bool {
        if name.hasPrefix("/") || name.hasPrefix("\\") { return false }
        return !name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    // MARK: - 读包

    struct Entry: Hashable {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private struct Reader {
        let data: Data
        private static let max32: UInt64 = 0xFFFF_FFFF

        private func u16(_ o: Int) throws -> UInt16 {
            guard o >= 0, o + 2 <= data.count else { throw TwitterZipError.corrupt("越界 @\(o)") }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }.littleEndian
        }
        private func u32(_ o: Int) throws -> UInt32 {
            guard o >= 0, o + 4 <= data.count else { throw TwitterZipError.corrupt("越界 @\(o)") }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian
        }
        /// 64 位声明值转 Int：畸形包给的超大值抛错，不 trap
        private func int(_ v: UInt64) throws -> Int {
            guard let i = Int(exactly: v), i <= data.count else { throw TwitterZipError.corrupt("数值越界 \(v)") }
            return i
        }

        private func u64(_ o: Int) throws -> UInt64 {
            guard o >= 0, o + 8 <= data.count else { throw TwitterZipError.corrupt("越界 @\(o)") }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }.littleEndian
        }

        /// 从尾部找目录结束记录；有 ZIP64 定位器就以 ZIP64 记录为准。
        /// `maxEntries`：目录里的条目总数上限（含不解压的），在建数组之前查
        func centralDirectory(maxEntries: Int? = nil) throws -> [Entry] {
            guard data.count >= 22 else { throw TwitterZipError.notAZip }
            var eocd = -1
            var i = data.count - 22
            let floor = max(0, data.count - 22 - 0xFFFF)   // 注释最长 64K
            while i >= floor {
                if try u32(i) == 0x0605_4B50 { eocd = i; break }
                i -= 1
            }
            guard eocd >= 0 else { throw TwitterZipError.notAZip }

            var count = UInt64(try u16(eocd + 10))
            var cdOffset = UInt64(try u32(eocd + 16))
            if eocd >= 20, try u32(eocd - 20) == 0x0706_4B50 {
                let z64 = try int(try u64(eocd - 20 + 8))
                guard try u32(z64) == 0x0606_4B50 else { throw TwitterZipError.corrupt("ZIP64 记录签名不对") }
                count = try u64(z64 + 32)
                cdOffset = try u64(z64 + 48)
            }

            // 每条目录项至少 46 字节，声明的条目数比这还多就是坏包
            guard count <= UInt64(data.count / 46) else { throw TwitterZipError.corrupt("条目数越界 \(count)") }
            if let maxEntries, count > UInt64(maxEntries) { throw ZipLimitError.tooManyEntries(maxEntries) }
            var entries: [Entry] = []
            entries.reserveCapacity(Int(count))
            var p = try int(cdOffset)
            for _ in 0..<count {
                guard try u32(p) == 0x0201_4B50 else { throw TwitterZipError.corrupt("目录条目签名不对 @\(p)") }
                let method = try u16(p + 10)
                var csize = UInt64(try u32(p + 20))
                var usize = UInt64(try u32(p + 24))
                let nlen = Int(try u16(p + 28))
                let xlen = Int(try u16(p + 30))
                let clen = Int(try u16(p + 32))
                var offset = UInt64(try u32(p + 42))
                guard p + 46 + nlen <= data.count else { throw TwitterZipError.corrupt("文件名越界") }
                let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nlen)],
                                  as: UTF8.self)

                // ZIP64 扩展字段：**只有**头里填了 0xFFFFFFFF 的那几项才在里面，按固定顺序。
                // 这里的 0 是真值（首条偏移就是 0），不能当「没填」——ZIPFoundation 就栽在这。
                var x = p + 46 + nlen
                let xEnd = x + xlen
                while x + 4 <= xEnd {
                    let id = try u16(x), size = Int(try u16(x + 2))
                    if id == 0x0001 {
                        var f = x + 4
                        if usize == Self.max32 { usize = try u64(f); f += 8 }
                        if csize == Self.max32 { csize = try u64(f); f += 8 }
                        if offset == Self.max32 { offset = try u64(f) }
                    }
                    x += 4 + size
                }
                // 压缩数据和本地头都得在包里：畸形值在这里拦下，后面求和 / 取数据不会越界或溢出
                guard csize <= UInt64(data.count), offset <= UInt64(data.count) else {
                    throw TwitterZipError.corrupt("条目大小 / 偏移越界：\(name)")
                }
                entries.append(Entry(name: name, method: method, compressedSize: csize,
                                     uncompressedSize: usize, localHeaderOffset: offset))
                p += 46 + nlen + xlen + clen
            }
            return entries
        }

        /// 取一个条目解压后的内容。大小以目录里的为准（推特的本地头里大小全是占位）。
        func contents(of e: Entry) throws -> Data {
            let lh = try int(e.localHeaderOffset)
            guard try u32(lh) == 0x0403_4B50 else { throw TwitterZipError.corrupt("本地头签名不对：\(e.name)") }
            let start = lh + 30 + Int(try u16(lh + 26)) + Int(try u16(lh + 28))
            let (end, overflow) = start.addingReportingOverflow(try int(e.compressedSize))
            guard !overflow, end <= data.count else { throw TwitterZipError.corrupt("数据越界：\(e.name)") }
            let packed = data[(data.startIndex + start)..<(data.startIndex + end)]

            switch e.method {
            case 0:
                return Data(packed)
            case 8:
                guard let want = Int(exactly: e.uncompressedSize) else { throw TwitterZipError.corrupt("解压大小越界：\(e.name)") }
                if want == 0 { return Data() }
                var out = Data(count: want)
                // COMPRESSION_ZLIB 就是裸 deflate（RFC 1951），正是 zip 里的格式
                let n = out.withUnsafeMutableBytes { dst in
                    packed.withUnsafeBytes { src in
                        compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, want,
                                                  src.bindMemory(to: UInt8.self).baseAddress!, packed.count,
                                                  nil, COMPRESSION_ZLIB)
                    }
                }
                guard n == want else { throw TwitterZipError.corrupt("解压长度不对：\(e.name)") }
                return out
            default:
                throw TwitterZipError.unsupportedMethod(e.method)
            }
        }
    }
}

// MARK: - 解包预算（#043）
/// 解包上限（#043 plan §2.5）。按中央目录里的声明值在**分配内存之前**检查。
struct ZipExtractLimits {
    var maxEntries: Int
    var maxEntryBytes: UInt64
    var maxTotalBytes: UInt64
    /// deflate 条目「解压 / 压缩」的上限倍数（zip bomb）
    var maxRatio: UInt64
}

/// 一次导入共用的预算：多选的几个包累计算
final class ZipExtractBudget {
    let limits: ZipExtractLimits
    private(set) var usedEntries = 0
    private(set) var usedBytes: UInt64 = 0

    init(_ limits: ZipExtractLimits) { self.limits = limits }

    func charge(name: String, method: UInt16, compressed: UInt64, uncompressed: UInt64) throws {
        usedEntries += 1
        guard usedEntries <= limits.maxEntries else { throw ZipLimitError.tooManyEntries(limits.maxEntries) }
        guard uncompressed <= limits.maxEntryBytes else { throw ZipLimitError.entryTooLarge(name) }
        if method == 0 {
            guard compressed == uncompressed else { throw ZipLimitError.inconsistent(name) }
        } else if uncompressed > 0 {
            guard compressed > 0, uncompressed / compressed <= limits.maxRatio else { throw ZipLimitError.ratio(name) }
        }
        let (sum, overflow) = usedBytes.addingReportingOverflow(uncompressed)
        guard !overflow, sum <= limits.maxTotalBytes else { throw ZipLimitError.totalTooLarge }
        usedBytes = sum
    }

    /// 不是 zip 条目的普通文件（文件夹里的、直接选中的）照样计入同一份预算
    func chargeFile(name: String, bytes: UInt64) throws {
        try charge(name: name, method: 0, compressed: bytes, uncompressed: bytes)
    }
}

enum ZipLimitError: Error, Equatable, CustomStringConvertible {
    case tooManyEntries(Int)
    case entryTooLarge(String)
    case totalTooLarge
    case ratio(String)
    case inconsistent(String)

    var description: String {
        switch self {
        case .tooManyEntries(let n): return "文件数超过 \(n) 个"
        case .entryTooLarge(let name): return "「\((name as NSString).lastPathComponent)」解压后超过 2 GB"
        case .totalTooLarge: return "解压后总共超过 4 GB"
        case .ratio(let name): return "「\((name as NSString).lastPathComponent)」压缩比异常"
        case .inconsistent(let name): return "「\((name as NSString).lastPathComponent)」大小对不上"
        }
    }
}
