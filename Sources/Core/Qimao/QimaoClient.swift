import CommonCrypto
import Foundation

/// 七猫（wtzw / qimao）数据层 —— 逐函数照搬 `~/code/novel-downloader/qimao/qimao.go`：
/// `NewClient`(:255) / `get`(:259) / `Search`(:288) / `BookDetail`(:325) /
/// `ChapterList`(:368) / `RankingBooks`(:398) / `adaptFetch`(:463) / `AdaptRankConfig`(:487) /
/// `AdaptBookList`(:509) / `DownloadURL`(:567) / `DownloadZip`(:584) / `Decrypt`(:602) /
/// `UnzipChapters`(:632) / `Download`(:659)。
///
/// 网络出口统一走 `HttpClient`（规格 4：只有一个 HTTP 出口）；签名/请求头/URL/协议原样照抄，
/// 未做任何"优化"或重设计。
@MainActor
final class QimaoClient {
    static let shared = QimaoClient()

    /// qimao.go:37-42 `baseURLs`
    private static let baseURLs: [String: String] = [
        "search": "https://api-bc.wtzw.com",
        "detail": "https://api-bc.wtzw.com",
        "download": "https://api-bc.wtzw.com",
        "catalog": "https://api-ks.wtzw.com",
    ]

    /// qimao.go:373
    private static let rankAPI = "https://www.qimao.com/qimaoapi/api/rank/book-list"
    /// qimao.go:440-443
    private static let adaptAPI = "https://zuozhe.qimao.com/api/pc/v1/book/screenplay-ranking-list"
    private static let adaptCfgAPI = "https://zuozhe.qimao.com/api/pc/v1/book/screenplay-ranking-config"

    private let http = HttpClient.shared

    private init() {}

    // MARK: - 请求底座

    /// qimao.go:259 `get`：params 里补 sign，query 排序编码，头 = requestHeaders(bookID)。
    private func get(baseKey: String, path: String, params: [String: String], bookID: String) async throws -> JSONValue {
        var params = params
        params["sign"] = QimaoSign.sign(params)
        let urlString = (Self.baseURLs[baseKey] ?? "") + path + "?" + QimaoSign.queryEncode(params)
        guard let url = URL(string: urlString) else { throw QimaoError.badURL(urlString) }
        let response = try await http.get(url, headers: QimaoSign.requestHeaders(bookID: bookID))
        guard response.statusCode == 200 else { throw QimaoError.http(response.statusCode, url.host ?? "") }
        return try JSONDecoder().decode(JSONValue.self, from: response.data)
    }

    // MARK: - 搜索 / 详情 / 目录

    /// qimao.go:288 `Search`
    func search(_ keyword: String) async throws -> [QimaoModels.SearchResult] {
        let data = try await get(baseKey: "search", path: "/search/v1/words", params: [
            "extend": "",
            "tab": "0",
            "gender": "0",
            "refresh_state": "8",
            "page": "1",
            "wd": keyword,
            "is_short_story_user": "0",
        ], bookID: "00000000")

        var results: [QimaoModels.SearchResult] = []
        for item in data["data"]?["books"]?.arrayValue ?? [] {
            let id = QimaoModels.strOf(item["id"])
            if id.isEmpty { continue }
            results.append(QimaoModels.SearchResult(
                id: id,
                title: QimaoSign.stripHTML(QimaoModels.strOf(item["title"])),
                author: QimaoSign.stripHTML(QimaoModels.strOf(item["author"])),
                isOver: QimaoModels.strOf(item["is_over"]) == "1",
                score: QimaoModels.strOf(item["score"]),
                words: QimaoModels.extractWords(QimaoModels.strOf(item["sub_title"])),
                coverURL: QimaoModels.strOf(item["image_link"])
            ))
        }
        return results
    }

    /// qimao.go:325 `BookDetail`
    func bookDetail(bookID: String) async throws -> QimaoModels.Book {
        let data = try await get(baseKey: "detail", path: "/api/v4/book/detail", params: [
            "id": bookID,
            "imei_ip": "2937357107",
            "teeny_mode": "0",
        ], bookID: bookID)

        guard let dm = data["data"]?.objectValue else { throw QimaoError.missingField("detail: 无 data 字段") }
        guard let b = dm["book"] else { throw QimaoError.missingField("detail: 无 book 字段") }

        var tags: [String] = []
        for tag in b["book_tag_list"]?.arrayValue ?? [] {
            let title = QimaoModels.strOf(tag["title"])
            if !title.isEmpty { tags.append(title) }
        }
        let attr = b["attribute"]
        return QimaoModels.Book(
            bookID: QimaoModels.firstNonEmpty(QimaoModels.strOf(b["id"]), bookID),
            title: QimaoModels.strOf(b["title"]),
            author: QimaoModels.strOf(b["author"]),
            intro: QimaoModels.strOf(b["intro"]),
            wordsNum: QimaoModels.intOf(b["words_num"]),
            tags: tags.joined(separator: ", "),
            imgURL: QimaoModels.strOf(b["image_link"]),
            score: QimaoModels.strOf(attr?["score"]),
            hot: QimaoModels.composeHot(attr),
            rank: QimaoModels.cleanRank(QimaoModels.strOf(attr?["rank_title"])),
            category: (QimaoModels.strOf(b["category1_name"]) + " " + QimaoModels.strOf(b["category2_name"]))
                .trimmingCharacters(in: .whitespacesAndNewlines),
            characters: QimaoModels.firstNonEmpty(QimaoModels.strOf(attr?["characters"]), QimaoModels.strOf(b["characters"]))
        )
    }

