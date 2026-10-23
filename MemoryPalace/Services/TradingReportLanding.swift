#if PERSONAL_APPS
import Foundation
import SwiftData

extension Notification.Name {
    /// 研报到货（userInfo: symbol/ok/error?）——档案页/面板刷新。
    static let tradingReportArrived = Notification.Name("tradingReportArrived")
    /// 研究进度心跳（userInfo: symbol/stage/label）。
    static let tradingResearchProgress = Notification.Name("tradingResearchProgress")
}

/// trading_report_result 帧落地：双端分流（拍板：全文放电脑、手机放裁决）。
/// Mac 与 hub 同机 → 优先按 full_path 读全文；iPhone/读不到 → 用帧里的裁决版。
enum TradingReportLanding {

    /// 返回 true = 处理成功（WS client 才 ack）。失败帧（ok:false）只发通知解锁按钮，也算处理成功。
    /// context 传入时：报告到达自动加入关注列表（没有入口的报告=看不见，粟粟 08-02 实锤）。
    @MainActor
    static func handle(_ payload: [String: Any], profileId: String, context: ModelContext? = nil) -> Bool {
        guard let symbol = payload["symbol"] as? String, !symbol.isEmpty else { return false }
        let ok = (payload["ok"] as? Bool) ?? false

        defer {
            NotificationCenter.default.post(
                name: .tradingReportArrived, object: nil,
                userInfo: ["symbol": symbol, "ok": ok,
                           "error": (payload["error"] as? String) ?? ""]
            )
        }

        guard ok else { return true }
        guard !profileId.isEmpty,
              let filename = payload["filename"] as? String, !filename.isEmpty,
              filename.hasSuffix(".md"), !filename.contains("/") else { return false }

        var content = payload["content"] as? String ?? ""
        #if os(macOS)
        if let fullPath = payload["full_path"] as? String, !fullPath.isEmpty,
           let full = try? String(contentsOfFile: fullPath, encoding: .utf8), !full.isEmpty {
            content = full
        }
        #endif
        guard !content.isEmpty else { return false }

        do {
            try FileLibraryStore.write("trading/\(symbol)/\(filename)", content: content, profileId: profileId)
        } catch {
            return false   // 不 ack，等补投重试
        }

        // 财报书架素材（earnings 帧带 filing 时）：按原生格式分流进已有共读管线（粟粟拍的不转换）
        if let context, let filing = payload["filing"] as? [String: Any] {
            importFilingBook(filing, symbol: symbol, profileId: profileId, context: context)
        } else if (payload["filing_too_large"] as? Bool) == true {
            // hub 侧闸门降级帧：报告本体已落，PDF 原件留在 Mac 磁盘（full_path）
            ToastCenter.shared.show("\(symbol) 财报文件过大，本次未进书架（原件在 Mac）")
        }

        // 自动加入关注列表：报告到了面板就得有它的行（入口），词典逻辑闭环
        if let context {
            let sym = symbol
            var desc = FetchDescriptor<TickerEntry>(
                predicate: #Predicate<TickerEntry> { $0.profileId == profileId && $0.symbol == sym })
            desc.fetchLimit = 1
            if ((try? context.fetch(desc))?.first) == nil {
                context.insert(TickerEntry(profileId: profileId, symbol: sym))
                try? context.save()
                TradingStore.reportWatchlist(context: context, profileId: profileId)
            }
        }

        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
        return true
    }

    /// 财报进书架：pdf → CR-7 PDF 链；txt → txt 共读链。失败只 toast 不挡 ack（报告本体已落）。
    @MainActor
    private static func importFilingBook(_ filing: [String: Any], symbol: String,
                                         profileId: String, context: ModelContext) {
        guard let filename = filing["filename"] as? String, !filename.contains("/"),
              let format = filing["format"] as? String,
              let b64 = filing["data"] as? String,
              let data = Data(base64Encoded: b64), !data.isEmpty else { return }
        var bookName = (filing["book_name"] as? String) ?? filename
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("filing-\(UUID().uuidString)")
            .appendingPathExtension(format == "pdf" ? "pdf" : "txt")
        do {
            try data.write(to: tmp)
        } catch { return }
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: tmp) }
            for attempt in 0..<2 {
                do {
                    if format == "pdf" {
                        _ = try await BookImporter.importPDF(url: tmp, bookName: bookName,
                                                             profileId: profileId, context: context)
                    } else {
                        _ = try await BookImporter.importTxt(url: tmp, bookName: bookName,
                                                             profileId: profileId, context: context)
                    }
                    ToastCenter.shared.show("📚 财报已进书架：\(bookName)")
                    return
                } catch {
                    // 重名（同季重跑）→ 书名加时间后缀再试一次
                    if attempt == 0 {
                        let stamp = Date().formatted(.dateTime.month().day().hour().minute())
                        bookName = "\(bookName)（\(stamp)）"
                        continue
                    }
                    ToastCenter.shared.show("财报进书架失败：\(error.localizedDescription)")
                }
            }
        }
    }
}
#endif
