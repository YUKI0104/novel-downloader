import Foundation

/// 内核层对外契约（`docs/contracts-m1.md` 第 1 节，B/C 只读使用）。
/// 契约文件：A 拥有 `Core/Kernel/**`；B/C 不要改这里的文件。

/// 顶栏状态胶囊读它。
enum KernelPhase: Equatable {
    case stopped
    case starting
    case updating
    case ready
    case failed(String)

    /// 中文短句（界面直接用，别在各处重复写文案）。
    var displayText: String {
        switch self {
        case .stopped: "内核未启动"
        case .starting: "内核正在启动…"
        case .updating: "内核正在更新…"
        case .ready: "内核就绪"
        case .failed: "内核未就绪"
        }
    }

    var isBusy: Bool { self == .starting || self == .updating }
    var isReady: Bool { self == .ready }
}

/// 设置页那行灰字读它。
enum KernelUpdateState: Equatable {
    case idle
    case checking
    /// progress ∈ 0…1
    case downloading(progress: Double)
    /// 本地已是最新（远端不高于本地）
    case upToDate
    case updated(String)
    case failed(String)
}

/// 内核自动更新：状态只写进 `KernelManager.shared.update`，不弹窗、不打扰（规格 6.4/6.5）。
@MainActor
final class KernelUpdater {
    static let shared = KernelUpdater()

    private var isChecking = false
    private var timerTask: Task<Void, Never>?
    private var lastCheck: Date?

    private init() {}

