import Foundation
import NaturalLanguage

public enum MemoryBM25 {
    public static func tokens(_ text: String) -> [String] {
        let text = SearchTextSegmenter.normalized(text)
        var words: [String] = []
        var previous: Unicode.Scalar?
        var needsWordTokenizer = false
        // 汉字取相邻双字，不依赖词典切专名；不生成单字，也不跨空格、标点拼接。
        for scalar in text.unicodeScalars {
            if scalar.properties.isIdeographic {
                if let previous {
                    var pair = String(previous)
                    pair.unicodeScalars.append(scalar)
                    words.append(pair)
                }
                previous = scalar
            } else {
                previous = nil
                if !needsWordTokenizer && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil) {
                    needsWordTokenizer = true
                }
            }
        }
        guard needsWordTokenizer else { return words }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range]
            if word.count >= 2 && !word.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) {
                words.append(String(word))
            }
            return true
        }
        return words
    }

    public static func document(content: String, keywords: [String]) -> [String] {
        let keys = keywords.flatMap { tokens($0) }
        return tokens(content) + keys + keys
    }

    public static func scores(documents: [[String]], query: String, cancel: CatalogCancel? = nil) -> [Double] {
        guard !documents.isEmpty else { return [] }
        var groups: [(terms: Set<String>, requiresAll: Bool, dropsCommon: Bool)] = []
        for segment in SearchTextSegmenter.catalogTerms([query]) {
            let han = segment.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
            let terms: Set<String> = han ? Set(tokens(segment)) : (segment.count >= 2 ? [segment] : [])
            guard !terms.isEmpty else { continue }
            groups.append((terms, han && (3...6).contains(segment.count),
                           han && segment.count >= 7 && documents.count >= 20))
        }
        guard !groups.isEmpty else { return Array(repeating: 0, count: documents.count) }
        let k1 = 1.2
        let b = 0.75
        let n = Double(documents.count)
        var df: [String: Int] = [:]
        for doc in documents {
            if cancel?.isCancelled == true { return [] }
            for term in Set(doc) { df[term, default: 0] += 1 }
        }
        for index in groups.indices where groups[index].dropsCommon {
            groups[index].terms = groups[index].terms.filter { Double(df[$0, default: 0]) <= n * 0.5 }
        }
        groups.removeAll { $0.terms.isEmpty }
        guard !groups.isEmpty else { return Array(repeating: 0, count: documents.count) }
        let avgLen = max(1.0, Double(documents.reduce(0) { $0 + $1.count }) / n)
        var scores: [Double] = []
        scores.reserveCapacity(documents.count)
        var tf: [String: Int] = [:]
        var matchedTerms = Set<String>()
        for doc in documents {
            if cancel?.isCancelled == true { return [] }
            tf.removeAll(keepingCapacity: true)
            matchedTerms.removeAll(keepingCapacity: true)
            for term in doc { tf[term, default: 0] += 1 }
            for group in groups {
                if group.requiresAll && !group.terms.allSatisfy({ tf[$0] != nil }) { continue }
                for term in group.terms where tf[term] != nil { matchedTerms.insert(term) }
            }
            var score = 0.0
            for term in matchedTerms {
                guard let f = tf[term], let d = df[term] else { continue }
                let idf = log(1 + (n - Double(d) + 0.5) / (Double(d) + 0.5))
                let freq = Double(f)
                score += idf * (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * Double(doc.count) / avgLen))
            }
            scores.append(score)
        }
        return scores
    }
}
