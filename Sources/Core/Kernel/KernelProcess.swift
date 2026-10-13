import Darwin
import Foundation

/// 内核进程的底层原语：独立进程组启动、按进程组回收、端口属主探测。
/// 这次事故的第二类问题（退出留孤儿）就是在这里根治的：
/// 内核永远以**独立进程组组长**启动，退出时整组 SIGTERM → 3s → SIGKILL；
/// 端口上有别的内核时按 pid 接管，退出时一并收干净。
enum KernelProcess {

    // MARK: - 启停

    /// 以独立进程组启动（posix_spawn + POSIX_SPAWN_SETPGROUP）。
    /// 用 posix_spawn 而不是 Foundation.Process：只有 fork 期设置 pgid 才没有竞态，
    /// 启动后再 setpgid 会因子进程已 exec 而 EACCES。
    static func spawn(executable: URL, arguments: [String], stdoutPath: String?) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdin ← /dev/null
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        // stdout / stderr ← 追加日志（拿不到就丢弃）
        if let stdoutPath {
            posix_spawn_file_actions_addopen(&fileActions, 1, stdoutPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_addopen(&fileActions, 2, stdoutPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 关键：POSIX_SPAWN_SETSIGDEF 把 SIGTERM/SIGINT/SIGHUP 重置为默认动作。
        // App 自己为了「kill <pid> 也能干净退出」把这三个信号设成了 SIG_IGN，
        // 子进程会继承这个 disposition——那样内核永远收不到 SIGTERM，
        // 每次退出都要白等 3s 再 SIGKILL。
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGHUP)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
        // pgroup = 0 → 子进程成为新进程组组长，pgid == 子进程 pid
        posix_spawnattr_setpgroup(&attr, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &fileActions, &attr, argv, environ)
        guard rc == 0 else {
            throw KernelProcessError.spawnFailed(errno: rc)
        }
        return pid
    }

    enum KernelProcessError: LocalizedError {
        case spawnFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let code):
                return "启动内核失败：\(String(cString: strerror(code)))"
            }
        }
    }

    // MARK: - 探测

    static func isAlive(_ pid: pid_t) -> Bool {
        isRunning(pid)
    }

    /// 进程是否仍在运行。
    /// - 本 App spawn 的子进程：用 waitpid(WNOHANG) 顺便回收，否则死了也会以僵尸形态留在 ps 里；
    /// - 接管来的孤儿（父进程是 launchd）：waitpid 会 ECHILD，退回 kill(pid,0) + ps 状态判断，
    ///   因为 kill(pid, 0) 对僵尸同样返回 0，会把「已死」误判成「还在跑」，白等满 3s。
    static func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid { return false } // 刚退出并已回收
        if reaped == 0 { return true } // 我们的子进程，还在跑
        errno = 0
        guard kill(pid, 0) == 0 else { return false }
        if errno == EPERM { return true } // 别人的进程，存在但无权限
        return !isZombie(pid)
    }

    /// ps 状态是否以 Z（僵尸）开头。
    static func isZombie(_ pid: pid_t) -> Bool {
        let out = runAndCapture("/bin/ps", ["-o", "state=", "-p", String(pid)], timeout: 3)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
    }

    /// 监听指定端口的 pid（lsof，与旧版同一套判据）。
    static func listeningPID(port: UInt16) -> pid_t? {
        let out = runAndCapture("/usr/sbin/lsof", ["-ti", "tcp:\(port)", "-sTCP:LISTEN"])
        for field in out.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
            if let pid = pid_t(field), pid > 0 { return pid }
        }
        return nil
    }

    static func commandLine(of pid: pid_t) -> String? {
        let out = runAndCapture("/bin/ps", ["-p", String(pid), "-o", "command="])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 命令行看起来像番茄内核吗？
    /// 返回 (像不像, 是否确认)。ps 拿不到时 checked=false，调用方应保守处理。
    static func looksLikeKernel(_ pid: pid_t) -> (looksLike: Bool, checked: Bool) {
        guard let cmd = commandLine(of: pid) else { return (false, false) }
        return (cmd.lowercased().contains("tomato"), true)
    }

    // MARK: - 回收

    static func signalGroup(_ pid: pid_t, _ sig: Int32) {
        guard pid > 0 else { return }
        _ = kill(-pid, sig) // 进程组（pgid == pid）
        _ = kill(pid, sig)
    }

    /// 温和退出：SIGTERM → 最多等 3s → SIGKILL；返回是否全部退出。
    @discardableResult
    static func terminateGroup(_ pid: pid_t, grace: TimeInterval = 3) -> Bool {
        guard pid > 0, isAlive(pid) else { return true }
        signalGroup(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(80_000)
        }
        signalGroup(pid, SIGKILL)
        let hardDeadline = Date().addingTimeInterval(1.0)
        while Date() < hardDeadline {
            if !isAlive(pid) { return true }
            usleep(50_000)
        }
        return !isAlive(pid)
    }

    // MARK: - 工具

    @discardableResult
    static func runAndCapture(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 8) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning { process.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
