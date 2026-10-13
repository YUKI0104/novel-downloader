import AppKit
import Darwin
import Foundation

/// 内核生命周期（规格 5 节 / 契约第 1 节）。
///
/// 根治两类事故：
/// 1. 内核自杀循环 —— 出厂/托管内核永远是官方原样文件（不改字节），内核自身的 SHA 校验能对上，
///    不会再触发「热补丁」下载 → 替换 → 重启。
/// 2. 退出留孤儿 —— 内核以独立进程组启动；关窗 / Cmd+Q / applicationWillTerminate 三处都走
///    stopSync()，SIGTERM → 3s → SIGKILL 整组回收并清 pid 文件；启动时遇到端口上的陌生/孤儿内核，
///    先记版本再接管，退出时一并收干净。
@MainActor
final class KernelManager: ObservableObject {
    static let shared = KernelManager()

    /// 顶栏状态胶囊读它（契约第 1 节）。
    @Published private(set) var phase: KernelPhase = .stopped
    /// 设置页灰字读它。
    @Published var update: KernelUpdateState = .idle
    /// 形如 "2.4.15"。
    @Published private(set) var version: String?

    // 诊断信息（不属于契约，界面可选读）
    @Published private(set) var lastFailureMessage: String?
    @Published private(set) var resolvedPath: String?
    @Published private(set) var adoptedOrphan = false

    /// 内核起不来时回调（立刻触发一次更新检查，规格 6.2）。
    var onFatalFailure: (() async -> Void)?

    private let service = KernelService.shared
    private var ownedPids: Set<pid_t> = []
    private var launchedPid: pid_t?
    private var startTask: Task<Void, Never>?
    private var startFailureReason: String?

