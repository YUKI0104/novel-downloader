import Foundation

/// 短剧后台数据层 —— 钥匙串与命令执行。
/// 逐函数照搬 `~/code/novel-downloader/shortdrama.go`：
/// `keychainErr`(:39) / `isKeychainAccessIssue`(:45) / `runCmd`(:54) / `FixKeychainAccess`(:67) /
/// `ShortdramaSessionStatusEx`(:90) / `KeychainFixStatus`(:79)。
///
/// **钥匙串只在这里被读**：`runCmd` 本身不读钥匙串，只有 `ShortdramaSession.sessionFromBrowser`
/// 在确认「cookie 库里确实有这条 sessionid、且没过期」之后才调 `security` 取密钥，
/// 因此 App 普通启动（无人调用短剧数据层）绝不会弹钥匙串授权。
enum ShortdramaKeychain {
    /// shortdrama.go:35 `keychainErrMarker`：钥匙串 ACL 拦截错误标记，界面据此弹引导授权。
    static let errMarker = "KEYCHAIN_NEEDS_FIX"
    /// shortdrama.go:39 `keychainHint`
    static let hint = "请在 macOS 弹窗里点「总是允许」,或在引导界面点「一键授权」"

    /// shortdrama.go:39 `keychainErr`：把钥匙串问题包装成带标记的错误。
    static func keychainErr(_ error: Error) -> ShortdramaFailure {
        ShortdramaFailure(message: errMarker + ": " + error.localizedDescription + "。" + hint, kind: .keychain)
    }

    /// shortdrama.go:45 `isKeychainAccessIssue`：区分「弹窗未授权」与「从未用过、钥匙串没这个条目」。
    static func isKeychainAccessIssue(_ error: Error) -> Bool {
        let s = error.localizedDescription
        return s.contains(errMarker) || s.contains("User canceled") || s.contains("denied") || s.contains("超时")
    }

    /// shortdrama.go:54 `runCmd`：带超时执行命令（钥匙串弹窗一直未批准时不无限阻塞）。
    /// `executable` 用绝对路径（`/usr/bin/security`、`/usr/bin/sqlite3`），避免依赖 PATH。
    static func runCmd(timeout: TimeInterval, executable: String, args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ShortdramaFailure(message: "无法执行 \(executable)：\(error.localizedDescription)"))
                    return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline { usleep(50_000) }
                if process.isRunning {
                    process.terminate()
                    usleep(200_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    continuation.resume(throwing: ShortdramaFailure(message: "钥匙串授权超时(卡在系统弹窗)"))
                    return
                }
                let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                if process.terminationStatus != 0 {
                    let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ShortdramaFailure(message: msg.isEmpty ? "命令退出码 \(process.terminationStatus)" : msg))
                    return
                }
                continuation.resume(returning: outData)
            }
        }
    }

    /// shortdrama.go:67 `FixKeychainAccess`：一键授权（把 security 工具加入 login 钥匙串分区列表）。
    /// 只照搬数据层动作，M3-a 不接界面，所以暂时没有调用点。
    static func fixKeychainAccess(password: String) async throws -> String {
        guard !password.isEmpty else { throw ShortdramaFailure(message: "请输入 Mac 开机密码") }
        do {
            let out = try await runCmd(timeout: 30, executable: "/usr/bin/security", args: [
                "set-key-partition-list", "-S", "apple-tool:,apple:", "-k", password, "login",
            ])
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ShortdramaFailure(message: "授权失败(请确认开机密码正确): \(error.localizedDescription)")
        }
    }
}

/// shortdrama.go:79 `KeychainFixStatus`：钥匙串授权状态。
struct KeychainFixStatus: Sendable {
    var ok = false
    var keychainNeedsFix = false
    /// M3-d：Safari cookie 库读被 TCC 拒（需要完全磁盘访问权限），与「未登录态」严格区分
    var needsFullDiskAccess = false
    var message = ""
}

/// 短剧后台数据层错误。
/// Go 版用 `errors.New(...)` 纯字符串在层内传递，这里保持一致（消息即用户的失败原因），
/// 额外带一个 `kind` 让自检能区分「无会话 / 钥匙串未授权 / 其它」，不改动任何消息文案。
struct ShortdramaFailure: Error, LocalizedError, CustomStringConvertible, Sendable {
    enum Kind: Sendable { case keychain, noSession, needsFullDiskAccess, other }

    let message: String
    let kind: Kind

    init(message: String, kind: Kind = .other) {
        self.message = message
        self.kind = kind
    }

    var errorDescription: String? { message }
    var description: String { message }
}
