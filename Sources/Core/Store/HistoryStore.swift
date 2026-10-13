import Foundation

/// 一条「最近查看」记录（M5）：搜索关键词 或 打开过的书籍详情。
/// 落盘 `~/Library/Application Support/novel-downloader/history.json`，与 settings/downloads 同目录。
struct FMHistoryRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable, Hashable {
        case search
        case detail
    }

    var kind: Kind
    /// 去重键：搜索 = 关键词；详情 = 书籍 ID
    var key: String
    /// 显示主文本：关键词 / 书名
    var title: String
    var author: String
    /// "fanqie" / "qimao"
    var platform: String
    /// 详情记录用：重新打开详情时带的书籍 ID（搜索记录为空）
    var bookID: String
    /// RFC3339（与 downloads.json 同一套时间格式）
    var time: String

    var id: String { "\(kind.rawValue)|\(key)" }
    var date: Date { FMFormat.parseISO(time) ?? .distantPast }

    /// 次要灰字里的平台小字（番茄小说 / 七猫）
    var platformDisplay: String {
        switch Platform(rawValue: platform) {
        case .qimao: return "七猫"
        case .fanqie: return "番茄小说"
        case nil: return platform
        }
    }

    /// 详情记录 → 重新打开详情用的 SearchItem（字段少；详情弹窗会自己再拉一次完整信息）
    var searchItem: SearchItem {
        SearchItem(
            platform: Platform(rawValue: platform) ?? .fanqie,
            bookID: bookID,
            title: title,
            author: author,
            abstract: "",
            score: "",
            words: "",
            hot: "",
            coverURL: nil
        )
    }
}

/// 「最近查看」历史记录的唯一写盘入口（M5）。
///
/// 规则（任务书第 4 节）：
///   · 记录两类：搜索执行成功（关键词）/ 打开详情页（书）；搜索失败不记。
///   · 去重：同一关键词 / 同一本书 7 天内只留最新一条（刷新时间并置顶）。
///   · 保留：只留近 7 天，最多 500 条兜底；启动时 + 每次写入时都清一遍。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    nonisolated static let retentionDays = 7
    nonisolated static let maxCount = 500

    @Published private(set) var records: [FMHistoryRecord] = []

    private let fileURL = FMAppPaths.historyFile

    private init() {
        let loaded = Self.load(from: fileURL)
        let pruned = Self.pruned(loaded)
        records = pruned
        // 手改/陈旧文件在启动时清掉过期与超量条目（数量变了才回写）
        if pruned.count != loaded.count { persist(pruned) }
    }

    /// 某个分段的记录（已按时间倒序）
    func records(of kind: FMHistoryRecord.Kind) -> [FMHistoryRecord] {
        records.filter { $0.kind == kind }
    }

    /// ① 搜索执行的记录（关键词；搜索失败不记）
    func recordSearch(keyword: String, platform: Platform) {
        insert(
            FMHistoryRecord(
                kind: .search,
                key: keyword,
                title: keyword,
                author: "",
                platform: platform.rawValue,
                bookID: "",
                time: LibraryStore.timestamp()
            ),
            label: "搜索"
        )
    }

    /// ② 打开详情页的记录（榜单 / 搜索 / 下载管理 / 最近查看都走这里）
    func recordDetail(bookID: String, title: String, author: String, platform: Platform) {
        insert(
            FMHistoryRecord(
                kind: .detail,
                key: bookID,
                title: title,
                author: author,
                platform: platform.rawValue,
                bookID: bookID,
                time: LibraryStore.timestamp()
            ),
            label: "详情"
        )
    }

    /// 「清空记录」：两个分段一起清（面板上只有这一个清理动作）
    func clear() {
        records = []
        persist(records)
        fmLog("最近查看：已清空全部记录")
    }

    /// 从磁盘重读 + 清理（自检注入旧记录后调用；正常使用由 init / insert 维护）
    func reload() {
        records = Self.pruned(Self.load(from: fileURL))
        persist(records)
    }

    // MARK: - 内部

    private func insert(_ record: FMHistoryRecord, label: String) {
        var next = records.filter { !($0.kind == record.kind && $0.key == record.key) }
        next.insert(record, at: 0)
        next = Self.pruned(next)
        records = next
        persist(next)
        fmLog("最近查看：记录\(label)「\(record.title)」@\(record.platformDisplay)，共 \(next.count) 条")
    }

    /// 近 7 天 + 同键去重 + 最多 500 条（按时间倒序）
    nonisolated static func pruned(_ input: [FMHistoryRecord]) -> [FMHistoryRecord] {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        var seen = Set<String>()
        var out: [FMHistoryRecord] = []
        for record in input.sorted(by: { $0.date > $1.date }) where record.date >= cutoff {
            let key = "\(record.kind.rawValue)|\(record.key)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(record)
            if out.count >= maxCount { break }
        }
        return out
    }

    private func persist(_ records: [FMHistoryRecord]) {
        do {
            try FileManager.default.createDirectory(at: FMAppPaths.legacySupport, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            fmLog("最近查看保存失败：\(error.localizedDescription)")
        }
    }

    nonisolated static func load(from url: URL) -> [FMHistoryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let decoded = try? JSONDecoder().decode([FMHistoryRecord].self, from: data) { return decoded }
        fmLog("最近查看无法解析：\(url.path)")
        return []
    }
}
