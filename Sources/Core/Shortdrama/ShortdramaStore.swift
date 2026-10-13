import AppKit
import Foundation

/// 短剧 IP 界面联动状态（M3-b）。
///
/// 职责：把 `ShortdramaClient`（数据层，M3-a）接到界面上，但**永远不阻塞主流程**：
/// 任何后台查询失败都只落在本 store 的 `keychainNeedsFix` / `statusText` / `detailHint` 上，
/// 不抛错、不弹模态、不影响搜索/榜单/下载本身。
///
/// 旧版对照（`frontend/src/main.js`）：`sdActive`(:1187 开关判定) / `checkShortdramaBackend`(:538) /
/// `loadShortdramaStrip`(:1041) / `sdStatusFeedback`(:1169) / `showKeychainDialog`(:1119)。
@MainActor
final class ShortdramaStore: ObservableObject {
    static let shared = ShortdramaStore()

    /// 短剧模式是否开启：`!shortdramaIgnored && shortdramaPrompted`（旧版 `sdActive` main.js:1187）。
    /// **没被问过的用户不启用**（首次会问一次要不要开启）。
    var isEnabled: Bool {
        let settings = SettingsStore.shared.settings
        return !settings.shortdramaIgnored && settings.shortdramaPrompted
    }

    /// 首启询问弹窗是否显示（旧版 `#sd-first-backdrop` / `maybeShowShortdramaPrompt` main.js:1220）
    @Published var showFirstRunPrompt = false

    /// 钥匙串被 ACL 拦截 → 界面上给「钥匙串授权…」入口（只在用户点按钮后才执行修复）
    @Published private(set) var keychainNeedsFix = false

    /// M3-d：Safari cookie 库读被 TCC 拒 → 给「打开系统设置」入口（完全磁盘访问权限）
    @Published private(set) var needsFullDiskAccess = false

    /// M3-d：使用教程弹窗（用户打开开关 / 点检测登录态失败时给）
    @Published var showTutorial = false

    /// 设置页那行灰字：登录态反馈 / 失败原因（旧版 `sdStatusFeedback` 的非模态版）
    @Published private(set) var statusText = ""

    /// 番茄详情 IP 数据条（当前打开的书）
    @Published private(set) var detailHit: ShortdramaClient.ShortdramaIP?
    /// 详情里数据条加载失败时的提示（无登录态 / 会话失效 / 钥匙串）
    @Published private(set) var detailHint: String?
    @Published private(set) var detailLoading = false

    private var detailToken = UUID()

    /// 自检注入（只给 `m3b-hit` 用）：非 nil 时 `lookup` 直接用这份命中表，
    /// 用来在**没有真机登录态**时验证“命中 → 红标/角标/排最前/状态行计数”这条渲染链路。
    var debugInjectedHits: [String: ShortdramaClient.ShortdramaIP]?

    private init() {}

    // MARK: - 搜索 / 榜单：批量查后台

    /// 旧版 `checkShortdramaBackend`：逐本查，返回命中表（title → 最佳命中）。失败静默/只记标记。
    /// M10：输入带**番茄小说 ID** 的二元组；有 ID 先按 ID 查（后书名兜底），七猫只按书名。
    func lookup(books: [ShortdramaClient.BookQuery]) async -> [String: ShortdramaClient.ShortdramaIP] {
        guard isEnabled, !books.isEmpty else { return [:] }
        if let injected = debugInjectedHits {
            let titles = Set(books.map(\.title))
            let hits = injected.filter { titles.contains($0.key) }
            fmLog("短剧(注入) 查 \(books.count) 本，命中 \(hits.count) 本（自检注入，不走网络/钥匙串）")
            return hits
        }
        let started = Date()
        let batch = await ShortdramaClient.shared.searchBooks(books)
        if batch.keychainNeedsFix { keychainNeedsFix = true }
        if batch.needsFullDiskAccess {
            needsFullDiskAccess = true
            statusText = batch.sessionMessage
        }
        if let failure = batch.loginFailure { statusText = "短剧后台:\(failure)" }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        fmLog("短剧(搜索/榜单) 查 \(books.count) 本，命中 \(batch.hits.count) 本，耗时 \(elapsed)ms；无登录态=\(batch.sessionMissing) 钥匙串待授权=\(batch.keychainNeedsFix) 读钥匙串次数=\(ShortdramaSession.keychainReads)")
        return batch.hits
    }

    // MARK: - 番茄详情：IP 数据条

    /// 旧版 `loadShortdramaStrip`：查当前书，命中显示数据块；失败按类型给提示（非模态）。
    /// M10：番茄书带 ID → **先按小说 ID 查**（后台 `book_id=`），未命中回退书名。
    func loadDetail(bookID: String?, title: String) async {
        clearDetail()
        guard isEnabled else { return }
        let token = UUID()
        detailToken = token
        detailLoading = true
        defer { if detailToken == token { detailLoading = false } }
        let started = Date()
        do {
            var hit: ShortdramaClient.ShortdramaIP?
            // 自检注入（M11）：命中表里按书名/番茄 ID 取；用来在无登录态时渲染数据块（与 `lookup` 同一份注入表）
            if let injected = debugInjectedHits {
                hit = injected[title] ?? injected[bookID ?? ""]
            }
            if hit == nil, let bookID, !bookID.isEmpty {
                hit = try await ShortdramaClient.shared.searchByBookID(bookID)
            }
            if hit == nil {
                let items = try await ShortdramaClient.shared.search(title)
                hit = items.first
            }
            guard detailToken == token else { return }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            if let best = hit {
                detailHit = best
                fmLog("短剧(详情)《\(title)》命中 IP=\(best.ipBookID) 后台名=\(best.name) 上架=\(best.onlineMonth) 申请=\(best.selectedCnt) 改编中=\(best.adaptingCnt)（\(elapsed)ms）")
            } else {
                fmLog("短剧(详情)《\(title)》无命中（\(elapsed)ms）")
            }
        } catch {
            guard detailToken == token else { return }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            if ShortdramaKeychain.isKeychainAccessIssue(error) {
                keychainNeedsFix = true
                detailHint = "短剧IP数据未加载:钥匙串访问被拒绝，点「钥匙串授权」后自动重试"
            } else if let failure = error as? ShortdramaFailure, failure.kind == .needsFullDiskAccess {
                needsFullDiskAccess = true
                detailHint = failure.message
            } else if let failure = error as? ShortdramaFailure, failure.kind == .noSession {
                detailHint = "短剧IP数据未加载:请在 Safari 登录 www.shortdramas.com 后重试（也支持 Chrome/Edge 等 Chromium 浏览器）"
            } else {
                detailHint = "短剧IP数据未加载:" + error.localizedDescription
            }
            fmLog("短剧(详情)《\(title)》失败：\(error.localizedDescription)（\(elapsed)ms）")
        }
    }