    /// 启动后 30s、之后每 24h 自动检查（规格 6.2）。
    func startSchedule() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.check(reason: .launch)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard !Task.isCancelled else { return }
                await self?.check(reason: .scheduled)
            }
        }
    }

    /// 设置页那行灰字：`番茄内核 v2.4.15 · 已是最新（16:08 检查）`。
    func statusLine(version: String?, lastCheck: Date? = nil) -> String {
        let versionText = version.map { "番茄内核 v\($0)" } ?? "番茄内核版本未知"
        let stamp = (lastCheck ?? self.lastCheck).map { "（\(FMFormat.clock($0)) 检查）" } ?? ""
        switch KernelManager.shared.update {
        case .idle: return "\(versionText) · 尚未检查更新"
        case .checking: return "\(versionText) · 正在检查更新…"
        case .downloading(let progress): return "\(versionText) · 正在下载新版本 \(Int(progress * 100))%"
        case .upToDate: return "\(versionText) · 已是最新\(stamp)"
        case .updated(let target): return "\(versionText) · 已更新到 v\(target)\(stamp)"
        case .failed(let reason): return "\(versionText) · 更新检查失败，仍在使用当前版本（\(reason)）"
        }
    }

    enum CheckReason: String {
        case launch = "启动后检查"
        case scheduled = "定时检查"
        case kernelUnhealthy = "内核异常时检查"
        case manual = "手动检查"
    }

    func check(reason: CheckReason) async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            lastCheck = Date()
        }
        KernelManager.shared.update = .checking
        do {
            let source = Self.makeSource()
            let release = try await source.latest()
            let installed = KernelManager.shared.expectedVersion()
            fmLog("更新检查（\(reason.rawValue)）：本地 v\(installed ?? "?")，远端 \(release.tag)")
            guard let installed, KernelLocator.isNewer(release.version, than: installed) else {
                KernelManager.shared.update = .upToDate
                return
            }
            try await install(release: release, previousVersion: installed, source: source)
        } catch {
            KernelManager.shared.update = .failed(FriendlyError.text(error))
            fmLog("更新失败（\(reason.rawValue)）：\(error.localizedDescription)；继续使用当前内核 v\(KernelManager.shared.expectedVersion() ?? "?")")
        }
    }

    // MARK: - 发布源

    private static func makeSource() -> KernelReleaseSource {
        let env = ProcessInfo.processInfo.environment
        if let tag = env["FQM_MOCK_RELEASE_TAG"], !tag.isEmpty {
            if let path = env["FQM_MOCK_ASSET_PATH"], !path.isEmpty {
                fmLog("使用 mock 发布源：tag=\(tag) asset=\(path)")
                return MockReleaseSource(tag: tag, assetURL: URL(fileURLWithPath: path))
            }
            if let raw = env["FQM_MOCK_ASSET_URL"], let url = URL(string: raw) {
                fmLog("使用 mock 发布源：tag=\(tag) assetURL=\(raw)")
                return MockReleaseSource(tag: tag, assetURL: url)
            }
        }
        return GitHubReleaseSource()
    }

    // MARK: - 下载 → 校验 → 原子替换 → 重启 → 健康检查 → 回滚

    private func install(release: KernelRelease, previousVersion: String, source: KernelReleaseSource) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: FMAppPaths.kernelRoot, withIntermediateDirectories: true)
        let workDir = fm.temporaryDirectory.appending(path: "fqm-kernel-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let downloaded = workDir.appending(path: release.assetName)
        var candidates = [release.assetURL]
        if let github = source as? GitHubReleaseSource {
            candidates = [release.assetURL] + github.fallbackURLs(tag: release.tag, assetName: release.assetName)
        }
        var errors: [String] = []
        for url in candidates {
            do {
                fmLog("下载内核 v\(release.version)：\(url.absoluteString)")
                KernelManager.shared.update = .downloading(progress: 0)
                try await HttpClient.shared.download(url, to: downloaded) { fraction in
                    KernelManager.shared.update = .downloading(progress: fraction)
                }
                break
            } catch {
                errors.append("\(url.host ?? url.absoluteString): \(FriendlyError.text(error))")
            }
        }
        // 注意：刚下载的临时文件还没有 +x（URLSession 落盘权限 0600/0644），
        // 所以这里只校验「存在且非空」，随后 chmod 755，再用 --version 校验内容真伪。
        let size = (try? fm.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)??.int64Value ?? 0
        guard fm.fileExists(atPath: downloaded.path), size > 0 else {
            throw KernelUpdaterError.allDownloadsFailed(errors.joined(separator: "；"))
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloaded.path)

        // 先跑 --version 校验，挡住 404 HTML / 半截文件（规格 6.3.4）
        let verified = KernelLocator.version(of: downloaded)
        guard verified == release.version else {
            throw KernelUpdaterError.verifyFailed(expected: release.version, got: verified)
        }
        fmLog("新内核 v\(release.version) 已下载并通过 --version 校验")

        // 装到 kernel/<version>/，再原子切换 current
        let dir = FMAppPaths.kernelRoot.appending(path: release.version, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: "TomatoNovelDownloader")
        try? fm.removeItem(at: target)
        try fm.moveItem(at: downloaded, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try KernelManager.shared.pointCurrentTo(version: release.version)

        // 重启 + 60s 健康检查
        await KernelManager.shared.restart()
        if KernelManager.shared.phase.isReady {
            fmLog("内核已更新到 v\(release.version) 并通过健康检查")
            KernelManager.shared.update = .updated(release.version)
            prune(keeping: [release.version, previousVersion])
            return
        }

        // 健康检查失败 → 回滚上一个可用版本（规格 6.3.6）
        let reason = KernelManager.shared.lastFailureMessage ?? "健康检查未通过"
        fmLog("新内核 v\(release.version) 健康检查失败（\(reason)），回滚到 v\(previousVersion)")
        let rollbackBinary = FMAppPaths.kernelRoot
            .appending(path: previousVersion, directoryHint: .isDirectory)
            .appending(path: "TomatoNovelDownloader")
        if fm.isExecutableFile(atPath: rollbackBinary.path) {
            try KernelManager.shared.pointCurrentTo(version: previousVersion)
            await KernelManager.shared.restart()
            try? fm.removeItem(at: dir) // 坏版本不留
            KernelManager.shared.update = .failed("更新到 v\(release.version) 失败，已回滚到 v\(previousVersion)")
        } else {
            try? fm.removeItem(at: FMAppPaths.currentLink)
            try KernelManager.shared.installFactoryKernelIfNeeded()
            await KernelManager.shared.restart()
            try? fm.removeItem(at: dir)
            KernelManager.shared.update = .failed("更新到 v\(release.version) 失败，已退回出厂内核")
        }
    }

    /// 保留策略：最近 2 个版本 + 包内出厂版（规格 6.3.7）。
    private func prune(keeping versions: [String]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: FMAppPaths.kernelRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if versions.contains(name) || name == KernelManager.shared.expectedVersion() { continue }
            fmLog("清理旧内核版本 \(name)")
            try? fm.removeItem(at: entry)
        }
    }
}
