import Foundation

/// 记录行的纯字符串操作（原 app `CatalogSources.split / fingerprint / label`）。
/// 包内 `RecallWikiReader` 读记录行只靠这几个函数，不碰 app 的 `CatalogSources` 实例面；
/// app 的同名函数保留为一行转发，调用点与落盘（cursor JSON）不动。
public enum CatalogRecordLine {
    /// 问卷答案路径前缀（原 `CatalogSurvey.prefix`）。
    public static let surveyPrefix = "问卷/"
    /// 问卷层名（原 `CatalogSurvey.layer`）。
    public static let surveyLayer = "问卷"

    /// 碎片编号标签：`碎片 <uuid 前 8 位小写>`。
    public static func fragmentLabel(_ fragment: UUID) -> String {
        "碎片 \(fragment.uuidString.prefix(8).lowercased())"
    }

    /// 一条记录行的出处标签（原 `CatalogSources.label(_ cite:)` 与 `CatalogSurvey.label(_ cite:)` 的字符串逻辑）。
    /// `day` 只对问卷层有意义；`RecallWikiReader` 构造出处时不带 day，传 nil。
    public static func citeLabel(layer: String, filePath: String?, name: String?, day: String?) -> String {
        let path = filePath ?? ""
        switch layer {
        case "Prompt": return "Prompt \(name ?? path)"
        case "wiki":
            if let page = CatalogSeedMaterials.pagePath(path) { return "wiki " + page }
            if let folder = CatalogSeedMaterials.indexFolder(path) { return folder.isEmpty ? "wiki 根索引" : "wiki \(folder) 索引" }
            return "wiki " + path
        case surveyLayer:
            let task = path.split(separator: "/").last.map { String($0.prefix(8)) } ?? ""
            return "问卷「\(name ?? "")」\(day ?? "")#\(task)"
        default: return "\(layer) \(path)"
        }
    }

    public static func fingerprint(_ line: String) -> String {
        String(WikiStore.version(of: Data(line.utf8)).prefix(12))
    }

    /// 一行记录拆成正文和出处：旧「（出处：…）」或种子「（path）」；没有出处 = nil。
    public static func split(_ line: String) -> (body: String, labels: [String]?) {
        guard line.hasSuffix("）") else { return (line, nil) }
        if let open = line.range(of: "（出处：", options: .backwards) {
            return (String(line[..<open.lowerBound]), line[open.upperBound..<line.index(before: line.endIndex)].components(separatedBy: "；"))
        }
        var depth = 0
        for index in line.indices.reversed() {
            if line[index] == "）" { depth += 1 }
            if line[index] == "（" {
                depth -= 1
                if depth == 0 {
                    let path = String(line[line.index(after: index)..<line.index(before: line.endIndex)])
                    guard path.hasPrefix("memory/") || path.hasPrefix(surveyPrefix) else { break }
                    return (String(line[..<index]), [path])
                }
            }
        }
        return (line, nil)
    }
}
