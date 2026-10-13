import Foundation

/// 七猫数据模型 + JSON 宽松取值器。
/// 对照 `qimao.go:163-244`（SearchResult / BookChapter / RankBook / AdaptBook /
/// AdaptOption / AdaptFilterGroup / AdaptFilter / Book）与 `qimao.go:707-777`
/// （strOf / intOf / firstNonEmpty / extractWords / composeHot / cleanRank / FormatWords）。
enum QimaoModels {

    /// qimao.go:163 `SearchResult`
    struct SearchResult: Sendable, Identifiable, Hashable {
        var id: String
        var title: String
        var author: String
        var isOver: Bool
        var score: String   // 如 "9.7"
        var words: String   // 如 "536万字"
        var coverURL: String
    }

    /// qimao.go:174 `BookChapter`
    struct BookChapter: Sendable, Hashable {
        var id: String
        var title: String
        var sort: Int
    }

    /// qimao.go:180 `RankBook`
    struct RankBook: Sendable, Identifiable, Hashable {
        var id: String
        var title: String
        var author: String
        var words: String    // 如 "891.33万字"
        var hot: String      // 如 "4373.5万"
        var coverURL: String
        var intro: String
        var isOver: Bool
        var category: String
    }

    /// qimao.go:194 `AdaptBook`
    struct AdaptBook: Sendable, Identifiable, Hashable {
        var id: String
        var title: String
        var author: String
        var words: String    // 如 "4.6万字"
        var category: String
        var isOver: Bool
        var coverURL: String
        var intro: String
        var clientID: Int    // 改编类型（1=漫剧/动漫, 3=短剧）
    }

    /// qimao.go:208 `AdaptOption`
    struct AdaptOption: Sendable, Hashable {
        var label: String
        var value: String
    }

    /// qimao.go:214 `AdaptFilterGroup`
    struct AdaptFilterGroup: Sendable, Hashable, Identifiable {
        var key: String
        var label: String
        var options: [AdaptOption]
        var id: String { key }
    }

    /// qimao.go:222 `AdaptFilter`（界面菜单对应）
    struct AdaptFilter: Sendable, Hashable {
        var direction: String = ""   // 改编方向: ""全部 1动漫短剧 2真人短剧
        var channel: String = ""     // 频道: ""全部 0男生 1女生 2短故事
        var category: String = ""    // 分类: ""全部
        var words: String = ""       // 字数: ""全部 1~5
        var isOver: String = ""      // 完结: ""全部 1已完结 0连载中
        var rankingType: String = "" // 热门书单: ""全部 1~6
        var page: Int = 0
        var pageSize: Int = 0
    }

    /// qimao.go:234 `Book`
    struct Book: Sendable, Hashable {
        var bookID: String
        var title: String
        var author: String
        var intro: String
        var wordsNum: Int
        var tags: String
        var imgURL: String
        var score: String
        var hot: String
        var rank: String
        var category: String
        var characters: String
    }

    // MARK: - 取值器（qimao.go:707 起）

    /// qimao.go:707 `strOf`
    static func strOf(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s): return s
        case .integerText(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }

    /// qimao.go:720 `intOf`
    static func intOf(_ v: JSONValue?) -> Int {
        switch v {
        case .number(let n): return Int(n)
        case .integerText(let s): return Int(s) ?? 0
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }

    /// qimao.go:734 `firstNonEmpty`
    static func firstNonEmpty(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a
    }

    /// qimao.go:742 `extractWords`：从 "影视・影视原著・完结・536万字" 提取 "536万字"。
    static func extractWords(_ s: String) -> String {
        guard let range = s.range(of: #"\d+(?:\.\d+)?万?字"#, options: .regularExpression) else { return "" }
        return String(s[range])
    }

    /// qimao.go:750 `composeHot`：拼 "265.9万 人气 · 22.2万 在读"。
    static func composeHot(_ attr: JSONValue?) -> String {
        var parts: [String] = []
        let pop = strOf(attr?["popularity"])
        if !pop.isEmpty && pop != "0" { parts.append(pop + "万 人气") }
        let read = strOf(attr?["reading"])
        if !read.isEmpty && read != "0" { parts.append(read + "万 在读") }
        return parts.joined(separator: " · ")
    }

    /// qimao.go:762 `cleanRank`：去掉 "当前排第###7###名" 里的 ### 标记。
    static func cleanRank(_ s: String) -> String {
        if s.isEmpty { return "" }
        return s.replacingOccurrences(of: #"#+(\d+)#+"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// qimao.go:771 `FormatWords`：5353368 → "535万字"。
    static func formatWords(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.0f万字", Double(n) / 10000) }
        return "\(n)字"
    }

    /// qimao.go:559 `wordsText`：{value,unit,title} → "4.6万字"。
    static func wordsText(_ v: JSONValue?) -> String {
        guard let wn = v, wn.objectValue != nil else { return "" }
        let text = strOf(wn["value"]) + strOf(wn["unit"]) + strOf(wn["title"])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
