import AppKit
import Foundation

/// 下载流水线（对照 `app.go: App.Download` + `fanqie/fanqie.go` 的
/// Download / relocateOutput / findOutput / isTargetFile / SafeFilename）。
///
/// 职责：建任务 → 轮询真实进度 → 找到内核产物 → 按 `书名 作者 [ID].txt` 改名搬到下载目录
/// → 登记到 LibraryStore（唯一写盘入口）。
@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()

    struct DownloadTask: Identifiable, Sendable {
        let id: UUID
        /// M2-b：任务来自哪个平台（决定走内核下载还是七猫直连下载）
        var platform: Platform = .fanqie
        var bookID: String
        var title: String
        var author: String
        var state: String          // 准备中… / 下载中 / 下载完成 / 失败 / 已取消
        var progress: DownloadProgress
        var message: String?
        var filePath: String?
        var startedAt: Date

        var isActive: Bool { state == "准备中" || state == "下载中" }
        var progressText: String {
            switch state {
            case "准备中": "准备中"
            case "下载完成": "下载完成"
            default: progress.text
            }
        }
    }

    @Published private(set) var tasks: [DownloadTask] = []

    private let service = KernelService.shared
    private var runners: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// 诊断钩子：`FQM_DOWNLOAD_LIMIT=3` 时只下前 3 章（0/缺省 = 全本）。
    /// 验收「下载前 3 章产出真实文件」用它，不影响正常使用。
    static var chapterLimit: Int? {
        guard let raw = ProcessInfo.processInfo.environment["FQM_DOWNLOAD_LIMIT"],
              let value = Int(raw), value > 0 else { return nil }
        return value
    }

    @discardableResult
    func start(bookID: String, title: String, author: String, platform: Platform = .fanqie) -> UUID {
        let task = DownloadTask(
            id: UUID(),
            platform: platform,
            bookID: bookID,
            title: title,
            author: author,
            state: "准备中",
            progress: DownloadProgress(saved: 0, total: 0),
            message: nil,
            filePath: nil,
            startedAt: Date()
        )
        tasks.append(task)
        let id = task.id
        runners[id] = Task { [weak self] in
            await self?.run(id: id)
            self?.runners[id] = nil
        }
        return id
    }

    func cancel(_ id: UUID) {
        runners[id]?.cancel()
        runners[id] = nil
        mutate(id) { if $0.isActive { $0.state = "已取消" } }
    }

    var activeCount: Int { tasks.filter(\.isActive).count }

    func task(for bookID: String) -> DownloadTask? {
        tasks.last { $0.bookID == bookID }
    }

    func activeTask(for bookID: String) -> DownloadTask? {
        tasks.last { $0.bookID == bookID && $0.isActive }
    }

    // MARK: - 下载主流程

    /// 契约风格入口：供界面/自检调用，返回产物路径。
    @discardableResult
    func download(
        id bookID: String,
        title: String,
        author: String,
        range: ClosedRange<Int>?,
        onProgress: (@MainActor (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        try await FanqieAPI.shared.ensureServer()
        let startedAt = Date()
        let jobID = try await service.createJob(
            bookID: bookID,
            start: range.map { $0.lowerBound },
            end: range.map { $0.upperBound }
        )
        fmLog("下载任务已创建：\(title) job=\(jobID)\(range.map { "（限第 \($0.lowerBound)-\($0.upperBound) 章）" } ?? "")")

        while !Task.isCancelled {
            let job: KernelJob?
            do { job = try await service.jobStatus(jobID) } catch { job = nil }
            guard let job else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let progress = DownloadProgress(saved: job.savedChapters, total: job.chapterTotal)
            onProgress?(progress)
            if job.isFinished { break }
            if job.isFailed {
                throw FanqieError.upstream(job.message ?? "下载失败")
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if Task.isCancelled { throw CancellationError() }

        let target = try await relocate(bookID: bookID, title: title, author: author, since: startedAt)
        LibraryStore.shared.add(path: target, title: title, author: author, platform: "fanqie")
        fmLog("下载完成：\(target.path)")
        return target
    }

    private func run(id: UUID) async {
        guard let snapshot = tasks.first(where: { $0.id == id }) else { return }
        let limit = Self.chapterLimit
        let range = limit.map { 1...$0 }
        do {
            mutate(id) { $0.state = "下载中" }
            // M12：内核只在收尾时才回报 total（下载过程中只给「已下载 N 章」）→
            // 限章下载时先用本次范围的上限做分母，按钮里的绿色填充 / 下载管理的进度条才能实时动起来。
            // （不限章的全本下载由详情页用书本章节总数做分母，见 `BookDetailView.DownloadButtonState.fraction`。）
            if snapshot.platform != .qimao, let total = range?.upperBound {
                mutate(id) { $0.progress = DownloadProgress(saved: $0.progress.saved, total: total) }
            }
            let onProgress: @MainActor (DownloadProgress) -> Void = { [weak self] progress in
                self?.mutate(id) { task in
                    // 内核在「抓章节」阶段只给 progress=null（total/saved 都是 0），
                    // 到「保存」阶段才报 saved_chapters/chapter_total。
                    // 所以 total=0 的上报不能把上面 seed 的范围上限洗掉。
                    let expected = task.progress.total
                    task.progress = progress.total > 0
                        ? progress
                        : DownloadProgress(saved: progress.saved, total: expected)
                }
            }
            let url: URL
            if snapshot.platform == .qimao {
                url = try await downloadQimao(
                    id: snapshot.bookID,
                    title: snapshot.title,
                    author: snapshot.author,
                    onProgress: onProgress
                )
            } else {
                url = try await download(
                    id: snapshot.bookID,
                    title: snapshot.title,
                    author: snapshot.author,
                    range: range,
                    onProgress: onProgress
                )
            }
            mutate(id) { task in
                task.state = "下载完成"
                task.filePath = url.path
                if task.progress.total == 0 { task.progress.total = task.progress.saved }
            }
        } catch {
            if Task.isCancelled {
                mutate(id) { if $0.isActive { $0.state = "已取消" } }
                return
            }
            let message = FriendlyError.text(error)
            mutate(id) { task in
                task.state = "失败"
                task.message = message
            }
            fmLog("下载失败（\(snapshot.title)）：\(message)")
        }
    }

    // MARK: - 产物查找与改名（fanqie.go: findOutput / isTargetFile / relocateOutput）

    enum DownloadError: LocalizedError {
        case outputNotFound
        case epubOnly

        var errorDescription: String? {
            switch self {
            case .outputNotFound: "内核报告下载完成，但没找到产物文件"
            case .epubOnly: "内核产出的是 EPUB；M1 只保存 TXT，请重试"
            }
        }
    }

    /// M2-b：七猫整本下载（qimao.go:659 Download）——详情 + 目录 + zip + 解密 + 写出 TXT/EPUB。
    /// 七猫产物直接落在下载目录（文件名规则与番茄一致：`书名 作者 [ID].txt|epub`），不需要搬运。
    @discardableResult
    func downloadQimao(
        id bookID: String,
        title: String,
        author: String,
        onProgress: (@MainActor (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        // M11：设置页已删「保存格式」→ 两个平台一律 TXT（旧配置文件里的 epub 不再生效；
        // `SettingsStore` 载入/写入时也会把 epub 归一为 txt，不存在「选了但没入口」的悬挂状态）。
        let format = "txt"
        let dir = SettingsStore.shared.downloadDir
        fmLog("七猫下载开始：《\(title)》id=\(bookID) 格式=\(format) → \(dir.path)")
        let url = try await QimaoClient.shared.download(bookID: bookID, outputDir: dir, format: format) { done, total in
            onProgress?(DownloadProgress(saved: done, total: total))
        }
        if Task.isCancelled { throw CancellationError() }
        LibraryStore.shared.add(path: url, title: title, author: author, platform: "qimao")
        fmLog("七猫下载完成：\(url.path)")
        return url
    }

    private func relocate(bookID: String, title: String, author: String, since: Date) async throws -> URL {
        let fm = FileManager.default
        guard let found = await findOutput(bookID: bookID, title: title, since: since) else {
            throw DownloadError.outputNotFound
        }
        if found.pathExtension.lowercased() == "epub" { throw DownloadError.epubOnly }

        let target = SettingsStore.shared.downloadDir
            .appending(path: FMFormat.downloadFileName(title: title, author: author, bookID: bookID))
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if found.standardizedFileURL == target.standardizedFileURL { return target }
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        do {
            try fm.moveItem(at: found, to: target)
        } catch {
            try fm.copyItem(at: found, to: target) // 跨卷时退化为 copy
            try? fm.removeItem(at: found)
        }
        return target
    }

    /// 旧版会在「库根目录（递归）+ 内核数据目录 + 暂存目录 + ~/Downloads + ~/downloads」里找产物。
    /// 额外加一层「产物必须是本次任务之后写的」过滤，避免把上一本同名书当成新产物。
    private func findOutput(bookID: String, title: String, since: Date) async -> URL? {
        var directories: [URL] = []
        if let libraryRoot = await libraryRootDirectory() { directories.append(libraryRoot) }
        directories.append(FMAppPaths.kernelDataDir)
        directories.append(FMAppPaths.kernelStaging)
        directories.append(FMAppPaths.home.appending(path: "Downloads"))
        directories.append(FMAppPaths.home.appending(path: "downloads"))

        var newest: (url: URL, date: Date)?
        for (index, directory) in directories.enumerated() {
            let recursive = index == 0
            for candidate in files(in: directory, recursive: recursive) {
                guard Self.isTargetFile(candidate.lastPathComponent, bookID: bookID, title: title) else { continue }
                let modified = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard modified >= since.addingTimeInterval(-10) else { continue }
                if newest == nil || modified > newest!.date { newest = (candidate, modified) }
            }
        }
        return newest?.url
    }

    private func files(in directory: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard recursive else {
            return (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    /// fanqie.go: isTargetFile
    static func isTargetFile(_ name: String, bookID: String, title: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext == "txt" || ext == "epub" else { return false }
        let stem = (name as NSString).deletingPathExtension
        return stem.contains(title) || stem.contains(bookID)
    }

    /// 内核 /api/library 的 root（旧版 findOutput 的第一顺位）。
    private func libraryRootDirectory() async -> URL? {
        guard let json = try? await KernelService.shared.library(),
              let root = json["root"]?.looseString, !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root)
    }

    private func mutate(_ id: UUID, _ change: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }
}
