import Foundation

public enum CatalogSeedTools {
    /// 按 generatedRecords 格式剥第二段恰为「设定」「待判」的机械标记；其他来源的记录若正文恰以此开头也会被剥，接受。
    public static func recordIndexText(_ record: String) -> String {
        guard let first = record.range(of: " · "),
              let second = record.range(of: " · ", range: first.upperBound..<record.endIndex) else { return record }
        let marker = record[first.upperBound..<second.lowerBound]
        guard marker == "设定" || marker == "待判" else { return record }
        return String(record[..<first.upperBound]) + record[second.upperBound...]
    }
}
