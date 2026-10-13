import Foundation

/// 短剧后台 IP 数据层 —— 原样照搬 `~/code/novel-downloader/shortdrama.go`：
/// `ShortdramaIP`(:140) / `ShortdramaSearch`(:264) / `shortdramaSearchWithSession`(:281) /
/// `ipGenderLabel`(:339) / `strOf`(:350) / `intOf`(:363)，
/// 以及 `ShortdramaSessionStatusEx`(:90) 的会话校验部分。
///
/// 网络出口统一走 `HttpClient`（规格 4）；URL/请求头/解析口径原样照抄 Go 版。
/// 本层不接触任何界面。
///
/// M10 两处关键改动：
/// 1. **命中判定从「后台书名」改成「小说 ID」**：`book_id=<19 位番茄ID>` 可命中，
///    `novel_id`/`keyword`/`book_ids` 等参数会被后台**静默忽略并返回默认 20 条**，
///    所以命中只认「返回里存在一条 `ip_book_id` == 传入 ID（字符串精确相等）」。
/// 2. 19 位 ID 走 `strOf` 必须逐字符保真（`.integerText`，见 `JSONValue`）；
///    全链路按**字符串**取值/比较/拼 query，绝不经过 Double/Int 中转。
final class ShortdramaClient: @unchecked Sendable {
    static let shared = ShortdramaClient()

    private let http = HttpClient.shared

    private init() {}

    /// 自检只读取证（`sd-tags`）：最近一次搜索的**原始响应正文**（仅 `FQM_SELFTEST` 下记录）。
    /// 用来摊开每本书的 `category_list` 原文 / `gender` / `ip_tier_level`，判断
    /// 「标签少」是后台数据本来就少，还是解析/界面丢了。
    /// （`shortdramaList` 逐串行调用；取完一本书的正文再查下一本，不用加锁）
    nonisolated(unsafe) var debugLastRawBody: String?

    /// shortdrama.go:140 `ShortdramaIP`：短剧后台 IP 搜索结果。
    ///
    /// 除旧字段外（M10 起不删任何一个），新增后台全量展示字段 —— 全部**字符串化**，
    /// 展示文案在解析时就定型（百分比/万/列表），界面只负责摆位置。
    struct ShortdramaIP: Sendable, Identifiable, Hashable {
        // ---- 旧字段（M3-b；M10 起 `author`/`score` 与 `author_name`/`book_score` 同源） ----
        var ipBookID: String        // `ip_book_id`（19 位小说 ID，字符串）
        var name: String            // `ip_name`（后台书名）
        var author: String          // `author_name`
        var score: String           // `book_score`
        var desc: String            // `book_desc`（不展示）
        var coverURL: String        // `thumb_url`
        var words: String           // `word_num` → 「115万字」
        var gender: String          // `gender` → 「女频/男频/未知」
        var adaptType: String       // `ip_adaptation_type`
        var selectedCnt: String     // `ip_selected_count`（被挑选次数）
        var adaptingCnt: String     // `same_ip_adapting_count`（改编中）
        var readingCnt: String      // `read_listen_dcnt_14d`（原始数字）
        var onlineMonth: String     // `first_online_month`（上架）

        // ---- M10 后台全量数据（详情页数据块） ----
        /// `ip_id`（短剧后台自己的 IP 主键，19 位，字符串）
        var ipID: String = ""
        /// `ip_source` → 「网文/故事/出版/电影/电视剧/游戏/动漫/漫画/其他/未知」
        var source: String = ""
        /// `creation_status` → 「已完结/连载中/未知」
        var creationStatus: String = ""
        /// `read_listen_dcnt_14d` → 「25.9 万人在读」
        var readingText: String = ""
        /// `middle_read_duration_rate` → 「66.3%」
        var middleRate: String = ""
        /// `old_read_duration_rate` → 「19.3%」
        var oldRate: String = ""
        /// `young_read_duration_rate` → 「14.3%」
        var youngRate: String = ""
        /// `ip_shelved_count`（已上架短剧数）
        var shelvedCnt: String = ""
        /// `ip_tier_level` → 「未知/典藏IP/精品IP/潜力IP」
        var tierLevel: String = ""
        /// `category_list`（逗号分隔 → 数组）
        var categories: [String] = []
        /// `ip_current_ranking_list`（当前榜）
        var currentRankings: [String] = []
        /// `ip_historical_ranking_list`（历史峰值榜，可为空）
        var historicalRankings: [String] = []
        /// `ip_rating_count`（评价人数）
        var ratingCount: String = ""

