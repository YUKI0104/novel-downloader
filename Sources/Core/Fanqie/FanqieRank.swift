import Foundation

/// 榜单分组（对照 fanqie.go 的 RankGenre / RankGroup）
struct RankGenre: Sendable, Hashable {
    var name: String
    var readURL: String   // 类型 1 = 阅读榜
    var newURL: String    // 类型 2 = 新书榜
}

struct RankGroup: Sendable, Hashable {
    var gender: String    // 综合 / 男频 / 女频
    var hotURL: String    // 只有综合组有
    var genres: [RankGenre]
}

/// 番茄榜单数据层 —— 逐函数对照 `~/code/novel-downloader/fanqie/fanqie.go:732-870`
/// （RankCategories / FetchRankBookIDs / RankingBooks / fetchHTML），
/// 同一 URL 结构、同正则、并发 8 保序、60s 缓存；抓官网页面不走内核。
@MainActor
final class FanqieRank {
    static let shared = FanqieRank()

    static let rankBaseURL = "https://fanqienovel.com"
    private static let cacheTTL: TimeInterval = 60
    private static let workerCount = 8
    private static let topCount = 10

    private var cache: [String: (books: [SearchItem], at: Date)] = [:]
    private var cachedGroups: [RankGroup]?

    private init() {}

    // MARK: - 频道 / 题材（RankCategories）

    func categories(forceRefresh: Bool = false) async throws -> [RankGroup] {
        if !forceRefresh, let cachedGroups { return cachedGroups }
        let html = try await Self.fetchHTML(Self.rankBaseURL + "/rank")
        let groups = Self.parseCategories(html)
        cachedGroups = groups
        return groups
    }

    /// 正则与分组逻辑照搬 Go 版：`<a[^>]*href="(/rank/(\d+)_(\d+)_(\d+))"[^>]*>(.*?)</a>`
    static func parseCategories(_ html: String) -> [RankGroup] {
        let pattern = #"<a[^>]*href="(/rank/(\d+)_(\d+)_(\d+))"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        var byGender: [String: [String: RankGenre]] = [:]
        let ns = html as NSString
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 6 else { return }
            let path = ns.substring(with: match.range(at: 1))
            let genderCode = ns.substring(with: match.range(at: 2))
            let rankType = ns.substring(with: match.range(at: 3))
            let inner = ns.substring(with: match.range(at: 5))
            let label = stripTags(inner)
            guard !label.isEmpty, !isObfuscated(label) else { return }
            let gender = genderCode == "0" ? "女频" : "男频"
            var group = byGender[gender] ?? [:]
            var genre = group[label] ?? RankGenre(name: label, readURL: "", newURL: "")
            if rankType == "1" {
                genre.readURL = rankBaseURL + path
            } else {
                genre.newURL = rankBaseURL + path
            }
            group[label] = genre
            byGender[gender] = group
        }