    /// qimao.go:368 `ChapterList`（按 chapter_sort 稳定排序）
    func chapterList(_ bookID: String) async throws -> [QimaoModels.BookChapter] {
        let data = try await get(baseKey: "catalog", path: "/api/v1/chapter/chapter-list", params: [
            "chapter_ver": "0",
            "id": bookID,
        ], bookID: bookID)

        var chapters: [QimaoModels.BookChapter] = []
        for item in data["data"]?["chapter_lists"]?.arrayValue ?? [] {
            chapters.append(QimaoModels.BookChapter(
                id: QimaoModels.strOf(item["id"]),
                title: QimaoModels.strOf(item["title"]),
                sort: QimaoModels.intOf(item["chapter_sort"])
            ))
        }
        // 等价 Go 的 sort.SliceStable：sort 相同时保持原顺序（Swift sort 不保证稳定，用索引兜底）
        return chapters.enumerated()
            .sorted { lhs, rhs in
                lhs.element.sort != rhs.element.sort ? lhs.element.sort < rhs.element.sort : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - 榜单（官网 web API，普通浏览器请求）

    /// qimao.go:398 `RankingBooks`：isGirl "0"男 "1"女；rankType 1大热 2新书 3完结 4收藏 6更新。
    func rankingBooks(isGirl: String, rankType: String) async throws -> [QimaoModels.RankBook] {
        let params: [String: String] = [
            "is_girl": isGirl,
            "rank_type": rankType,
            "page": "1",
            "date_type": (rankType == "4" || rankType == "6") ? "1" : "2",
        ]
        guard let url = URL(string: Self.rankAPI + "?" + QimaoSign.queryEncode(params)) else {
            throw QimaoError.badURL(Self.rankAPI)
        }
        let response = try await http.get(url, headers: [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
        ])
        guard response.statusCode == 200 else { throw QimaoError.rankHTTP(response.statusCode) }
        let payload = try JSONDecoder().decode(JSONValue.self, from: response.data)

        var books: [QimaoModels.RankBook] = []
        for it in payload["data"]?["table_data"]?.arrayValue ?? [] {
            let id = QimaoModels.strOf(it["book_id"])
            if id.isEmpty { continue }
            let hot = (QimaoModels.strOf(it["number"]) + QimaoModels.strOf(it["unit"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let category = (QimaoModels.strOf(it["category1_name"]) + " " + QimaoModels.strOf(it["category2_name"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            books.append(QimaoModels.RankBook(
                id: id,
                title: QimaoModels.strOf(it["title"]),
                author: QimaoModels.strOf(it["author"]),
                words: QimaoModels.strOf(it["words_num"]),
                hot: hot,
                coverURL: QimaoModels.strOf(it["image_link"]),
                intro: QimaoModels.strOf(it["intro"]),
                isOver: QimaoModels.strOf(it["is_over"]) == "1",
                category: category
            ))
        }
        return books
    }

    // MARK: - 官方「剧本改编书单」

    /// qimao.go:463 `adaptFetch`：作者中心 UA + Referer。
    private func adaptFetch(_ rawURL: String) async throws -> JSONValue {
        guard let url = URL(string: rawURL) else { throw QimaoError.badURL(rawURL) }
        let response = try await http.get(url, headers: [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Referer": "https://zuozhe.qimao.com/front/screenplay/adapt-book-list",
            "Accept": "application/json, text/plain, */*",
        ])
        guard response.statusCode == 200 else { throw QimaoError.adaptHTTP(response.statusCode) }
        return try JSONDecoder().decode(JSONValue.self, from: response.data)
    }

    /// qimao.go:487 `AdaptRankConfig`
    func adaptRankConfig() async throws -> [QimaoModels.AdaptFilterGroup] {
        let data = try await adaptFetch(Self.adaptCfgAPI)
        var groups: [QimaoModels.AdaptFilterGroup] = []
        for item in data["data"]?.arrayValue ?? [] {
            var group = QimaoModels.AdaptFilterGroup(
                key: QimaoModels.strOf(item["key"]),
                label: QimaoModels.strOf(item["label"]),
                options: []
            )
            for option in item["options"]?.arrayValue ?? [] {
                group.options.append(QimaoModels.AdaptOption(
                    label: QimaoModels.strOf(option["label"]),
                    value: QimaoModels.strOf(option["value"])
                ))
            }
            groups.append(group)
        }
        return groups
    }

    /// qimao.go:509 `AdaptBookList`：返回（书籍, 总数）。
    func adaptBookList(_ filter: QimaoModels.AdaptFilter) async throws -> (books: [QimaoModels.AdaptBook], total: Int) {
        var filter = filter
        if filter.pageSize <= 0 { filter.pageSize = 20 }
        if filter.page <= 0 { filter.page = 1 }
        let params: [String: String] = [
            "direction": filter.direction,
            "channel": filter.channel,
            "category": filter.category,
            "words": filter.words,
            "is_over": filter.isOver,
            "ranking_type": filter.rankingType,
            "date_type": "1",
            "page_size": String(filter.pageSize),
            "page": String(filter.page),
        ]
        let data = try await adaptFetch(Self.adaptAPI + "?" + QimaoSign.queryEncode(params))

        var books: [QimaoModels.AdaptBook] = []
        for it in data["data"]?["book_list"]?.arrayValue ?? [] {
            let id = String(QimaoModels.intOf(it["book_id"]))
            if id == "0" { continue }
            books.append(QimaoModels.AdaptBook(
                id: id,
                title: QimaoModels.strOf(it["book_title"]),
                author: QimaoModels.strOf(it["author_name"]),
                words: QimaoModels.wordsText(it["words_num"]),
                category: QimaoModels.strOf(it["category1_name"]),
                isOver: QimaoModels.strOf(it["is_over"]) == "完结",
                coverURL: QimaoModels.strOf(it["image_link"]),
                intro: QimaoModels.strOf(it["intro"]),
                clientID: QimaoModels.intOf(it["client_id"])
            ))
        }
        let total = QimaoModels.intOf(data["data"]?["page_data"]?["count"])
        return (books, total)
    }

    // MARK: - 下载

    /// qimao.go:567 `DownloadURL`
    func downloadURL(_ bookID: String) async throws -> String {
        let data = try await get(baseKey: "download", path: "/api/v1/book/download", params: [
            "id": bookID,
            "source": "1",
            "type": "2",
            "is_vip": "1",
        ], bookID: bookID)
        return QimaoModels.strOf(data["data"]?["link"])
    }

    /// qimao.go:584 `DownloadZip`（带空书号请求头）
    func downloadZip(_ link: String) async throws -> Data {
        guard let url = URL(string: link) else { throw QimaoError.badURL(link) }
        let response = try await http.get(url, headers: QimaoSign.requestHeaders(bookID: ""))
        guard response.statusCode == 200 else { throw QimaoError.zipHTTP(response.statusCode) }
        return response.data
    }

    /// qimao.go:659 `Download`：详情 + 目录 + zip + 解密 + 写文件（txt | epub）。
    func download(
        bookID: String,
        outputDir: URL,
        format: String,
        progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> URL {
        let book = try await bookDetail(bookID: bookID)
        let catalog = try await chapterList(bookID)
        let link = try await downloadURL(bookID)
        let zipBytes = try await downloadZip(link)
        let chapters = try QimaoCrypto.unzipChapters(zipBytes)

        var ordered: [QimaoWriters.OrderedChapter] = []
        for (index, chapter) in catalog.enumerated() {
            if let content = chapters[chapter.id] {
                ordered.append(QimaoWriters.OrderedChapter(chapter: chapter, content: content))
            }
            progress?(index + 1, catalog.count)
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let base = QimaoSign.safeFilename(book.title) + " " + QimaoSign.safeFilename(book.author)
            + " [" + QimaoSign.safeFilename(book.bookID) + "]"
        if format == "epub" {
            let path = outputDir.appendingPathComponent(base + ".epub")
            try QimaoWriters.writeEpub(book: book, chapters: ordered, path: path, coverURL: book.imgURL)
            return path
        }
        let path = outputDir.appendingPathComponent(base + ".txt")
        try QimaoWriters.writeSingleTxt(book: book, chapters: ordered, path: path)
        return path
    }
}

/// 七猫错误（用户可见文案一律中文，原始细节只进日志）
enum QimaoError: Error, LocalizedError {
    case http(Int, String)
    case rankHTTP(Int)
    case adaptHTTP(Int)
    case zipHTTP(Int)
    case badURL(String)
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let host): "七猫服务返回 HTTP \(code)（\(host)）"
        case .rankHTTP(let code): "七猫榜单返回 HTTP \(code)"
        case .adaptHTTP(let code): "七猫改编书单返回 HTTP \(code)"
        case .zipHTTP(let code): "七猫下载包返回 HTTP \(code)"
        case .badURL: "接口地址无法解析"
        case .missingField(let why): "七猫返回数据缺少字段（\(why)）"
        }
    }
}