        var id: String { ipBookID }
    }

    // MARK: - 会话状态（shortdrama.go:90 `ShortdramaSessionStatusEx`）

    /// 检查短剧登录态：先取本地候选，再用试探词「斗破」调一次服务端确认会话有效。
    /// 刚在浏览器登录时 Chromium 可能还没落盘新 cookie，失败后带延迟重试（最多 3 轮）。
    func sessionStatus() async -> KeychainFixStatus {
        var sids: [String]
        do {
            sids = try await ShortdramaSession.shortdramaSessionCandidates()
        } catch {
            return KeychainFixStatus(
                ok: false,
                keychainNeedsFix: ShortdramaKeychain.isKeychainAccessIssue(error),
                needsFullDiskAccess: (error as? ShortdramaFailure)?.kind == .needsFullDiskAccess,
                message: error.localizedDescription
            )
        }
        var lastErr: Error?
        for attempt in 0..<3 {
            for sid in sids {
                do {
                    _ = try await shortdramaSearchWithSession(sid, bookName: "斗破")
                    fmLog("短剧登录态校验成功(候选 \(sids.count) 个, 第 \(attempt + 1) 轮)")
                    return KeychainFixStatus(ok: true, keychainNeedsFix: false, message: "")
                } catch {
                    lastErr = error
                }
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 等 Chromium 落盘新 cookie
                do {
                    sids = try await ShortdramaSession.shortdramaSessionCandidates()
                } catch {
                    return KeychainFixStatus(
                        ok: false,
                        keychainNeedsFix: ShortdramaKeychain.isKeychainAccessIssue(error),
                        needsFullDiskAccess: (error as? ShortdramaFailure)?.kind == .needsFullDiskAccess,
                        message: error.localizedDescription
                    )
                }
            }
        }
        fmLog("短剧登录态校验失败: \(lastErr?.localizedDescription ?? "未知错误")")
        return KeychainFixStatus(ok: false, keychainNeedsFix: false, message: "无法访问短剧后台:" + (lastErr?.localizedDescription ?? "未知错误"))
    }

    // MARK: - 搜索（shortdrama.go:264 `ShortdramaSearch`）

    /// 按书名搜索短剧后台 IP（前 20 条）。依次尝试各浏览器的 sessionid，失效的自动跳过。
    func search(_ keyword: String) async throws -> [ShortdramaIP] {
        let sids = try await ShortdramaSession.shortdramaSessionCandidates()
        var lastErr: Error?
        for sid in sids {
            do {
                return try await shortdramaSearchWithSession(sid, bookName: keyword)
            } catch {
                lastErr = error
            }
        }
        throw lastErr ?? ShortdramaFailure(message: "短剧后台查询失败")
    }

    /// M10：按**小说 ID** 搜索短剧后台 IP。
    ///
    /// 只有返回里存在 `ip_book_id == id`（字符串精确相等）才算命中 —— 后台对未知参数
    /// 会静默忽略并回默认 20 条，不校验的话会把「本来不在后台」的书误判成命中。
    func searchByBookID(_ id: String) async throws -> ShortdramaIP? {
        let sids = try await ShortdramaSession.shortdramaSessionCandidates()
        var lastErr: Error?
        for sid in sids {
            do {
                let items = try await shortdramaSearchWithSession(sid, bookID: id)
                if let hit = items.first(where: { $0.ipBookID == id }) {
                    return hit
                }
                // 未命中：这一 sid 是有效的（请求成功），不必再试其它 sid
                return nil
            } catch {
                lastErr = error
            }
        }
        throw lastErr ?? ShortdramaFailure(message: "短剧后台查询失败")
    }

