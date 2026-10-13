import AppKit
import Foundation

/// 下载记录（与旧版 downloads.json 完全同构）。
struct FMDownloadRecord: Codable, Sendable, Equatable, Hashable, Identifiable {
    var path: String
    var title: String
    var author: String
    var format: String
    var platform: String
    var time: String

    var id: String { path }
}

/// 列表项（带磁盘现状）。旧版 Library() 会跳过已丢失的文件，
/// 这里保留并标记 exists=false，让用户能自己决定删记录还是留着。
struct LibraryItem: Identifiable, Hashable, Sendable {
    var id: String { record.path }
    let record: FMDownloadRecord
    let name: String
    let size: Int64
    let ext: String
    let exists: Bool

    var title: String { record.title }
    var author: String { record.author }
    var platform: String { record.platform }
    var date: Date { FMFormat.parseISO(record.time) ?? .distantPast }
    var path: URL { URL(fileURLWithPath: record.path) }
}

/// 下载记录的唯一写盘入口（规格第 3 节）。
/// 对照 `app.go: Library / RemoveLibraryItem / loadRecords / saveRecords / addRecord / OpenFolder`。
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var items: [LibraryItem] = []

    private let fileURL = FMAppPaths.downloadsFile

    private init() {
        reload()
    }

    func reload() {
        items = Self.load(from: fileURL).reversed().map { record in
            let url = URL(fileURLWithPath: record.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return LibraryItem(
                record: record,
                name: url.lastPathComponent,
                size: size,
                ext: url.pathExtension,
                exists: FileManager.default.fileExists(atPath: url.path)
            )
        }
    }

    /// app.go: addRecord
    func add(path: URL, title: String, author: String, platform: String, format: String = "txt") {
        var records = Self.load(from: fileURL)
        records.append(FMDownloadRecord(
            path: path.path,
            title: title,
            author: author,
            format: format,
            platform: platform,
            time: Self.timestamp()
        ))
        persist(records)
        reload()
    }

    /// app.go: RemoveLibraryItem(path, deleteFile)
    func remove(id: String, deleteFile: Bool) throws {
        var records = Self.load(from: fileURL)
        guard let index = records.firstIndex(where: { $0.path == id }) else {
            throw LibraryError.recordNotFound
        }
        if deleteFile {
            do {
                try FileManager.default.removeItem(atPath: id)
                fmLog("删除下载文件：\(id)")
            } catch {
                if !(error is CocoaError) { throw error }
            }
        }
        records.remove(at: index)
        persist(records)
        reload()
    }

    /// app.go: OpenFolder —— 文件用 open -R，目录直接打开。
    func revealInFinder(id: String) {
        let url = URL(fileURLWithPath: id)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    enum LibraryError: LocalizedError {
        case recordNotFound

        var errorDescription: String? { "未找到该下载记录" }
    }

    private func persist(_ records: [FMDownloadRecord]) {
        do {
            try FileManager.default.createDirectory(at: FMAppPaths.legacySupport, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            fmLog("下载记录保存失败：\(error.localizedDescription)")
        }
    }

    static func load(from url: URL) -> [FMDownloadRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let decoded = try? JSONDecoder().decode([FMDownloadRecord].self, from: data) { return decoded }
        fmLog("下载记录无法解析：\(url.path)")
        return []
    }

    /// 旧版 time 格式：RFC3339 带本地时区（2026-09-27T23:04:56+08:00）。
    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}