        var groups: [RankGroup] = [RankGroup(gender: "综合", hotURL: rankBaseURL + "/rank", genres: [])]
        for gender in ["男频", "女频"] {
            guard let map = byGender[gender], !map.isEmpty else { continue }
            let genres = map.keys.sorted().compactMap { map[$0] }
            groups.append(RankGroup(gender: gender, hotURL: "", genres: genres))
        }
        return groups
    }

    static func stripTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        let ns = html as NSString
        let plain = regex.stringByReplacingMatches(
            in: html, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
        return plain.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 私用区字符（番茄对未登录用户做字体混淆）
    static func isObfuscated(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0xE000 && $0.value <= 0xF8FF }
    }

    // MARK: - 榜单前 10（FetchRankBookIDs + RankingBooks）

    /// 榜单前 10。`forceRefresh = true` 时**跳过 60s 缓存**（M13「刷新榜单」按钮走这条：
    /// 用户点刷新 = 要新数据，不能拿 60s 内的缓存敷衍）。
    func books(rankURL: String, forceRefresh: Bool = false) async throws -> [SearchItem] {
        guard !rankURL.isEmpty else { return [] }
        let totalStart = Date()
        if !forceRefresh, let entry = cache[rankURL], Date().timeIntervalSince(entry.at) < Self.cacheTTL {
            let ms = Self.ms(since: totalStart)
            fmLog("榜单命中缓存（\(rankURL)），共 \(entry.books.count) 条")
            Self.stageReport("命中缓存", url: rankURL, fetchMS: 0, parseMS: 0, previewMS: 0, totalMS: ms, ids: entry.books.count)
            return entry.books
        }

        // a) 抓榜单页 HTML
        let fetchStart = Date()
        let html = try await Self.fetchHTML(rankURL)
        let fetchMS = Self.ms(since: fetchStart)

        // b) 解析出有序书 ID
        let parseStart = Date()
        let ids = Self.parseIDs(html)
        let parseMS = Self.ms(since: parseStart)
        let top = Array(ids.prefix(Self.topCount))

        // c) 并发 8 的 worker 池补全 10 本书（保持名次顺序）
        let previewStart = Date()
        var slots = [SearchItem?](repeating: nil, count: top.count)
        await withTaskGroup(of: (Int, SearchItem?).self) { group in
            var next = 0
            func addTask(_ index: Int) {
                let id = top[index]
                group.addTask {
                    let item = try? await FanqieAPI.shared.previewItem(id: id)
                    return (index, item)
                }
            }
            while next < min(Self.workerCount, top.count) {
                addTask(next)
                next += 1
            }
            for await (index, item) in group {
                slots[index] = item
                if next < top.count {
                    addTask(next)
                    next += 1
                }
            }
        }
        let previewMS = Self.ms(since: previewStart)

        let result = slots.compactMap { $0 }
        cache[rankURL] = (result, Date())
        let totalMS = Self.ms(since: totalStart)
        fmLog("榜单已加载（\(rankURL)）：\(result.count) 条")
        Self.stageReport("首屏", url: rankURL, fetchMS: fetchMS, parseMS: parseMS, previewMS: previewMS, totalMS: totalMS, ids: ids.count)
        return result
    }

    static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// 分阶段计时（M1.6 取证）：`FQM_DEBUG_METRICS=1` 时输出
    static func stageReport(_ stage: String, url: String, fetchMS: Int, parseMS: Int, previewMS: Int, totalMS: Int, ids: Int) {
        guard FMMetrics.enabled else { return }
        let line = "FQM_RANKSTAGE \(stage) 抓HTML=\(fetchMS)ms 解析ID=\(parseMS)ms(\(ids)个ID) preview×\(min(ids, topCount))=\(previewMS)ms 合计=\(totalMS)ms url=\(url)"
        print(line)
        fflush(stdout)
        fmLog(line)
    }

    /// `/page/(\d{15,})` 有序去重
    static func fetchRankBookIDs(_ rankURL: String) async throws -> [String] {
        parseIDs(try await fetchHTML(rankURL))
    }

    /// `/page/(\d{15,})` 有序去重（fetchRankBookIDs 的解析部分，单独抽出来便于分阶段计时）
    static func parseIDs(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"/page/(\d{15,})"#) else { return [] }
        let ns = html as NSString
        var ids: [String] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let id = ns.substring(with: match.range(at: 1))
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    // MARK: - fetchHTML（不走内核，自己带浏览器 UA；curl 兜底）

    static func fetchHTML(_ rawURL: String) async throws -> String {
        let host = URL(string: rawURL)?.host ?? "fanqienovel.com"
        var lastError: Error?
        var lastStatus = 0
        // 1) URLSession + 完整浏览器头
        if let url = URL(string: rawURL) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            FanqieAPI.applyBrowserHeaders(to: &request)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, let html = String(data: data, encoding: .utf8), !html.isEmpty {
                    return html
                }
                lastStatus = status
                if !(200..<300).contains(status), status != 0 {
                    fmLog("榜单页 HTTP \(status)：\(rawURL)")
                }
            } catch {
                lastError = error
                fmLog("榜单页抓取失败（只进日志）：\(error) url=\(rawURL)")
            }
        }
        // 2) curl 兜底（TLS 指纹/协议栈不同，反爬可能放行）—— 对照 Go 版 fetchCurl
        if let html = try? fetchByCurl(rawURL) {
            return html
        }

        // 用户可见文案：全中文短句，一句话只说一件事
        if let lastError {
            let nsError = lastError as NSError
            if nsError.domain == NSURLErrorDomain {
                throw FanqieError.network(
                    FriendlyError.networkText(URLError(URLError.Code(rawValue: nsError.code)), host: host)
                )
            }
            throw FanqieError.network("无法连接 \(host)")
        }
        if lastStatus == 403 || lastStatus == 444 || lastStatus == 401 {
            throw FanqieError.network("番茄官网反爬拦截（HTTP \(lastStatus)）：请先用浏览器打开 https://fanqienovel.com 再重试")
        }
        throw FanqieError.network("找不到服务器 \(host)（HTTP \(lastStatus)）")
    }

    private static func fetchByCurl(_ rawURL: String) throws -> String {
        let output = KernelProcess.runAndCapture(
            "/usr/bin/curl",
            [
                "--compressed", "--http1.1", "-sS", "-L", "--max-time", "25",
                "-A", FanqieAPI.webUserAgent,
                "-H", "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                "-H", "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8",
                "-H", "Sec-Fetch-Dest: document",
                "-H", "Sec-Fetch-Mode: navigate",
                "-H", "Sec-Fetch-Site: none",
                "-H", "Upgrade-Insecure-Requests: 1",
                rawURL,
            ],
            timeout: 30
        )
        guard !output.isEmpty else { throw FanqieError.network("curl: 空响应") }
        return output
    }
}
