import Foundation
import CryptoKit

// MARK: - Canonical Section sha256 (codex Round 3 强烈建议 #5+#6)
//
// 跨平台一致的目录 hash 算法。用于 manifest.sections[*].sha256，staging 前校验包完整。
//
// 算法（见 docs/plan-global-export.md v4 §1.2）：
//   1. 递归枚举 section 内所有文件
//   2. 过滤 .DS_Store / __MACOSX/ / .git*
//   3. symlink 直接抛错（v1 拒绝 symlink）
//   4. 非 regular file（device/pipe/socket）跳过
//   5. 路径转 POSIX 相对路径 + Unicode NFC 规范化
//   6. NFC 后检查重复 → 抛错
//   7. 按 NFC 路径 UTF-8 字节升序
//   8. 对每个文件依次喂 hash：path bytes + 0x00 + size UInt64 BE + 0x00 + file bytes（流式）
//   9. 空目录 v1 忽略；业务需要保留 → .keep 占位文件参与 hash
//  10. xattr / resource fork v1 不参与
//
// 为什么不用 ZIP CRC：CRC 不是抗篡改 hash（codex Round 3 #5）。
// 为什么自己定不用 git tree：v1 足够；v1.5 可升级 git tree 风格。

enum SectionHasher {

    enum HasherError: LocalizedError {
        case symlinkRejected(URL)
        case duplicatePathAfterNFC(String, [URL])
        case ioFailed(URL, Error)

        var errorDescription: String? {
            switch self {
            case .symlinkRejected(let url):
                return "拒绝 symlink: \(url.lastPathComponent)"
            case .duplicatePathAfterNFC(let path, let urls):
                return "NFC 规范化后路径重复: \(path) ← \(urls.map(\.path).joined(separator: ", "))"
            case .ioFailed(let url, let err):
                return "读 \(url.lastPathComponent) 失败: \(err.localizedDescription)"
            }
        }
    }

    /// 对一个目录算 canonical sha256 + 总字节数。
    /// `root` 是 section 根目录；返回 (hex, totalBytes)。
    static func hash(directory root: URL) throws -> (sha256: String, bytes: Int) {
        let entries = try enumerate(root: root)
        var hasher = SHA256()
        var totalBytes = 0

        for entry in entries {
            // path bytes + 0x00
            let pathBytes = Array(entry.normalizedRelativePath.utf8)
            hasher.update(data: Data(pathBytes))
            hasher.update(data: Data([0x00]))

            // size UInt64 BE + 0x00
            var sizeBE = UInt64(entry.bytes).bigEndian
            hasher.update(data: Data(bytes: &sizeBE, count: 8))
            hasher.update(data: Data([0x00]))

            // file bytes（流式 64KB chunk）
            try streamFile(at: entry.url, into: &hasher)
            totalBytes += entry.bytes
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, totalBytes)
    }

    // MARK: - Helpers

    private struct FileEntry {
        let url: URL
        let normalizedRelativePath: String  // NFC POSIX 相对路径
        let bytes: Int
    }

    private static let excludedNames: Set<String> = [".DS_Store"]
    private static let excludedPrefixes: [String] = ["__MACOSX/", ".git"]

    private static func enumerate(root: URL) throws -> [FileEntry] {
        let fm = FileManager.default
        // 注意：**不能**用 .skipsHiddenFiles —— filelibrary 的 `.memorypalace/manifest.json`
        // 是业务数据隐藏目录，必须参与 hash。`.DS_Store` 由 excludedNames 单独处理；
        // `.git*` 由 excludedPrefixes 处理。
        // bug history: 验收 1 抓到 — filelibrary section sha256=e3b0c44298(空集合)，但
        // stats.filesystemFileCount=8（含 .memorypalace 文件）→ hash 实际跳过这些隐藏文件
        // → 完整性校验对它们失效。
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }

        let rootPath = root.standardizedFileURL.path
        var pathToURL: [String: URL] = [:]
        var entries: [FileEntry] = []

        while let url = enumerator.nextObject() as? URL {
            let std = url.standardizedFileURL
            let rel = String(std.path.dropFirst(rootPath.count + 1))  // 去掉 root + "/"

            // 过滤
            if Self.excludedNames.contains(std.lastPathComponent) { continue }
            if Self.excludedPrefixes.contains(where: { rel.hasPrefix($0) }) { continue }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            } catch {
                throw HasherError.ioFailed(url, error)
            }

            if values.isSymbolicLink == true {
                throw HasherError.symlinkRejected(url)
            }
            guard values.isRegularFile == true else {
                // 非 regular file (device/pipe/socket) 跳过
                continue
            }

            // NFC 规范化
            let nfcRel = rel.precomposedStringWithCanonicalMapping

            if let prior = pathToURL[nfcRel] {
                throw HasherError.duplicatePathAfterNFC(nfcRel, [prior, url])
            }
            pathToURL[nfcRel] = url

            entries.append(FileEntry(
                url: url,
                normalizedRelativePath: nfcRel,
                bytes: values.fileSize ?? 0
            ))
        }

        // 按 NFC 路径 UTF-8 字节升序
        entries.sort { lhs, rhs in
            lhs.normalizedRelativePath.utf8.lexicographicallyPrecedes(rhs.normalizedRelativePath.utf8)
        }

        return entries
    }

    private static func streamFile(at url: URL, into hasher: inout SHA256) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw HasherError.ioFailed(url, error)
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw HasherError.ioFailed(url, error)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
    }
}
