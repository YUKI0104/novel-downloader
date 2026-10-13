import Foundation

/// 番茄数据层（对照 `fanqie/fanqie.go` 的 Client：EnsureServer + Search + Preview +
/// ResolveCover + WebBookName + resolveFanqieTitle）。
///
/// 低层 REST 传输（超时、退避重试、错误分类）在 `Core/Kernel/KernelService.swift`，
/// 这里只做业务编排与字段/文案处理。
@MainActor
final class FanqieAPI {
    static let shared = FanqieAPI()

    private let service = KernelService.shared

    /// fanqie.go: searchAttempts / searchRetryDelay
    private static let searchAttempts = 4
    private static let searchRetryDelay = Duration.milliseconds(800)

    private var nameCache: [String: (name: String, at: Date)] = [:]
    private static let nameCacheTTL: TimeInterval = 10 * 60

    private init() {}

    // MARK: - 搜索

    /// fanqie.go: Client.Search + app.go: App.Search / extractFanqieID
    /// 支持书名、纯数字 ID、fanqienovel.com/page/<id> 链接。
    func search(_ keyword: String) async throws -> [SearchItem] {
        try await ensureServer()

        // 纯数字 ID / 书页链接 → 直接按 ID 定位
        if let bookID = Self.extractBookID(from: keyword) {
            do {
                let info = try await bookInfo(id: bookID)
                fmLog("搜索[\(keyword)] 按 ID 命中《\(info.title)》")
                return [FanqieMapper.searchItem(from: info)]
            } catch {
                fmLog("搜索[ID:\(bookID)] 失败: \(error.localizedDescription)")
                if let fanqie = error as? FanqieError, case .kernelNotReady = fanqie { throw fanqie }
                throw FanqieError.notFound("未找到 ID 为 \(bookID) 的书籍")
            }
        }

        var lastError: String?
        for attempt in 1...Self.searchAttempts {
            fmLog("搜索[\(keyword)] 第\(attempt)/\(Self.searchAttempts)次尝试...")
            let json: JSONValue
            do {
                json = try await service.search(keyword)
            } catch let error as KernelServiceError {
                lastError = error.errorDescription
                if error.isKernelUnavailable { throw FanqieError.kernelNotReady(keyword) }
                if attempt < Self.searchAttempts { try? await Task.sleep(for: Self.searchRetryDelay) }
                continue
            } catch {
                lastError = FriendlyError.text(error)
                if attempt < Self.searchAttempts { try? await Task.sleep(for: Self.searchRetryDelay) }
                continue
            }

            let items = FanqieMapper.searchItems(from: json, coverBase: service.baseURL)
            if !items.isEmpty {
                fmLog("搜索[\(keyword)] 第\(attempt)次 结果 \(items.count) 条")
                return items
            }
            // 空结果：内核预热中或临时风控，短退避重试（旧版同样处理）
            fmLog("搜索[\(keyword)] 第\(attempt)次 空结果")
            lastError = "未找到相关结果"
            if attempt < Self.searchAttempts { try? await Task.sleep(for: Self.searchRetryDelay) }
        }

        let message = lastError ?? "未找到相关结果"
        if message.contains("HTTP 5") || message.contains("风控") || message.contains("滑块") {
            throw FanqieError.upstream("搜索失败: \(message)(可能被番茄网站风控限制，请稍后再试或更换搜索关键词)")
        }
        throw FanqieError.upstream("搜索失败: \(message)")
    }

    /// app.go: extractFanqieID —— ≥10 位纯数字，或 `/page/<id>` 链接。
    static func extractBookID(from keyword: String) -> String? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber), trimmed.count >= 10 { return trimmed }
        if let range = trimmed.range(of: #"/page/(\d{10,})"#, options: .regularExpression) {
            let digits = String(trimmed[range]).filter(\.isNumber)
            return digits.isEmpty ? nil : digits
        }
        return nil
    }

    // MARK: - 详情

    /// fanqie.go: Client.Preview + app.go: resolveFanqieTitle
    func bookInfo(id: String) async throws -> BookInfo {
        try await ensureServer()
        let json: JSONValue
        do {
            json = try await service.preview(id)
        } catch let error as KernelServiceError {
            if error.isKernelUnavailable { throw FanqieError.kernelNotReady(id) }
            throw FanqieError.upstream(error.errorDescription ?? "详情加载失败")
        }
        var info = FanqieMapper.bookInfo(from: json, fallbackID: id, coverBase: service.baseURL)
        let resolved = await resolveFanqieTitle(bookID: id, kernelTitle: info.title)
        info.title = resolved.title
        info.formerTitle = resolved.former
        return info
    }

    /// 榜单用：只取详情映射成一条结果（对照旧版 RankingBooks 里直接调 Preview，不做网页纠名）
    func previewItem(id: String) async throws -> SearchItem {
        try await ensureServer()
        let json = try await service.preview(id)
        let info = FanqieMapper.bookInfo(from: json, fallbackID: id, coverBase: service.baseURL)
        return FanqieMapper.searchItem(from: info)
    }

    /// app.go: resolveFanqieTitle —— 处理作者改名书：内核返回旧名，网页是当前名。
    /// 仅当两名字互不包含时才算改名（避免「三体」vs「三体全集(全三册)」这类显示差异误报）。
    func resolveFanqieTitle(bookID: String, kernelTitle: String) async -> (title: String, former: String) {
        let web = await webBookName(bookID: bookID)
        guard !web.isEmpty, web != kernelTitle else { return (kernelTitle, "") }
        if web.contains(kernelTitle) || kernelTitle.contains(web) { return (kernelTitle, "") }
        return (web, kernelTitle)
    }

    /// fanqie.go: WebBookName —— 抓番茄官网书页，取 keywords meta 里的当前书名。
    /// 抓不到（反爬/断网）返回空串，调用方回退旧名。
    func webBookName(bookID: String) async -> String {
        if let cached = nameCache[bookID], Date().timeIntervalSince(cached.at) < Self.nameCacheTTL {
            return cached.name
        }
        guard let url = URL(string: "https://fanqienovel.com/page/\(bookID)") else { return "" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8 // 改名书才会走到这里；超时就静默回退内核返回的名字
        Self.applyBrowserHeaders(to: &request)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let name = Self.parseWebBookName(html) else { return "" }
        nameCache[bookID] = (name, Date())
        return name
    }

    static let webNamePattern = #"<meta name="keywords" content="([^",]+)"#

    static func parseWebBookName(_ html: String) -> String? {
        guard let range = html.range(of: webNamePattern, options: .regularExpression) else { return nil }
        // 取捕获组：从匹配串里截出 content=" 与 " 之间的部分
        let matched = String(html[range])
        guard let start = matched.range(of: "content=\"")?.upperBound,
              let end = matched[start...].firstIndex(of: "\"") else { return nil }
        let raw = String(matched[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw.removingPercentEncoding ?? raw
    }

    static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// fanqie/fanqie.go: browserHeaders（贴合 Chrome，降低被反爬误判）
    static func applyBrowserHeaders(to request: inout URLRequest) {
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("max-age=0", forHTTPHeaderField: "Cache-Control")
    }

    // MARK: - 工具

    /// 等价于旧版 EnsureServer：内核没起来时等待/拉起，不让 connection refused 冒到界面。
    func ensureServer() async throws {
        do {
            try await KernelManager.shared.ensureReady()
        } catch {
            throw FanqieError.kernelNotReady(KernelManager.shared.lastFailureMessage ?? "内核未就绪")
        }
    }
}
