//
//  RootfsManager.swift
//  MemoryPalace — 搬自 OpenMinis src/ios/iSH/RootfsManager.swift（680 行 → 这份 ~180 行）
//  SPDX-License-Identifier: GPL-3.0-only
//  Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis), src/ios/iSH/RootfsManager.swift,
//  licensed under the GNU General Public License v3.0.
//  Modifications Copyright (C) 2026 Mneme Atrium contributors, also under GPL-3.0.
//  This file is GPL-3.0; it is combined with the AGPL-3.0 app under GPL-3.0 §13.
//
//  管 Alpine rootfs 的安装位置、架构标签、重置。只做这三件事：
//  解压 / 校验 / 删除。不碰 meta.db，不做覆盖层。
//
//  相对上游的差量见 docs/prompts/2026-08-26-sandbox-t0/reports/t1-report.md，
//  三条最重要的：
//    1. 安装位置 Documents/alpine-rootfs → Library/Application Support/MemoryPalace/sandbox/rootfs
//       （Documents 是文件库的家，且 .mpb 全量备份会扫 Documents）+ isExcludedFromBackup
//    2. 190 行手写 ZIP reader（Compression + compression_decode_buffer）删掉，换 ZIPFoundation
//    3. applyDefaultMountOverlay / ensureFakefsMetadata / /var/minis 预建目录全不搬
//       —— 那是 Minis 往 guest 里塞自家 Python CLI 和浏览器 wrapper 的通道，MP 不需要，
//       代价是 Swift 侧要直连 meta.db 写 SQLite（约 160 行）
//

import Foundation
import ZIPFoundation

enum RootfsError: LocalizedError {
    case bundleResourceMissing
    case archiveLayoutUnexpected(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing:
            return "app 里没有 alpine-rootfs.zip（构建时没打进 bundle）"
        case .archiveLayoutUnexpected(let detail):
            return "rootfs 压缩包结构不对：\(detail)"
        case .installFailed(let detail):
            return "rootfs 安装失败：\(detail)"
        }
    }
}

final class RootfsManager {
    static let shared = RootfsManager()

    /// 换 guest 架构时改这里；与磁盘上的 `.arch` 不一致就整个删掉重装
    private let currentArch = "aarch64"

    /// rootfs 内容版本。**改 prepare-rootfs.sh 的产物结构就要 +1**，否则老装机
    /// 因为 `.arch` 没变而不会重装，会带着旧 rootfs 跑（T3a 加 /mnt/library
    /// 挂载点时踩到：新 zip 里有、设备上那份没有，bind mount 会因为父目录不在
    /// meta.db 里而失败）。
    ///   v1 = T1 首版（去品牌 + resolv.conf 进 meta.db）
    ///   v2 = T3a（多一个空的 /mnt/library 挂载点）
    private let rootfsVersion = 2

    /// [重置后本进程不可再用] `ISHKernel` 每个进程只 boot 一次，`become_first_process()`
    /// 不可逆。reset 删掉 rootfs 后 kernel 仍然 `isBooted == true`，但它的 fakefs 挂在
    /// 一个已经不存在的目录上，下一次 executeCommand 会崩。所以重置在 app 内只能做成
    /// 「标记 + 要求重启」，做不成热重挂。本标志一旦置位，本进程内不再清除。
    private(set) var didResetWhileBooted = false

    private init() {}

    // MARK: - 路径