    // MARK: - 界面批量查询（M3-b：搜索/榜单逐本查后台，命中排最前）

    /// 一批书的命中情况 + 失败分类（界面用；永不抛错）。`hits` 以**书名**为键（界面按书名回填）。
    struct Batch: Sendable {
        var hits: [String: ShortdramaIP] = [:]
        /// 钥匙串被 ACL 拦截（需要引导授权）
        var keychainNeedsFix = false
        /// M3-d：Safari cookie 库读被 TCC 拒（需要完全磁盘访问权限）
        var needsFullDiskAccess = false
        /// 没有浏览器登录态（静默：搜索/榜单不提示，详情给提示）
        var sessionMissing = false
        /// 失败原因（无登录态 / 钥匙串 / 会话失效），供界面行文案
        var sessionMessage = ""
        /// 「短剧后台返回错误」（会话失效等）——旧版会弹登录引导，这里只记文案
        var loginFailure: String?
    }

    /// M10：把待查的书变成「番茄小说 ID + 书名」二元组。
    struct BookQuery: Sendable, Hashable {
        /// 番茄小说 ID（七猫书传 nil —— 七猫 ID 不是后台的 `book_id`，绝不能拿去查）
        var id: String?
        var title: String
    }

    /// M10：一次取候选，再按 3 个并发 worker 逐本查（对齐旧版 `checkShortdramaBackend` 的 3 worker）。
    ///
    /// 每本：有番茄 ID → **先按 ID 查**；未命中再**回退按书名**（兼容「后台书名 == 番茄书名」）；
    /// 无番茄 ID（七猫）→ 只按书名（与 M3-b 一致）。
    /// 参数互不影响主流程：任何失败都只记在 `Batch` 里，不抛错。
    func searchBooks(_ books: [BookQuery]) async -> Batch {
        var batch = Batch()
        guard !books.isEmpty else { return batch }

        let sids: [String]
        do {
            sids = try await ShortdramaSession.shortdramaSessionCandidates()
        } catch {
            batch.keychainNeedsFix = ShortdramaKeychain.isKeychainAccessIssue(error)
            batch.needsFullDiskAccess = (error as? ShortdramaFailure)?.kind == .needsFullDiskAccess
            batch.sessionMissing = (error as? ShortdramaFailure)?.kind == .noSession
            batch.sessionMessage = error.localizedDescription
            return batch
        }

        let workerCount = min(3, books.count)
        let collected = await withTaskGroup(of: [(BookQuery, ShortdramaIP?, String?)].self) { group -> [(BookQuery, ShortdramaIP?, String?)] in
            for offset in 0..<workerCount {
                group.addTask { [self] in
                    var out: [(BookQuery, ShortdramaIP?, String?)] = []
                    var index = offset
                    while index < books.count {
                        let book = books[index]
                        var best: ShortdramaIP?
                        var failure: String?
                        for sid in sids {
                            do {
                                best = try await hit(sid: sid, book: book)
                                failure = nil
                                break
                            } catch {
                                failure = error.localizedDescription
                            }
                        }
                        out.append((book, best, failure))
                        index += workerCount
                    }
                    return out
                }
            }
            var all: [(BookQuery, ShortdramaIP?, String?)] = []
            for await partial in group { all.append(contentsOf: partial) }
            return all
        }

        for (book, best, failure) in collected {
            if let best { batch.hits[book.title] = best }
            if let failure, batch.loginFailure == nil, failure.contains("短剧后台返回错误") {
                batch.loginFailure = failure
            }
        }
        return batch
    }

    /// 单本命中：先按 ID（有的话），未命中回退按书名。
    private func hit(sid: String, book: BookQuery) async throws -> ShortdramaIP? {
        if let id = book.id, !id.isEmpty {
            let byID = try await shortdramaSearchWithSession(sid, bookID: id)
            if let exact = byID.first(where: { $0.ipBookID == id }) { return exact }
        }
        let byName = try await shortdramaSearchWithSession(sid, bookName: book.title)
        return byName.first
    }

