import Foundation

/// M3-g：榜单 / 搜索请求失败时的自动重试（最多 3 次，间隔 1 / 2 / 4 秒）。
///
/// 只包裹「发请求」这一步，不碰接口 URL、频道、排序逻辑，也不引入任何新控件：
///   · 重试期间通过 `onRetry` 回调，让调用方把状态行换成「网络不稳，正在重试 n/3…」；
///   · 重试前有节奏地退避（1s → 2s → 4s），不再是长时间干等；
///   · 3 次重试仍失败则抛最后一次错误，由调用方沿用现有失败文案 + 现有「重试」按钮。
enum NetworkRetry {
    /// 失败后的重试次数（首次尝试不计）。与状态行「重试 n/3」的 3 一致。
    static let maxAttempts = 3

    /// 每次重试前的等待秒数：第 1 次 1s，第 2 次 2s，第 3 次 4s。
    static let delaySeconds: [Int] = [1, 2, 4]

    /// 重试期间的状态行文案（与现有灰字状态行同一句话风格，短、不堆句子）。
    static func retryText(_ attempt: Int) -> String {
        "网络不稳，正在重试 \(attempt)/\(maxAttempts)…"
    }

    /// 执行 `operation`；失败按 1/2/4s 退避重试，每次重试开始前调用 `onRetry(第几次)`。
    ///
    /// - Parameters:
    ///   - label: 日志前缀（「榜单」/「搜索」）
    ///   - onRetry: 第 n 次重试开始前调用（n 从 1 起）
    ///   - isCancelled: 返回 true 时立刻停止（换平台 / 重新发起请求），抛 `CancellationError`
    ///   - shouldRetry: 判定该错误是否值得重试（默认都重试；「未找到」这类业务结果不重试）
    ///   - operation: 真正发请求的闭包
    @MainActor
    static func run<T>(
        label: String,
        onRetry: (Int) -> Void,
        isCancelled: () -> Bool = { false },
        shouldRetry: (Error) -> Bool = { _ in true },
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            if isCancelled() { throw CancellationError() }
            do {
                let value = try await operation()
                if attempt > 0 {
                    fmLog("M3G \(label)重试成功（第 \(attempt)/\(maxAttempts) 次重试后）")
                }
                return value
            } catch {
                if isCancelled() { throw CancellationError() }
                guard shouldRetry(error) else { throw error }
                attempt += 1
                guard attempt <= maxAttempts else {
                    fmLog("M3G \(label)自动重试 \(maxAttempts) 次仍失败：\(FriendlyError.text(error))")
                    throw error
                }
                let seconds = delaySeconds[min(attempt, delaySeconds.count) - 1]
                fmLog("M3G \(label)请求失败，第 \(attempt)/\(maxAttempts) 次重试：等待 \(seconds)s ｜ 原因=\(FriendlyError.text(error))")
                onRetry(attempt)
                let sleepStart = Date()
                try? await Task.sleep(for: .seconds(seconds))
                let waited = Int(Date().timeIntervalSince(sleepStart) * 1000)
                fmLog("M3G \(label)第 \(attempt)/\(maxAttempts) 次重试发起（实测等待 \(waited)ms）")
            }
        }
    }
}