    /// `Library/Application Support/MemoryPalace/sandbox/`
    var sandboxRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("sandbox", isDirectory: true)
    }

    /// fakefs 根（含 `data/` 与 `meta.db`），传给 `ISHKernel.boot(withRootPath:)`
    var rootfsPath: URL { sandboxRoot.appendingPathComponent("rootfs", isDirectory: true) }

    var dataPath: URL { rootfsPath.appendingPathComponent("data", isDirectory: true) }

    /// 装好了才给路径；没装好返回 nil（挂载/清残留都不该对半成品动手）
    var rootfsPathIfInstalled: URL? { isInstalled ? rootfsPath : nil }

    private var metaDBPath: URL { rootfsPath.appendingPathComponent("meta.db") }

    private var archTagPath: URL { rootfsPath.appendingPathComponent(".arch") }

    private var versionTagPath: URL { rootfsPath.appendingPathComponent(".rootfs-version") }

    private var stagingPath: URL { sandboxRoot.appendingPathComponent("rootfs.staging", isDirectory: true) }

    // MARK: - 状态

    var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataPath.path), fm.fileExists(atPath: metaDBPath.path) else { return false }
        guard let tag = try? String(contentsOf: archTagPath, encoding: .utf8),
              tag.trimmingCharacters(in: .whitespacesAndNewlines) == currentArch else { return false }
        guard let ver = try? String(contentsOf: versionTagPath, encoding: .utf8),
              Int(ver.trimmingCharacters(in: .whitespacesAndNewlines)) == rootfsVersion else { return false }
        return true
    }

    // MARK: - 安装

    /// 幂等：已装好就秒返回 false；真装了返回 true。
    /// 解压到 staging 再整体 move —— 中途失败/被杀不会留下一个「看起来装好了」的半成品。
    @discardableResult
    func installIfNeeded(progress: ((String) -> Void)? = nil) throws -> Bool {
        let fm = FileManager.default

        // 目录在但标签不对（换过架构 / 上次装了一半）→ 整个删掉重来
        if fm.fileExists(atPath: rootfsPath.path) && !isInstalled {
            print("[RootfsManager] 架构/版本标签不符或安装不完整，删掉重装（\(currentArch) v\(rootfsVersion)）")
            try? fm.removeItem(at: rootfsPath)
        }

        guard !isInstalled else { return false }

        guard let zipURL = Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip") else {
            throw RootfsError.bundleResourceMissing
        }

        progress?("正在准备沙箱…")
        print("[RootfsManager] 从 \(zipURL.lastPathComponent) 安装 rootfs")

        try fm.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: stagingPath)
        try fm.createDirectory(at: stagingPath, withIntermediateDirectories: true)

        do {
            try fm.unzipItem(at: zipURL, to: stagingPath)
        } catch {
            try? fm.removeItem(at: stagingPath)
            throw RootfsError.installFailed("解压失败：\(error.localizedDescription)")
        }

        // zip 里是 `alpine-rootfs/{meta.db,data/}`（prepare-rootfs.sh 打的），
        // 但也认「顶层直接是 meta.db+data」的情况，免得换个打包方式就炸
        let source = try locateFakefsRoot(in: stagingPath)

        do {
            try? fm.removeItem(at: rootfsPath)
            try fm.moveItem(at: source, to: rootfsPath)
        } catch {
            try? fm.removeItem(at: stagingPath)
            throw RootfsError.installFailed("搬运失败：\(error.localizedDescription)")
        }
        try? fm.removeItem(at: stagingPath)

        try currentArch.write(to: archTagPath, atomically: true, encoding: .utf8)
        try String(rootfsVersion).write(to: versionTagPath, atomically: true, encoding: .utf8)
        excludeFromBackup(rootfsPath)

        print("[RootfsManager] 安装完成（\(currentArch)）→ \(rootfsPath.path)")
        return true
    }

    private func locateFakefsRoot(in staging: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.appendingPathComponent("meta.db").path) {
            return staging
        }
        let entries = (try? fm.contentsOfDirectory(atPath: staging.path))?
            .filter { $0 != "__MACOSX" && !$0.hasPrefix(".") } ?? []
        guard entries.count == 1 else {
            throw RootfsError.archiveLayoutUnexpected("顶层有 \(entries.count) 项：\(entries.prefix(5))")
        }
        let nested = staging.appendingPathComponent(entries[0], isDirectory: true)
        guard fm.fileExists(atPath: nested.appendingPathComponent("meta.db").path) else {
            throw RootfsError.archiveLayoutUnexpected("\(entries[0]) 下没有 meta.db")
        }
        return nested
    }

    /// rootfs 是可再生的构建产物（9.4 MB），别进 iCloud 备份
    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try mutable.setResourceValues(values)
        } catch {
            print("[RootfsManager] isExcludedFromBackup 设置失败（不致命）：\(error)")
        }
    }

    // MARK: - 重置

    /// 删掉 rootfs。**内核已 boot 时不能热重挂**——置 `didResetWhileBooted`，
    /// 调用方必须提示重启 app，且在重启前拒绝再起 guest。
    func reset() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: rootfsPath.path) {
            try fm.removeItem(at: rootfsPath)
            print("[RootfsManager] rootfs 已删除：\(rootfsPath.path)")
        }
        try? fm.removeItem(at: stagingPath)

        if ISHKernel.shared.isBooted {
            didResetWhileBooted = true
            print("[RootfsManager] ⚠️ 内核已 boot 时重置——本次启动内不能再起 guest，必须重启 app")
        }
    }
}