    /// shortdrama.go:281 `shortdramaSearchWithSession`：用指定 session 调短剧后台接口。
    /// M10：ID 查询与书名查询共用同一 URL，只差 `book_id=` / `book_name=` 一个参数。
    func shortdramaSearchWithSession(_ sid: String, bookName: String) async throws -> [ShortdramaIP] {
        try await shortdramaList(sid: sid, queryName: "book_name", queryValue: bookName)
    }

    /// M10：按小说 ID 查（其余参数与书名查询完全一致）。
    func shortdramaSearchWithSession(_ sid: String, bookID: String) async throws -> [ShortdramaIP] {
        try await shortdramaList(sid: sid, queryName: "book_id", queryValue: bookID)
    }

    private func shortdramaList(sid: String, queryName: String, queryValue: String) async throws -> [ShortdramaIP] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.shortdramas.com"
        comps.path = "/api/origin/cp/playlet/ip/list/v:version"
        comps.queryItems = [
            URLQueryItem(name: "page_no", value: "1"),
            URLQueryItem(name: "page_count", value: "20"),
            URLQueryItem(name: "image_fmt", value: "180x240"),
            URLQueryItem(name: "op_channel", value: "1"),
            URLQueryItem(name: "ip_adaptation_type", value: "2"),
            URLQueryItem(name: "aid", value: "791322"),
            URLQueryItem(name: queryName, value: queryValue),
        ]
        guard let url = comps.url else { throw ShortdramaFailure(message: "短剧后台地址构造失败") }

        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Referer": "https://www.shortdramas.com/page/ip-application",
            "Accept": "application/json, text/plain, */*",
            "Cookie": "sessionid=" + sid,
        ]
        let response = try await http.get(url, timeout: 20, headers: headers)
        guard response.statusCode == 200 else {
            throw ShortdramaFailure(message: "短剧后台 HTTP \(response.statusCode)")
        }

        let payload: JSONValue
        do {
            payload = try FMJSON.parse(response.data)
        } catch {
            throw ShortdramaFailure(message: "短剧后台返回无法解析")
        }
        // 自检只读取证（`sd-tags`）：把**原始响应正文**留下来，用来对照「后台原文 → 解析 → 界面渲染」
        // 三层（只解析阶段不丢字段就不算丢；只有自检模式才留）
        if ProcessInfo.processInfo.environment["FQM_SELFTEST"] != nil {
            debugLastRawBody = String(data: response.data, encoding: .utf8)
        }
        let code = intOf(payload["code"])
        if code != 0 {
            let raw = strOf(payload["message"])
            throw ShortdramaFailure(message: "短剧后台返回错误 code=\(code): \(raw.isEmpty ? "未知错误" : raw)")
        }

        var out: [ShortdramaIP] = []
        for it in payload["data"]?["ip_list"]?.arrayValue ?? [] {
            out.append(parseIP(it))
        }
        return out
    }

    // MARK: - 解析（全部字符串化；展示文案在这里定型）

    /// 把一条 `ip_list` 记录解析成 `ShortdramaIP`。
    func parseIP(_ it: JSONValue) -> ShortdramaIP {
        let wordCount = intOf(it["word_num"])
        let readerCount = intOf(it["read_listen_dcnt_14d"])
        return ShortdramaIP(
            ipBookID: strOf(it["ip_book_id"]),
            name: strOf(it["ip_name"]),
            author: strOf(it["author_name"]),
            score: strOf(it["book_score"]),
            desc: strOf(it["book_desc"]),
            coverURL: strOf(it["thumb_url"]),
            words: wordCount > 0 ? FMFormat.words(wordCount) : "",
            gender: ipGenderLabel(strOf(it["gender"])),
            adaptType: strOf(it["ip_adaptation_type"]),
            selectedCnt: strOf(it["ip_selected_count"]),
            adaptingCnt: strOf(it["same_ip_adapting_count"]),
            readingCnt: String(readerCount),
            onlineMonth: strOf(it["first_online_month"]),
            ipID: strOf(it["ip_id"]),
            source: ipSourceLabel(strOf(it["ip_source"])),
            creationStatus: creationStatusLabel(strOf(it["creation_status"])),
            readingText: readerText(readerCount),
            middleRate: rateText(it["middle_read_duration_rate"]),
            oldRate: rateText(it["old_read_duration_rate"]),
            youngRate: rateText(it["young_read_duration_rate"]),
            shelvedCnt: strOf(it["ip_shelved_count"]),
            tierLevel: tierLevelLabel(strOf(it["ip_tier_level"])),
            categories: stringList(it["category_list"]),
            currentRankings: stringList(it["ip_current_ranking_list"]),
            historicalRankings: stringList(it["ip_historical_ranking_list"]),
            ratingCount: strOf(it["ip_rating_count"])
        )
    }

    /// `category_list` 是逗号分隔字符串（也可能是数组）→ 数组。
    func stringList(_ v: JSONValue?) -> [String] {
        switch v {
        case .array(let a):
            return a.map { strOf($0) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .string(let s):
            return s.split(whereSeparator: { $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }

    // MARK: - 字段口径（M10 任务书 1.4 表）

    /// `ip_source`：1网文/2故事/3出版/4电影/5电视剧/6游戏/7动漫/8漫画/9其他，其余→「未知」。
    func ipSourceLabel(_ raw: String) -> String {
        switch raw {
        case "1": return "网文"
        case "2": return "故事"
        case "3": return "出版"
        case "4": return "电影"
        case "5": return "电视剧"
        case "6": return "游戏"
        case "7": return "动漫"
        case "8": return "漫画"
        case "9": return "其他"
        default: return "未知"
        }
    }

    /// `creation_status`：0已完结 / 1连载中 / 其余未知。
    func creationStatusLabel(_ raw: String) -> String {
        switch raw {
        case "0": return "已完结"
        case "1": return "连载中"
        default: return "未知"
        }
    }

    /// `ip_tier_level`：0未知 / 1典藏IP / 2精品IP / 3潜力IP / 其余未知。
    func tierLevelLabel(_ raw: String) -> String {
        switch raw {
        case "1": return "典藏IP"
        case "2": return "精品IP"
        case "3": return "潜力IP"
        default: return "未知"
        }
    }

    /// shortdrama.go:339 `ipGenderLabel`。
    /// M10 按任务书口径纠正：`gender` 0女频 / 1男频 / 其余未知
    /// （与 `ip_genre` 不是一个字段，别混用）。
    func ipGenderLabel(_ raw: String) -> String {
        switch raw {
        case "0": return "女频"
        case "1": return "男频"
        default: return "未知"
        }
    }

    /// `read_listen_dcnt_14d` → 「25.9 万人在读」/「1234 人在读」。
    func readerText(_ count: Int) -> String {
        guard count > 0 else { return "" }
        if count >= 10_000 {
            return String(format: "%.1f 万人在读", Double(count) / 10_000)
        }
        return "\(count) 人在读"
    }

    /// 0–1 浮点 → 百分比一位小数（0.6631984… → 「66.3%」）。
    func rateText(_ v: JSONValue?) -> String {
        guard let d = doubleOf(v) else { return "" }
        return String(format: "%.1f%%", d * 100)
    }

    private func doubleOf(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n): return n
        case .integerText(let s): return Double(s)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    // MARK: - 取值器（shortdrama.go:339 起）

    /// shortdrama.go:350 `strOf`。
    /// M10：`ip_book_id` / `ip_id` 这类 19 位 ID 必须逐字符保真 → 走 `.integerText`/`.string`，
    /// 绝不经过 Double（会抹尾数）。
    func strOf(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s): return s
        case .integerText(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }

    /// shortdrama.go:363 `intOf`。
    func intOf(_ v: JSONValue?) -> Int {
        switch v {
        case .number(let n): return Int(n)
        case .integerText(let s): return Int(s) ?? 0
        case .string(let s): return Int(s) ?? 0
        default: return 0
        }
    }
}
