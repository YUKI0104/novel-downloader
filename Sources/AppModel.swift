import AppKit
import Foundation
import SwiftUI

/// ViewModel 层（对照 `app.go` 的编排：Search / BookInfo / Download / Library / Settings
/// 的调用顺序与用户可见文案）。
@MainActor
final class AppModel: ObservableObject {
    enum Overlay: Equatable {
        case downloads
        case settings
        case kernelIssue
        /// M5：最近查看（搜索记录 / 详情记录）
        case history
    }

    enum SearchState: Equatable {
        case idle
        case searching
        case results
        case empty
        case failed(String)
    }

    /// 主页面视图：默认榜单（旧版主页默认就是榜单），搜索后切到结果视图
    enum MainView: Equatable { case rank, search, adapt }

    @Published var mainView: MainView = .rank
    @Published var searchText = ""
    @Published var results: [SearchItem] = []
    @Published var searchState: SearchState = .idle
    @Published var searchStatus = ""
    @Published var searchStatusIsError = false

    // 榜单（对照旧版 main.js:128-266 的 rankGroups/rankChannel/rankType/rankGenreURL）
    @Published var rankGroups: [RankGroup] = []
    @Published var rankChannel = "hot"        // hot | 男频 | 女频
    @Published var rankType = "1"             // 1=阅读榜 2=新书榜
    @Published var rankGenreIndex = 0
    @Published var rankBooks: [SearchItem] = []
    @Published var rankStatus = ""
    @Published var rankStatusIsError = false
    /// M13：榜单请求进行中（刷新按钮据此显示加载态并禁用，防连点并发）
    @Published private(set) var rankIsLoading = false
    /// M13 取证：真正发起的榜单抓取次数（自检用它证明「连点两次只发一次请求」）
    private(set) var rankRequestCount = 0
    /// M13 取证：最近一次榜单抓取耗时（ms）
    private(set) var lastRankDurationMs = 0
    private var rankLoadedOnce = false
    @Published var selected: SearchItem?
    @Published var activeOverlay: Overlay?
    /// M5：「最近查看」弹窗当前分段（默认搜索记录）
    @Published var historySegment: FMHistoryRecord.Kind = .search
    @Published var toast: String?
    /// 删除确认弹窗（旧版 #confirm-backdrop 独立一层）
    @Published var pendingDeletion: LibraryItem?

    let kernel = KernelManager.shared
    let downloads = DownloadCenter.shared
    let settings = SettingsStore.shared
    let library = LibraryStore.shared

    private var didLaunch = false

    // MARK: - M3-b 短剧后台命中
    /// 当前搜索/榜单命中短剧后台的本数（取证用；0 = 未命中或短剧模式关闭）
    @Published private(set) var shortdramaHits = 0
    private var searchToken = UUID()
    private var rankToken = UUID()

