import Foundation

// ---------------------------------------------------------------------------
// 番茄数据模型 + 内核 JSON 解析
// 对照 ~/code/novel-downloader/app.go（SearchItem / BookInfo）与
// fanqie/fanqie.go（parseSearchResults / Preview / SafeFilename / FormatWords）。
// ---------------------------------------------------------------------------

/// 搜索结果项（旧版 SearchItem）。
struct SearchItem: Identifiable, Sendable, Hashable {
    /// M2-b：这条结果来自哪个平台（番茄默认；七猫走 QimaoBridge 映射）
    var platform: Platform = .fanqie
    var bookID: String
    var title: String
    var author: String
    var abstract: String
    var score: String   // "7.6 分" / "暂无评分"
    var words: String   // "28万字"
    var hot: String     // "35.6万人在读"
    var coverURL: URL?

    // MARK: - M3-b 短剧后台命中信息（默认未命中；短剧模式关闭时永远是默认值）
    /// 是否在短剧后台命中（命中 → 红标高亮 + 「短剧」角标 + 排最前）
    var sdInBackend: Bool = false
    /// 短剧后台返回的上架月份（首月）
    var sdOnlineMonth: String = ""
    /// 申请人数 / IP 被挑选次数
    var sdApply: Int = 0
    /// M10：已上架短剧数（卡片角标「短剧 · 上架 N 部」）
    var sdShelved: Int = 0
    /// 同 IP 改编中项目数
    var sdAdapting: Int = 0

    var id: String { bookID }
    var link: URL { platform.bookLink(bookID: bookID) }
}

/// 书籍详情（旧版 BookInfo，M1 只用番茄需要的字段）。
struct BookInfo: Identifiable, Sendable, Hashable {
    var platform: Platform = .fanqie
    var bookID: String
    var title: String
    var formerTitle: String   // 曾用名（作者改名后内核返回旧名，用网页当前名纠正）
    var author: String
    var description: String
    var category: String
    var chapterCount: Int
    var coverURL: URL?
    var words: String
    var hot: String
    var score: String
    var finished: Bool

    var id: String { bookID }
    var link: URL { platform.bookLink(bookID: bookID) }
}

/// 下载进度（旧版 download:progress 事件里的 saved/total）。
struct DownloadProgress: Equatable, Sendable {
    var saved: Int
    var total: Int   // 0 = 未知

    var fraction: Double { total > 0 ? min(1, Double(saved) / Double(total)) : 0 }
    /// 旧版文案：`下载中 12/117 章 (10%)` / `已下载 12 章`
    var text: String {
        if total > 0 {
            return "下载中 \(saved)/\(total) 章 (\(Int((fraction * 100).rounded()))%)"
        }
        return "已下载 \(saved) 章"
    }
}

/// 用户可见的错误（错误话术照抄旧版）。
enum FanqieError: LocalizedError {
    case kernelNotReady(String)
    case notFound(String)
    case network(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .kernelNotReady: "内核正在启动，请稍候…"
        case .notFound(let text): text
        case .network(let text): text
        case .upstream(let text): text
        }
    }
}

enum FanqieMapper {
    /// fanqie/fanqie.go: parseSearchResults
    static func searchItems(from json: JSONValue, coverBase: URL?) -> [SearchItem] {
        guard let items = json["items"]?.arrayValue else { return [] }
        return items.compactMap { item in
            guard let bookID = item["book_id"]?.looseString, !bookID.isEmpty else { return nil }
            let raw = item["raw"]
            let title = item["title"]?.looseString ?? raw?["book_name"]?.looseString ?? ""
            guard !title.isEmpty else { return nil }
            let wordCount = raw?["word_number"]?.intValue ?? 0
            return SearchItem(
                bookID: bookID,
                title: title,
                author: item["author"]?.looseString ?? raw?["author"]?.looseString ?? "佚名",
                abstract: raw?["abstract"]?.looseString ?? "",
                score: FMFormat.score(raw?["score"]?.doubleValue),
                words: wordCount > 0 ? FMFormat.words(wordCount) : "",
                hot: raw?["read_count_text"]?.looseString ?? "",
                coverURL: resolveCover(raw?["thumb_url"]?.looseString, base: coverBase)
            )
        }
    }

    /// fanqie/fanqie.go: Preview（字段逐条对照）
    static func bookInfo(from json: JSONValue, fallbackID: String, coverBase: URL?) -> BookInfo {
        let bookID = json["book_id"]?.looseString ?? fallbackID
        let wordCount = json["word_count"]?.intValue ?? 0
        return BookInfo(
            bookID: bookID,
            title: json["book_name"]?.looseString ?? "",
            formerTitle: json["original_book_name"]?.looseString ?? "",
            author: json["author"]?.looseString ?? "佚名",
            description: (json["description"]?.looseString ?? "")
                .replacingOccurrences(of: "\u{3000}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            category: json["category"]?.looseString ?? "",
            chapterCount: json["chapter_count"]?.intValue ?? 0,
            coverURL: resolveCover(
                json["detail_cover_url"]?.looseString ?? json["cover_url"]?.looseString,
                base: coverBase
            ),
            words: wordCount > 0 ? FMFormat.words(wordCount) : "",
            hot: json["read_count_text"]?.looseString ?? "",
            score: FMFormat.score(json["score"]?.doubleValue),
            finished: json["finished"]?.boolValue ?? false
        )
    }

    static func searchItem(from info: BookInfo) -> SearchItem {
        SearchItem(
            bookID: info.bookID,
            title: info.title,
            author: info.author,
            abstract: info.description,
            score: info.score,
            words: info.words,
            hot: info.hot,
            coverURL: info.coverURL
        )
    }

    /// fanqie/fanqie.go: ResolveCover —— 内核返回相对路径 `/api/preview-cover/<hash>`。
    static func resolveCover(_ raw: String?, base: URL?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        guard let base else { return nil }
        return URL(string: base.absoluteString + (raw.hasPrefix("/") ? raw : "/" + raw))
    }
}
