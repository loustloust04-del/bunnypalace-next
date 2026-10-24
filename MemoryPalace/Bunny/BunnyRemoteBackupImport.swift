import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - [Bunny] 从私密链接下载全量备份包
//
// 背景：小兔用的重签证书下，系统文件选择器导入文件不可用。这里让 App 自己把 .mpb 下载进沙盒
// （Caches/BunnyDownloads/），再交回上游 GlobalImportSheet 原有的 peek → 确认 → staging 流程。
// 链接由用户粘贴，代码里不含任何地址或口令。只接受 https。

final class BunnyRemoteBackupDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var running = false
    @Published var received: Int64 = 0
    @Published var expected: Int64 = 0
    @Published var errorText: String?

    private var session: URLSession?
    private var completion: ((URL) -> Void)?
    private var suggestedName = "backup.mpb"

    static var downloadDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BunnyDownloads", isDirectory: true)
    }

    func start(_ raw: String, completion: @escaping (URL) -> Void) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            errorText = "链接不对：需要以 https:// 开头的完整地址"
            return
        }
        errorText = nil
        received = 0
        expected = 0
        running = true
        self.completion = completion
        suggestedName = url.lastPathComponent.isEmpty ? "backup.mpb" : url.lastPathComponent
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        let s = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session = s
        s.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        running = false
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        received = totalBytesWritten
        expected = max(totalBytesExpectedToWrite, 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // location 只在本回调内有效，必须同步挪走
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            errorText = "服务器返回 \(http.statusCode)（链接可能失效或写错）"
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.downloadDir, withIntermediateDirectories: true)
            if let old = try? fm.contentsOfDirectory(at: Self.downloadDir, includingPropertiesForKeys: nil) {
                for f in old { try? fm.removeItem(at: f) }   // 只留最新一份，避免大包堆积
            }
            let safeName = suggestedName.replacingOccurrences(of: "/", with: "_")
            let dst = Self.downloadDir.appendingPathComponent(safeName)
            try fm.moveItem(at: location, to: dst)
            let done = completion
            completion = nil
            done?(dst)
        } catch {
            errorText = "保存下载文件失败：\(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        running = false
        if let error, (error as NSError).code != NSURLErrorCancelled {
            errorText = "下载失败：\(error.localizedDescription)"
        }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}

struct BunnyRemoteImportRow: View {
    let onDownloaded: (URL) -> Void
    @StateObject private var downloader = BunnyRemoteBackupDownloader()
    @State private var link = ""

    private static let bytes = ByteCountFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("或者：从链接下载（文件选择器用不了时）")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
            HStack(spacing: 8) {
                TextField("粘贴 https:// 下载链接", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                #if os(iOS)
                Button("粘贴") { link = UIPasteboard.general.string ?? link }
                    .buttonStyle(.bordered)
                #endif
            }
            if downloader.running {
                VStack(alignment: .leading, spacing: 4) {
                    if downloader.expected > 0 {
                        ProgressView(value: Double(downloader.received), total: Double(downloader.expected))
                    } else {
                        ProgressView()
                    }
                    HStack {
                        Text("已下载 \(Self.bytes.string(fromByteCount: downloader.received))"
                             + (downloader.expected > 0 ? " / \(Self.bytes.string(fromByteCount: downloader.expected))" : ""))
                        Spacer()
                        Button("取消") { downloader.cancel() }
                    }
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                }
            } else {
                Button {
                    downloader.start(link, completion: onDownloaded)
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                        Text("下载并导入").font(.system(size: 15, weight: .medium))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent))
                    .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let e = downloader.errorText {
                Text(e).font(.caption).foregroundColor(.red)
            }
        }
    }
}