    // MARK: - 启动（app.go: startup）

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        FMAppPaths.ensureDirectories()
        KernelManager.shared.onFatalFailure = {
            await KernelUpdater.shared.check(reason: .kernelUnhealthy)
        }
        // 内核在后台预热（旧版 startup 也是异步预热内核，避免第一次搜索干等），
        // 内核就绪后加载主页默认榜单（旧版 startup → initRank）
        Task { [kernel] in
            await kernel.start()
            await loadRankIfNeeded()
        }
        kernel.startUpdateSchedule()
        // M3-c：旧版启动时 `maybeShowShortdramaPrompt()`（没被问过才弹）
        ShortdramaStore.shared.maybeShowFirstRunPrompt()
    }

    // MARK: - 榜单（旧版 initRank / selectChannel / setupFanqieGenres / onRankTypeChange）

    var currentRankGroup: RankGroup? {
        rankGroups.first { $0.gender == rankChannel }
    }

    var currentRankGenre: RankGenre? {
        guard let genres = currentRankGroup?.genres, genres.indices.contains(rankGenreIndex) else { return nil }
        return genres[rankGenreIndex]
    }

    /// 当前应抓的榜单页 URL：综合热榜 = /rank；其余按 题材 × 榜单类型 取
    var currentRankURL: String? {
        if rankChannel == "hot" {
            let hot = rankGroups.first { $0.gender == "综合" }?.hotURL
            return (hot?.isEmpty == false ? hot : FanqieRank.rankBaseURL + "/rank")
        }
        guard let genre = currentRankGenre else { return nil }
        return rankType == "1" ? genre.readURL : genre.newURL
    }

    func rankLabel() -> String {
        if PlatformStore.shared.platform == .qimao {
            let name = Self.qimaoTypeNames[qimaoRankType] ?? "大热"
            return "\(qimaoIsGirl == "0" ? "男生" : "女生") · \(name) · 七猫"
        }
        if rankChannel == "hot" { return "综合热榜 · 番茄" }
        return "\(rankChannel)·\(rankType == "1" ? "阅读" : "新书")"
    }

    /// 进 App 时加载一次（旧版 initRank）
    func loadRankIfNeeded() async {
        guard !rankLoadedOnce else { return }
        rankLoadedOnce = true
        if PlatformStore.shared.platform == .qimao {
            // 七猫榜单不需要番茄那套「频道/题材」目录
            await reloadRank()
            return
        }
        do {
            // M3-g：榜单频道页也是榜单请求，同一套自动重试（1/2/4s）
            rankStatus = "加载榜单中"
            rankStatusIsError = false
            let groups = try await NetworkRetry.run(
                label: "榜单",
                onRetry: { [weak self] attempt in
                    self?.rankStatus = NetworkRetry.retryText(attempt)
                    self?.rankStatusIsError = false
                },
                isCancelled: { PlatformStore.shared.platform != .fanqie },
                operation: { try await FanqieRank.shared.categories() }
            )
            guard PlatformStore.shared.platform == .fanqie else { return }
            rankGroups = groups
            fmLog("榜单已加载：\(rankGroups.map { "\($0.gender)(\($0.genres.count))" }.joined(separator: " "))")
        } catch {
            guard PlatformStore.shared.platform == .fanqie else { return }
            rankStatus = "榜单加载失败: \(AppModel.friendlyMessage(for: error))"
            rankStatusIsError = true
            return
        }
        await reloadRank()
    }

    /// M2-b：平台切换后重置搜索/榜单状态并按新平台重取榜单
    func platformChanged() async {
        results = []
        searchText = ""
        searchState = .idle
        searchStatus = ""
        selected = nil
        mainView = .rank
        rankBooks = []
        rankStatus = ""
        rankStatusIsError = false
        shortdramaHits = 0
        searchToken = UUID()
        rankToken = UUID()
        // 七猫没有「综合热榜」，切成男生榜；番茄回到综合热榜
        rankChannel = PlatformStore.shared.platform == .qimao ? "男频" : "hot"
        rankType = "1"
        rankGenreIndex = 0
        rankLoadedOnce = false
        adaptBooks = []
        adaptTotal = 0
        adaptPage = 1
        adaptStatus = ""
        adaptLoadedOnce = false
        await loadRankIfNeeded()
    }

    // MARK: - 七猫改编书单（M2-b：qimao.go:487 AdaptRankConfig / :509 AdaptBookList）

    @Published var adaptGroups: [QimaoModels.AdaptFilterGroup] = []
    @Published var adaptBooks: [SearchItem] = []
    @Published var adaptTotal = 0
    @Published var adaptPage = 1
    @Published var adaptStatus = ""
    @Published var adaptStatusIsError = false
    @Published var adaptFilter = QimaoModels.AdaptFilter()
    private var adaptLoadedOnce = false

    /// 进改编书单：先拿筛选菜单，再取第一页
    func loadAdaptIfNeeded() async {
        if adaptGroups.isEmpty {
            do {
                adaptGroups = try await QimaoClient.shared.adaptRankConfig()
                fmLog("改编书单筛选组已加载：\(adaptGroups.count) 组")
            } catch {
                adaptStatus = "加载筛选条件失败: \(AppModel.friendlyMessage(for: error))"
                adaptStatusIsError = true
                return
            }
        }
        guard !adaptLoadedOnce else { return }
        adaptLoadedOnce = true
        await reloadAdapt()
    }

    func reloadAdapt() async {
        adaptStatus = "加载改编书单中"
        adaptStatusIsError = false
        var filter = adaptFilter
        filter.page = adaptPage
        do {
            let (books, total) = try await QimaoClient.shared.adaptBookList(filter)
            guard PlatformStore.shared.platform == .qimao else { return }
            adaptBooks = books.map(QimaoBridge.searchItem)
            adaptTotal = total
            adaptStatus = adaptBooks.isEmpty ? "暂无数据" : "共 \(total) 本 · 第 \(adaptPage) 页"
            fmLog("改编书单第 \(adaptPage) 页：\(books.count) 条 / 总数 \(total)")
        } catch {
            adaptBooks = []
            adaptStatus = "改编书单加载失败: \(AppModel.friendlyMessage(for: error))"
            adaptStatusIsError = true
        }
    }

    /// 换筛选条件（key = 菜单 key，value = 选项 value）→ 回到第 1 页重取
    func selectAdaptFilter(key: String, value: String) async {
        switch key {
        case "direction": adaptFilter.direction = value
        case "channel": adaptFilter.channel = value
        case "category": adaptFilter.category = value
        case "words": adaptFilter.words = value
        case "is_over": adaptFilter.isOver = value
        case "ranking_type": adaptFilter.rankingType = value
        default: return
        }
        adaptPage = 1
        await reloadAdapt()
    }

    func adaptPage(delta: Int) async {
        let next = adaptPage + delta
        guard next >= 1 else { return }
        // 还有下一页：本页满 20 条就允许继续翻（总数只做展示，接口 count 恒为 10000 不参与判断）
        if delta > 0 && adaptBooks.isEmpty { return }
        adaptPage = next
        await reloadAdapt()
    }

    /// 七猫榜单参数（旧版 main.js:213-217：hot → 男生+大热；男频=0 女频=1）
    var qimaoIsGirl: String { rankChannel == "女频" ? "1" : "0" }
    var qimaoRankType: String { ["1", "2", "3", "4", "6"].contains(rankType) ? rankType : "1" }
    private static let qimaoTypeNames = ["1": "大热", "2": "新书", "3": "完结", "4": "收藏", "6": "更新"]

    func selectRankChannel(_ channel: String) async {
        rankChannel = channel
        rankGenreIndex = 0 // 旧版：切频道后取该频道第一个题材
        await reloadRank()
    }

    func selectRankType(_ type: String) async {
        rankType = type
        await reloadRank()
    }

    func selectRankGenre(_ index: Int) async {
        rankGenreIndex = index
        await reloadRank()
    }

    /// M13：点「刷新榜单」= 重新拉取**当前频道**榜单（综合/男频/女频不变，仍 TOP10），
    /// 完成后刷新卡片（短剧开关开着时由 loadFanqieRank 照旧按 ID 重查角标）。
    /// 请求进行中直接忽略这次点击 —— 按钮此时也是 disabled，这里再兜一层防并发。
    func refreshRank() async {
        if rankIsLoading {
            fmLog("刷新榜单：上一次榜单请求还在进行中，忽略本次点击（防连点并发）")
            return
        }
        fmLog("刷新榜单：重新拉取当前频道榜单 channel=\(rankChannel) type=\(rankType) genre=\(rankGenreIndex)（跳过 60s 缓存）")
        await reloadRank(forceRefresh: true)
    }

    /// M13：榜单请求开始（计数 + 置加载态；番茄/七猫两条路径共用）
    private func beginRankRequest() {
        rankRequestCount += 1
        rankIsLoading = true
    }

    /// M13：榜单请求结束。只有「当前 token 仍是发起它的那次请求」时才清加载态：
    /// 若请求途中用户切了频道/平台（新请求已换 token），不能把新请求的加载态误清掉。
    private func endRankRequest(token: UUID) {
        guard rankToken == token else { return }
        rankIsLoading = false
    }

    /// 旧版 loadRank(url)：状态位先「加载榜单…」，成功 TOP n · 标签，失败「加载榜单失败: <原因>」
    /// M3-g：失败自动重试最多 3 次（1/2/4s），重试期间状态行给「网络不稳，正在重试 n/3…」
    func reloadRank(forceRefresh: Bool = false) async {
        rankToken = UUID()
        let token = rankToken
        if PlatformStore.shared.platform == .qimao {
            await reloadQimaoRank(token: token)
            return
        }
        guard let url = currentRankURL, !url.isEmpty else {
            rankBooks = []
            rankStatus = "暂无数据"
            rankStatusIsError = false
            return
        }
        await loadFanqieRank(url: url, token: token, forceRefresh: forceRefresh)
    }

    /// M3-g 取证：走与 reloadRank 完全相同的加载路径（含自动重试），只把榜单 URL 换成传入值。
    /// 不动接口/频道/排序，仅供自检制造失败态。
    func debugReloadRankRetry(url: String) async {
        rankToken = UUID()
        await loadFanqieRank(url: url, token: rankToken)
    }

    /// 番茄榜单加载核心（重试策略见 NetworkRetry；成功/失败文案与旧版一致）
    private func loadFanqieRank(url: String, token: UUID, forceRefresh: Bool = false) async {
        rankStatus = "加载榜单中"
        rankStatusIsError = false
        rankBooks = []
        beginRankRequest()
        defer { endRankRequest(token: token) }
        let started = Date()
        do {
            let books = try await NetworkRetry.run(
                label: "榜单",
                onRetry: { [weak self] attempt in
                    guard let self, self.rankToken == token else { return }
                    self.rankStatus = NetworkRetry.retryText(attempt)
                    self.rankStatusIsError = false
                },
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return self.rankToken != token || PlatformStore.shared.platform != .fanqie
                },
                operation: { try await FanqieRank.shared.books(rankURL: url, forceRefresh: forceRefresh) }
            )
            // M2-b：抓取期间用户可能已经切到七猫 —— 旧平台的在途结果不许覆盖新平台
            guard rankToken == token, PlatformStore.shared.platform == .fanqie else {
                fmLog("榜单结果已过期（平台已切到 \(PlatformStore.shared.platform.displayName)），丢弃番茄榜单")
                return
            }
            rankBooks = books
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastRankDurationMs = ms
            if books.isEmpty {
                rankStatus = "暂无数据"
            } else {
                rankStatus = "TOP \(books.count) · \(rankLabel())"
            }
            fmLog("榜单耗时 \(ms)ms  url=\(url)  条数=\(books.count)")
            scheduleShortdramaEnrich(rank: true)
        } catch {
            guard rankToken == token, PlatformStore.shared.platform == .fanqie else { return }
            rankStatus = "榜单加载失败: \(AppModel.friendlyMessage(for: error))"
            rankStatusIsError = true
            fmLog("榜单加载失败 url=\(url): \(error.localizedDescription)")
        }
    }

    /// 取证用：用指定 URL 加载一次榜单（只为制造失败态，不动抓取逻辑）
    func debugLoadRank(badURL: String) async {
        rankStatus = "加载榜单…"
        rankStatusIsError = false
        rankBooks = []
        do {
            rankBooks = try await FanqieRank.shared.books(rankURL: badURL)
            rankStatus = rankBooks.isEmpty ? "暂无数据" : "TOP \(rankBooks.count) · \(rankLabel())"
        } catch {
            rankStatus = "榜单加载失败: \(AppModel.friendlyMessage(for: error))"
            rankStatusIsError = true
        }
    }

    /// 七猫榜单（qimao.go:398 RankingBooks：is_girl + rank_type，官网接口直接返回 20 条）
    /// M3-g：与番茄榜单同一套自动重试（3 次，1/2/4s）
    private func reloadQimaoRank(token: UUID) async {
        rankStatus = "加载榜单中"
        rankStatusIsError = false
        beginRankRequest()
        defer { endRankRequest(token: token) }
        let startedAt = Date()
        do {
            let isGirl = qimaoIsGirl
            let rankType = qimaoRankType
            let books = try await NetworkRetry.run(
                label: "榜单",
                onRetry: { [weak self] attempt in
                    guard let self, self.rankToken == token else { return }
                    self.rankStatus = NetworkRetry.retryText(attempt)
                    self.rankStatusIsError = false
                },
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return self.rankToken != token || PlatformStore.shared.platform != .qimao
                },
                operation: { try await QimaoClient.shared.rankingBooks(isGirl: isGirl, rankType: rankType) }
            )
            guard rankToken == token, PlatformStore.shared.platform == .qimao else {
                fmLog("榜单结果已过期（平台已切到 \(PlatformStore.shared.platform.displayName)），丢弃七猫榜单")
                return
            }
            rankBooks = books.map(QimaoBridge.searchItem)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastRankDurationMs = ms
            rankStatus = rankBooks.isEmpty ? "暂无数据" : "TOP \(rankBooks.count) · \(rankLabel())"
            fmLog("七猫榜单已加载：is_girl=\(qimaoIsGirl) rank_type=\(qimaoRankType) \(rankBooks.count) 条，耗时 \(ms)ms")
            scheduleShortdramaEnrich(rank: true)
        } catch {
            guard rankToken == token, PlatformStore.shared.platform == .qimao else { return }
            rankBooks = []
            rankStatus = "榜单加载失败: \(AppModel.friendlyMessage(for: error))"
            rankStatusIsError = true
        }
    }

    /// 搜索后「返回榜单」（旧版 btn-back-rank）
    func backToRank() async {
        mainView = .rank
        searchText = ""
        searchStatus = ""
        searchStatusIsError = false
        await reloadRank()
    }

    // MARK: - 搜索（app.go: App.Search）

    func submitSearch() async {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchState = .idle
            results = []
            return
        }
        mainView = .search // 旧版：搜索时隐藏默认榜单，切到结果视图
        let token = UUID()
        searchToken = token
        shortdramaHits = 0
        searchState = .searching
        results = []
        searchStatus = "正在搜索「\(keyword)」中"
        searchStatusIsError = false
        do {
            let platform = PlatformStore.shared.platform
            // M3-g：网络抖动自动重试最多 3 次（1/2/4s），重试期间状态行给可感知反馈
            let items: [SearchItem] = try await NetworkRetry.run(
                label: "搜索",
                onRetry: { [weak self] attempt in
                    guard let self, self.searchToken == token else { return }
                    self.searchStatus = NetworkRetry.retryText(attempt)
                    self.searchStatusIsError = false
                },
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    return self.searchToken != token || PlatformStore.shared.platform != platform
                },
                shouldRetry: { error in
                    // 「未找到结果 / 未找到 ID」是正常业务结果，不是网络抖动：保持原来的快速失败，不拖长等待
                    if let fanqie = error as? FanqieError, case .notFound = fanqie { return false }
                    return !FriendlyError.text(error).contains("未找到")
                },
                operation: {
                    switch platform {
                    case .qimao: return try await QimaoBridge.search(keyword)
                    case .fanqie: return try await FanqieAPI.shared.search(keyword)
                    }
                }
            )
            guard searchToken == token else { return }
            results = items
            searchState = items.isEmpty ? .empty : .results
            if items.isEmpty {
                searchStatus = "未找到相关书籍"
                searchStatusIsError = true
            } else {
                searchStatus = "共 \(items.count) 条结果 · 点击查看详情"
                searchStatusIsError = false
                scheduleShortdramaEnrich(rank: false, token: token)
            }
            // M5.1 语义「甲」：按 ID 直达 / 书页链接直达**不进搜索记录**（不记那串数字/网址），
            // 只按解析出来的书名记一条「详情记录」；关键词搜索仍只记用户真敲的词。
            // 失败不记；空结果也属于执行成功。
            if Self.directBookID(keyword, platform: platform) != nil, let book = items.first {
                HistoryStore.shared.recordDetail(
                    bookID: book.bookID,
                    title: book.title,
                    author: book.author,
                    platform: platform
                )
            } else {
                HistoryStore.shared.recordSearch(keyword: keyword, platform: platform)
            }
        } catch {
            guard searchToken == token else { return }
            let message = Self.friendlyMessage(for: error)
            searchState = .failed(message)
            searchStatus = "搜索失败: \(message)"
            searchStatusIsError = true
        }
    }

    /// M5.1：关键词是不是「按 ID / 书页链接直达」（这类不记搜索记录，只记详情记录）。
    /// 与数据层 `FanqieAPI.extractBookID` / `QimaoSign.extractBookID` 的判定保持一致。
    static func directBookID(_ keyword: String, platform: Platform) -> String? {
        switch platform {
        case .fanqie:
            return FanqieAPI.extractBookID(from: keyword)
        case .qimao:
            let normalized = QimaoSign.extractBookID(keyword)
            return QimaoSign.isAllDigits(normalized) && normalized.count >= 5 ? normalized : nil
        }
    }

    // MARK: - M3-b 短剧后台（尽力而为，不阻塞主流程）

    /// 正式启动一次短剧后台查（搜索/榜单）：参数不满足/失败都不会影响主流程。
    /// - Parameter rank: true = 榜单（**完全不重排**）；false = 搜索结果（命中稳定前置）
    private func scheduleShortdramaEnrich(rank: Bool, token: UUID? = nil) {
        guard ShortdramaStore.shared.isEnabled else { shortdramaHits = 0; return }
        let token = token ?? rankToken
        Task { [weak self] in
            await self?.enrichShortdrama(rank: rank, token: token)
        }
    }

    /// 旧版 `checkShortdramaBackend` + `sortList`：逐本查 → 命中高亮字段 → 重排 → 状态行追计数。
    private func enrichShortdrama(rank: Bool, token: UUID) async {
        let snapshot = rank ? rankBooks : results
        guard !snapshot.isEmpty else { return }
        // M10：番茄书带上小说 ID（先按 ID 查），七猫书没有番茄 ID（传 nil → 只按书名）
        let queries = snapshot.map { item in
            ShortdramaClient.BookQuery(id: item.platform == .fanqie ? item.bookID : nil, title: item.title)
        }
        let hits = await ShortdramaStore.shared.lookup(books: queries)
        guard (rank ? rankToken : searchToken) == token else {
            fmLog("短剧结果已过期（已换平台/重新搜索），丢弃")
            return
        }
        guard !hits.isEmpty else { return }

        var updated = snapshot
        for index in updated.indices {
            guard let hit = hits[updated[index].title] else { continue }
            updated[index].sdInBackend = true
            updated[index].sdOnlineMonth = hit.onlineMonth
            updated[index].sdApply = Int(hit.selectedCnt) ?? 0
            updated[index].sdShelved = Int(hit.shelvedCnt) ?? 0
            updated[index].sdAdapting = Int(hit.adaptingCnt) ?? 0
        }
        if rank {
            // M10 Q1 乙：榜单页**完全保持番茄原排名**（TOP 10 就是 TOP 10），
            // 命中只体现在红框 + 角标 + 状态行计数上，禁止再 filter(命中)+filter(未命中) 重排。
            rankBooks = updated
        } else {
            // M10 Q2 乙：搜索页只把命中的书**稳定前置**（组内保持番茄原相对顺序）。
            results = Self.shortdramaSearchOrder(updated)
        }
        shortdramaHits = hits.count
        if rank {
            rankStatus = "TOP \(rankBooks.count) · \(rankLabel()) · \(hits.count) 本在短剧后台"
        } else {
            searchStatus = "共 \(results.count) 条结果 · \(hits.count) 本在短剧后台"
        }
        fmLog("短剧命中 \(hits.count) 本，状态行已追计数")
    }

    /// M10 Q2 乙：搜索页排序——只把命中的书**稳定前置**。
    /// 命中组内、未命中组内各自保持传入顺序（即番茄原相对顺序）；已删除旧的多级排序
    /// （上架月份→在读→字数→改编中→被挑选）。
    static func shortdramaSearchOrder(_ items: [SearchItem]) -> [SearchItem] {
        items.filter(\.sdInBackend) + items.filter { !$0.sdInBackend }
    }

    /// 内核没就绪时不把 connection refused 抛给用户（规格 5.3）。
    static func friendlyMessage(for error: Error) -> String {
        if let kernelError = error as? KernelServiceError, kernelError.isKernelUnavailable {
            return "内核正在启动，请稍候再试"
        }
        return FriendlyError.text(error)
    }

    // MARK: - 详情（app.go: App.BookInfo + frontend 的 openDetail）

    func openDetail(_ item: SearchItem) {
        // M5：凡打开详情（榜单 / 搜索 / 下载管理 / 最近查看）都记一条「详情记录」
        HistoryStore.shared.recordDetail(
            bookID: item.bookID,
            title: item.title,
            author: item.author,
            platform: item.platform
        )
        withAnimation(.snappy(duration: 0.35)) { selected = item }
    }

    // MARK: - M5 最近查看

    /// 点一条「最近查看」：先切回记录时的平台（番茄/七猫），再重搜关键词 / 重开详情，最后关弹窗。
    func openHistory(_ record: FMHistoryRecord) async {
        let target = Platform(rawValue: record.platform) ?? .fanqie
        withAnimation(.easeOut(duration: 0.18)) { activeOverlay = nil }
        if PlatformStore.shared.platform != target {
            PlatformStore.shared.set(target)
            await platformChanged()
        }
        switch record.kind {
        case .search:
            fmLog("最近查看：重搜「\(record.title)」（\(target.displayName)）")
            searchText = record.title
            await submitSearch()
        case .detail:
            fmLog("最近查看：打开详情《\(record.title)》（\(target.displayName)）")
            openDetail(record.searchItem)
        }
    }

    /// 自检用：当前详情简介的字数（M1.11 取证）
    var detailDescriptionLength: Int { detailInfo?.description.count ?? -1 }
    /// 自检用：最近一次加载到的详情
    static var lastDetailInfo: BookInfo?
    var detailInfo: BookInfo? { Self.lastDetailInfo }

    func closeDetail() {
        withAnimation(.snappy(duration: 0.25)) { selected = nil }
    }

    // MARK: - 全局 Esc（M1.8：旧版 window keydown 的等价物）

    /// 按层级从最上层往下关一层：删除确认(3) → 详情(2) → 设置/下载管理/内核问题(1)。
    /// 返回是否关掉了一层（没弹窗返回 false，事件照常放行）。
    @discardableResult
    func closeTopmostByEscape() -> Bool {
        if pendingDeletion != nil {
            pendingDeletion = nil
            fmLog("全局 Esc：关闭最上层弹窗 删除确认")
            return true
        }
        if selected != nil {
            withAnimation(.snappy(duration: 0.25)) { selected = nil }
            fmLog("全局 Esc：关闭最上层弹窗 详情")
            return true
        }
        if let overlay = activeOverlay {
            withAnimation(.easeOut(duration: 0.18)) { activeOverlay = nil }
            fmLog("全局 Esc：关闭最上层弹窗 \(Self.overlayName(overlay))")
            return true
        }
        return false
    }

    private static func overlayName(_ overlay: Overlay) -> String {
        switch overlay {
        case .downloads: return "下载管理"
        case .settings: return "设置"
        case .kernelIssue: return "内核问题"
        case .history: return "最近查看"
        }
    }

    // MARK: - 下载（app.go: App.Download）

    func startDownload(title: String, author: String, bookID: String, platform: Platform = .fanqie) {
        downloads.start(bookID: bookID, title: title, author: author, platform: platform)
        showToast("已加入下载：\(title)")
    }

    // MARK: - 杂项

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == text { toast = nil }
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealDownloadDirectory() {
        NSWorkspace.shared.open(settings.downloadDir)
    }

    func openLogs() {
        NSWorkspace.shared.open(FMAppPaths.logsDir)
    }

    /// 打开内核日志所在目录（设置页「导出日志」：旧版是 reveal 日志文件并带上内核日志）
    func exportDiagnostics() {
        fmLog("用户导出诊断日志")
        let fileManager = FileManager.default
        let exportDir = FMAppPaths.appSupport.appending(path: "diagnostics")
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: exportDir.appending(path: "app.log"))
        try? fileManager.copyItem(at: URL(fileURLWithPath: FMLog.shared.path), to: exportDir.appending(path: "app.log"))
        for (source, name) in [
            (FMAppPaths.kernelDataDir.appending(path: "logs/latest.log"), "kernel.log"),
            (FMAppPaths.logsDir.appending(path: "kernel.stdout.log"), "kernel.stdout.log"),
        ] where fileManager.fileExists(atPath: source.path) {
            try? fileManager.removeItem(at: exportDir.appending(path: name))
            try? fileManager.copyItem(at: source, to: exportDir.appending(path: name))
        }
        NSWorkspace.shared.activateFileViewerSelecting([exportDir])
    }
}
