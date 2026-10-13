import Foundation

/// 文案与格式化（规格 7：全中文短句、字号用系统层级）。
enum FMFormat {
    /// 与旧版一致的产物文件名规则：`书名 作者 [ID].txt`（规格 2）。
    static func safeFilename(_ name: String) -> String {
        let stripped = name
            .replacingOccurrences(of: "[<>:\"/\\\\|?*]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return stripped.isEmpty ? "未知" : stripped
    }

    static func downloadFileName(title: String, author: String, bookID: String) -> String {
        "\(safeFilename(title)) \(safeFilename(author)) [\(safeFilename(bookID))].txt"
    }

    /// 5353368 → 535万字（与旧版一致）
    static func words(_ count: Int) -> String {
        count >= 10_000 ? String(format: "%.0f万字", Double(count) / 10_000) : "\(count)字"
    }

    static func score(_ value: Double?) -> String {
        guard let value, value > 0 else { return "暂无评分" }
        return String(format: "%.1f 分", value)
    }

    static func fileSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    static func shortTime(_ raw: String) -> String {
        guard let date = FMFormat.parseISO(raw) else { return raw }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// M5「最近查看」的相对时间：今天 14:20 / 昨天 20:15 / 10-09 20:15。
    static func relativeTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            f.dateFormat = "'今天' HH:mm"
        } else if calendar.isDateInYesterday(date) {
            f.dateFormat = "'昨天' HH:mm"
        } else {
            f.dateFormat = "MM-dd HH:mm"
        }
        return f.string(from: date)
    }

    static func parseISO(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