    func clearDetail() {
        detailToken = UUID()
        detailHit = nil
        detailHint = nil
        detailLoading = false
    }

    // MARK: - M10：在后台打开该 IP

    /// 「在后台打开」：用默认浏览器打开短剧后台 IP 申请页，并把番茄小说 ID 带上。
    ///
    /// M11（用户拍板选丙）：详情页已**删掉「在后台打开」按钮**，界面不再有入口；
    /// 这个方法保留（以后若要恢复入口直接用），不再被任何视图调用。
    ///
    /// **实测说明（见 M10 报告）**：`ip-application` 页面自己的 bundle 只从 URL 读 `tab`，
    /// `book_id` 参数不会被预填（页面上的「改编网文BID」筛选项由组件状态驱动）。
    /// 参数照带（无害，后台以后支持就直接生效），页面本身 = IP 申请页。
    @discardableResult
    func openBackend(bookID: String) -> Bool {
        var comps = URLComponents(string: "https://www.shortdramas.com/page/ip-application")
        if !bookID.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "book_id", value: bookID)]
        }
        guard let url = comps?.url else { return false }
        let opened = NSWorkspace.shared.open(url)
        fmLog("短剧(详情) 在后台打开：\(url.absoluteString) opened=\(opened)")
        return opened
    }

    // MARK: - 首启询问（旧版 `SetShortdramaIgnored` app.go:313 + main.js:1220）

    /// 旧版 `SetShortdramaIgnored(ignored)`：任何一次用户显式选择都同时把 `shortdramaPrompted` 置 true。
    /// 设置页开关 / 首启询问 / 详情提示的「忽略」都走这里，保证只问一次。
    func setIgnored(_ ignored: Bool) {
        SettingsStore.shared.update {
            $0.shortdramaIgnored = ignored
            $0.shortdramaPrompted = true
        }
    }

    /// 旧版启动时的 `maybeShowShortdramaPrompt()`：没问过就弹一次。
    func maybeShowFirstRunPrompt() {
        showFirstRunPrompt = !SettingsStore.shared.settings.shortdramaPrompted
    }

    /// 询问里点「启用」：`SetShortdramaIgnored(false)` + 使用教程 + 一次登录态反馈（非模态灰字）。
    func acceptFirstRun() {
        setIgnored(false)
        showFirstRunPrompt = false
        showTutorial = true // 用户原话：打开后给教程引导去 Safari 登录
        Task { await refreshStatus() }
    }

    /// 询问里点「忽略」：`SetShortdramaIgnored(true)`。
    func declineFirstRun() {
        setIgnored(true)
        showFirstRunPrompt = false
    }

    // MARK: - 设置页开关：登录态反馈 + 授权

    /// 旧版 `sdStatusFeedback`：开启开关/点检测时校验一次登录态，结果写进 `statusText`（灰字，不弹窗）。
    /// 返回是否登录态正常（供设置页决定是否弹教程）。
    @discardableResult
    func refreshStatus() async -> Bool {
        guard isEnabled else { statusText = ""; return false }
        let status = await ShortdramaClient.shared.sessionStatus()
        if status.ok {
            keychainNeedsFix = false
            needsFullDiskAccess = false
            statusText = "登录态正常"
            fmLog("短剧(设置) 登录态反馈：ok=true")
            return true
        }
        if status.needsFullDiskAccess {
            needsFullDiskAccess = true
            statusText = status.message
        } else if status.keychainNeedsFix {
            keychainNeedsFix = true
            statusText = "钥匙串需要授权"
        } else {
            statusText = status.message
        }
        fmLog("短剧(设置) 登录态反馈：ok=false needsFix=\(status.keychainNeedsFix) needsFDA=\(status.needsFullDiskAccess) \(status.message)")
        return false
    }

    /// M3-d：打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」（用户点按钮后才调用）。
    @discardableResult
    func openFullDiskAccessSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return false }
        let opened = NSWorkspace.shared.open(url)
        fmLog("短剧(设置) 打开完全磁盘访问权限面板：\(opened)")
        return opened
    }

    /// **只在用户点「钥匙串授权…」并输入开机密码之后执行**（旧版 `FixKeychainAccess` 按钮）。
    func authorizeKeychain(password: String) async -> String? {
        do {
            _ = try await ShortdramaKeychain.fixKeychainAccess(password: password)
            keychainNeedsFix = false
            statusText = "钥匙串已授权"
            fmLog("短剧(设置) 钥匙串授权成功")
            return nil
        } catch {
            let message = error.localizedDescription
            fmLog("短剧(设置) 钥匙串授权失败：\(message)")
            return message
        }
    }
}