    private init() {
        // 兜底：即使 C 忘了挂 AppLifecycle，Cmd+Q / 正常退出也会收干净内核
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                KernelManager.shared.stopSync(reason: "willTerminateNotification")
            }
        }
        // B 的请求遇到 connection refused 时，由这里负责拉起/等待，不把错误抛给用户
        KernelService.shared.onTransportFailure = {
            let current = KernelManager.shared.phase
            guard current != .starting, current != .updating, current != .ready else { return }
            await KernelManager.shared.start()
        }
    }

    // MARK: - 契约 API

    /// 幂等启动；内部接管孤儿内核（规格 5.1~5.3）。
    func start() async {
        if let task = startTask {
            await task.value
            return
        }
        if phase.isReady, let status = await service.probe(timeout: 1.5) {
            version = status.version
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
        startTask = nil
    }

    /// 停止：杀进程组 + 清 pid 文件；幂等。
    func stop() async {
        stopSync(reason: "stop()")
    }

    /// 请求前调用：未就绪就等待/拉起，失败抛错。
    /// 注意：**不要**在这里额外探活——内核在忙（正在跑搜索/下载的 HTTP 处理）时
    /// `/api/status` 可能超过 1.5s 才回，按「探活失败=内核挂了」处理会误判成没就绪，
    /// 甚至把正在服务的内核回收掉。存活性由状态机与 KernelService 的退避重试负责。
    func ensureReady() async throws {
        if phase.isReady { return }
        await start()
        guard phase.isReady else {
            throw KernelError.notReady(lastFailureMessage ?? "内核启动失败")
        }
    }

    /// 手动/定时更新检查；失败静默（只写 update 状态）。
    func checkForUpdate() async {
        await KernelUpdater.shared.check(reason: .manual)
    }

    /// 更新后重启（也用于手动重试）。
    func restart() async {
        phase = .updating
        stopSync(reason: "重启")
        await start()
    }

    /// 启动后 30s + 每 24h 的自动更新调度（规格 6.2）。
    func startUpdateSchedule() {
        KernelUpdater.shared.startSchedule()
    }

    // MARK: - 启动流程

    private func performStart() async {
        FMAppPaths.ensureDirectories()
        phase = .starting
        lastFailureMessage = nil

        // 1) 端口上已经有一个能应答的内核
        if let status = await service.probe(timeout: 2) {
            if await adoptOrRecycle(version: status.version) { return }
        }

        // 2) 端口被占用但没有应答（连续探活失败 3 次才认定僵死，避免误杀正在忙的内核）
        if let pid = KernelProcess.listeningPID(port: FMAppPaths.kernelPort) {
            let unresponsive = await unresponsiveProbes(count: 3)
            if verifiedKernel(pid), unresponsive {
                fmLog("内核 PID \(pid) 连续 \(unresponsiveProbesCount) 次不响应 /api/status，回收后重启")
                KernelProcess.terminateGroup(pid)
            } else if verifiedKernel(pid) {
                fmLog("内核 PID \(pid) 暂时不响应 /api/status，继续等待")
                if let status = await waitHealthy(timeout: 30) {
                    version = status.version
                    phase = .ready
                    return
                }
                KernelProcess.terminateGroup(pid)
            } else {
                let cmd = KernelProcess.commandLine(of: pid) ?? "未知进程"
                fail("端口 \(FMAppPaths.kernelPort) 被其他程序占用：\(cmd)")
                return
            }
        }

        // 3) 清掉失效的 pid 文件
        removeStalePidFile()

        // 4) 首次运行：把出厂内核复制到可写目录（绝不写 App 包内）
        do {
            try installFactoryKernelIfNeeded()
            try ensureKernelConfig()
        } catch {
            fail("准备内核失败：\(FriendlyError.text(error))")
            return
        }

        // 5) 按规格 5.1 定位：用户指定 → kernel/current → 包内出厂
        guard let location = KernelLocator.resolve(userSpecified: Self.userSpecifiedKernel) else {
            fail("未找到番茄内核。请检查 App 包内是否带 Kernel/\(FMAppPaths.bundledKernelName)，或在「设置」里指定内核路径。")
            return
        }
        resolvedPath = location.url.path

        // 6) 启动（独立进程组；SIGTERM 必须是默认动作，否则退出要白等 3s）
        let stdoutLog = FMAppPaths.logsDir.appending(path: "kernel.stdout.log").path
        try? FileManager.default.removeItem(atPath: stdoutLog)
        let arguments = ["--server", "--data-dir", FMAppPaths.kernelDataDir.path]
        do {
            let pid = try KernelProcess.spawn(executable: location.url, arguments: arguments, stdoutPath: stdoutLog)
            launchedPid = pid
            ownedPids.insert(pid)
            writePidFile(pid)
            fmLog("启动内核 \(location.url.path)（\(location.displaySource)）PID \(pid)，参数 \(arguments.joined(separator: " "))")
        } catch {
            fail(FriendlyError.text(error))
            return
        }

        // 7) 健康探测：/api/status 2s 超时，冷启动最多等 60s
        if let status = await waitHealthy(timeout: 60) {
            version = status.version
            phase = .ready
            fmLog("内核就绪 v\(status.version)")
        } else {
            if let pid = launchedPid { KernelProcess.terminateGroup(pid) }
            ownedPids.removeAll()
            launchedPid = nil
            removePidFile()
            fail(startFailureReason ?? "内核启动超时（60s）。日志见 \(FMAppPaths.logsDir.path)")
            await onFatalFailure?()
        }
    }

    private var unresponsiveProbesCount = 3

    /// 连续 N 次探活都失败才认为内核真的没在服务。
    private func unresponsiveProbes(count: Int) async -> Bool {
        for _ in 0..<count {
            if await service.probe(timeout: 2) != nil { return false }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return true
    }

    /// 端口上已有内核：版本一致就接管（退出时收干净），版本不一致就回收后重启自己的。
    /// 返回 true 表示已可对外服务。
    private func adoptOrRecycle(version runningVersion: String) async -> Bool {
        guard let pid = KernelProcess.listeningPID(port: FMAppPaths.kernelPort) else {
            version = runningVersion
            phase = .ready
            fmLog("内核已在运行 v\(runningVersion)（无法取得 PID），退出时按端口回收")
            return true
        }
        let expected = expectedVersion()
        if let expected, !expected.isEmpty, expected != runningVersion {
            fmLog("端口上的内核是 v\(runningVersion)，本地当前为 v\(expected)：回收后启动自己的")
            KernelProcess.terminateGroup(pid)
            removePidFile()
            return false
        }
        ownedPids.insert(pid)
        launchedPid = pid
        adoptedOrphan = true
        writePidFile(pid)
        version = runningVersion
        phase = .ready
        fmLog("接管已在运行的内核 PID \(pid) v\(runningVersion)（退出时会一并回收）")
        return true
    }

    /// 本地当前应使用的内核版本。
    func expectedVersion() -> String? {
        guard let location = KernelLocator.resolve(userSpecified: Self.userSpecifiedKernel) else {
            return nil
        }
        return KernelLocator.version(of: location.url)
    }

    /// 2s 超时探活，最多等 timeout 秒；进程提前退出就尽快失败（不白等 60s）。
    private func waitHealthy(timeout: TimeInterval) async -> KernelStatus? {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = await service.probe(timeout: 2) { return status }
            if let pid = launchedPid, !KernelProcess.isAlive(pid), Date().timeIntervalSince(start) > 1 {
                startFailureReason = "内核进程启动后立即退出（PID \(pid)）"
                fmLog("内核进程 \(pid) 提前退出")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        startFailureReason = "内核启动超时（\(Int(timeout))s）"
        return nil
    }

    // MARK: - 停止 / 回收

    /// 同步回收：给 applicationWillTerminate 用（关窗 / Cmd+Q / 正常退出）。
    /// SIGTERM → 等 3s → SIGKILL，并清 pid 文件。幂等，可重复调用。
    func stopSync(reason: String = "退出") {
        let pids = collectReclaimPids()
        guard !pids.isEmpty else {
            removePidFile()
            ownedPids.removeAll()
            launchedPid = nil
            phase = .stopped
            return
        }
        fmLog("\(reason)：回收内核进程 \(pids.sorted().map(String.init).joined(separator: ","))")
        for pid in pids { KernelProcess.signalGroup(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, pids.contains(where: { KernelProcess.isAlive($0) }) {
            usleep(50_000)
        }
        let stubborn = pids.filter { KernelProcess.isAlive($0) }
        for pid in stubborn { KernelProcess.signalGroup(pid, SIGKILL) }
        if !stubborn.isEmpty { fmLog("SIGKILL 强杀 \(stubborn.sorted())") }

        let hardDeadline = Date().addingTimeInterval(1.5)
        while Date() < hardDeadline, pids.contains(where: { KernelProcess.isAlive($0) }) {
            usleep(50_000)
        }

        removePidFile()
        ownedPids.removeAll()
        launchedPid = nil
        adoptedOrphan = false
        phase = .stopped
        if let leftover = KernelProcess.listeningPID(port: FMAppPaths.kernelPort) {
            fmLog("警告：端口 \(FMAppPaths.kernelPort) 仍被 PID \(leftover) 监听")
        } else {
            fmLog("内核已全部退出，端口 \(FMAppPaths.kernelPort) 已释放")
        }
    }

    /// 本 App 认为自己拥有的 pid ∪ pid 文件里的 pid ∪ 端口属主（都过一遍「像内核」校验）。
    private func collectReclaimPids() -> Set<pid_t> {
        var pids = ownedPids
        if let pid = launchedPid, pid > 0 { pids.insert(pid) }
        if let filePid = readPidFile(), KernelProcess.isAlive(filePid), verifiedKernel(filePid) {
            pids.insert(filePid)
        }
        if let portPid = KernelProcess.listeningPID(port: FMAppPaths.kernelPort), verifiedKernel(portPid) {
            pids.insert(portPid)
        }
        return pids.filter { KernelProcess.isAlive($0) }
    }

    /// ps 拿不到时不误杀：只有明确不像内核才排除。
    private func verifiedKernel(_ pid: pid_t) -> Bool {
        let result = KernelProcess.looksLikeKernel(pid)
        return !result.checked || result.looksLike
    }

    // MARK: - pid 文件

    func writePidFile(_ pid: pid_t) {
        try? "\(pid)".data(using: .utf8)?.write(to: FMAppPaths.pidFile)
    }

    func readPidFile() -> pid_t? {
        guard let text = try? String(contentsOf: FMAppPaths.pidFile, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func removePidFile() {
        try? FileManager.default.removeItem(at: FMAppPaths.pidFile)
    }

    private func removeStalePidFile() {
        guard let pid = readPidFile() else { return }
        if !KernelProcess.isAlive(pid) || !verifiedKernel(pid) {
            removePidFile()
        }
    }

    // MARK: - 首次运行：出厂内核复制到可写目录

    /// 规格 5.2：把出厂内核复制到 `kernel/<version>/TomatoNovelDownloader`，chmod 755，
    /// `current` 指向它。包内那份只做出厂回滚用，绝不写回 App 包。
    func installFactoryKernelIfNeeded() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: FMAppPaths.kernelRoot, withIntermediateDirectories: true)

        if KernelLocator.resolvedCurrentTarget() != nil {
            return // 已有可用托管内核
        }
        guard let bundled = FMAppPaths.bundledKernelURL() else {
            throw KernelManager.KernelPrepError.bundledKernelMissing
        }
        let version = KernelLocator.version(of: bundled) ?? "factory"
        let dir = FMAppPaths.kernelRoot.appending(path: version, directoryHint: .isDirectory)
        let target = dir.appending(path: "TomatoNovelDownloader")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.isExecutableFile(atPath: target.path) {
            try fm.copyItem(at: bundled, to: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            fmLog("首次运行：出厂内核（v\(version)）已复制到 \(target.path)")
        }
        try pointCurrentTo(version: version)
    }

    /// 原子切换 current 指针：先写 current.new 再 rename（规格 6.3.5）。
    /// 用 POSIX rename 而不是 FileManager.replaceItemAt：后者会先解析软链接，
    /// 对着 current 这种「指向文件的软链接」会报 “current doesn’t exist”。
    func pointCurrentTo(version: String) throws {
        let fm = FileManager.default
        let link = FMAppPaths.currentLink
        let relative = "\(version)/TomatoNovelDownloader"
        let staging = FMAppPaths.kernelRoot.appending(path: "current.new")
        try? fm.removeItem(at: staging)
        try fm.createSymbolicLink(atPath: staging.path, withDestinationPath: relative)
        let rc = staging.path.withCString { source in
            link.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard rc == 0 else {
            let code = errno
            try? fm.removeItem(at: staging)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "切换 current 指针失败：\(String(cString: strerror(code)))"]
            )
        }
        fmLog("current 指针 → \(relative)")
    }

    // MARK: - 内核 config.yml（save_path / novel_format）

    /// 保证内核把 txt 产物写到 App 的暂存目录（与旧版一致），再由下载流水线改名搬到用户下载目录。
    func ensureKernelConfig() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: FMAppPaths.kernelDataDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: FMAppPaths.kernelStaging, withIntermediateDirectories: true)
        var content = (try? String(contentsOf: FMAppPaths.kernelConfig, encoding: .utf8)) ?? Self.defaultKernelConfig
        content = Self.setYAMLValue(content, key: "save_path", value: FMAppPaths.kernelStaging.path)
        content = Self.setYAMLValue(content, key: "novel_format", value: "txt")
        try content.write(to: FMAppPaths.kernelConfig, atomically: true, encoding: .utf8)
    }

    static func setYAMLValue(_ content: String, key: String, value: String) -> String {
        let pattern = "(?m)^(\(key):).*$"
        if content.range(of: pattern, options: .regularExpression) != nil {
            return content.replacingOccurrences(
                of: pattern,
                with: "$1 \(value)",
                options: .regularExpression
            )
        }
        return content + "\n\(key): \(value)\n"
    }

    static let defaultKernelConfig = """
    old_cli: false
    max_workers: 3
    request_timeout: 15
    novel_format: txt
    bulk_files: false
    auto_open_downloaded_files: false
    save_path: ''
    use_official_api: true
    api_endpoints: []
    """

    /// 「用户显式指定内核路径」（规格 5.1 第 1 顺位）——取自旧版 settings.json 的 fanqieBin 键。
    static var userSpecifiedKernel: String? {
        let value = SettingsStore.shared.settings.fanqieBin.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 失败

    private func fail(_ message: String) {
        lastFailureMessage = message
        phase = .failed(message)
        fmLog("内核不可用：\(message)")
    }

    enum KernelPrepError: LocalizedError {
        case bundledKernelMissing

        var errorDescription: String? {
            "App 包内没有出厂内核（Contents/Resources/Kernel/\(FMAppPaths.bundledKernelName)）"
        }
    }
}

enum KernelError: LocalizedError {
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let reason): "番茄内核未就绪：\(reason)"
        }
    }
}
