import Foundation

/// 七猫 → 共用界面模型（`SearchItem` / `BookInfo`）的桥。
/// 界面组件（AlbumCard / ResultsArea / BookDetailView）完全不改形态，只吃这两个共用模型。
@MainActor
enum QimaoBridge {

    /// 搜索/榜单/改编书单统一映射：rating 文案与番茄保持一致口径（"9.7 分" / "暂无评分"）
    static func scoreText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "0" || trimmed == "0.0" { return "暂无评分" }
        return trimmed.hasSuffix("分") ? trimmed : "\(trimmed) 分"
    }

    static func searchItem(_ r: QimaoModels.SearchResult) -> SearchItem {
        SearchItem(
            platform: .qimao,
            bookID: r.id,
            title: r.title,
            author: r.author,
            abstract: "",
            score: scoreText(r.score),
            words: r.words,
            hot: r.isOver ? "已完结" : "连载中",
            coverURL: URL(string: r.coverURL)
        )
    }

    static func searchItem(_ b: QimaoModels.RankBook) -> SearchItem {
        SearchItem(
            platform: .qimao,
            bookID: b.id,
            title: b.title,
            author: b.author,
            abstract: b.intro,
            score: "",
            words: b.words,
            hot: b.hot,
            coverURL: URL(string: b.coverURL)
        )
    }

    static func searchItem(_ b: QimaoModels.AdaptBook) -> SearchItem {
        SearchItem(
            platform: .qimao,
            bookID: b.id,
            title: b.title,
            author: b.author,
            abstract: b.intro,
            score: "",
            words: b.words,
            hot: b.isOver ? "已完结" : "连载中",
            coverURL: URL(string: b.coverURL)
        )
    }

    /// app.go: BookInfo 的七猫分支（ExtractBookID → BookDetail + ChapterList）
    static func bookInfo(_ b: QimaoModels.Book, chapterCount: Int) -> BookInfo {
        BookInfo(
            platform: .qimao,
            bookID: b.bookID,
            title: b.title,
            formerTitle: "",
            author: b.author,
            description: b.intro,
            category: b.category,
            chapterCount: chapterCount,
            coverURL: URL(string: b.imgURL),
            words: b.wordsNum > 0 ? QimaoModels.formatWords(b.wordsNum) : "",
            hot: b.hot,
            score: scoreText(b.score),
            finished: false
        )
    }

    /// BookInfo → SearchItem（ID/链接直达时用，和番茄 ID 直达一个观感）
    static func searchItem(fromBookInfo info: BookInfo) -> SearchItem {
        SearchItem(
            platform: .qimao,
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

    /// 搜索入口（含 ID / 链接直达，对照 app.go:462 的 ExtractBookID）
    static func search(_ keyword: String) async throws -> [SearchItem] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let normalized = QimaoSign.extractBookID(trimmed)
        let looksLikeID = QimaoSign.isAllDigits(normalized) && normalized.count >= 5
        if looksLikeID {
            let book = try await QimaoClient.shared.bookDetail(bookID: normalized)
            fmLog("七猫搜索[\(trimmed)] 按 ID 命中《\(book.title)》")
            return [searchItem(fromBookInfo: bookInfo(book, chapterCount: 0))]
        }

        let hits = try await QimaoClient.shared.search(trimmed)
        fmLog("七猫搜索[\(trimmed)] 共 \(hits.count) 条")
        return hits.map(searchItem)
    }

    /// 详情入口（ExtractBookID → BookDetail + ChapterList）
    static func bookInfo(id rawID: String) async throws -> BookInfo {
        let id = QimaoSign.extractBookID(rawID)
        let book = try await QimaoClient.shared.bookDetail(bookID: id)
        var chapterCount = 0
        if let chapters = try? await QimaoClient.shared.chapterList(id) {
            chapterCount = chapters.count
        }
        return bookInfo(book, chapterCount: chapterCount)
    }
}
