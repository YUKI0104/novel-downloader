import AppKit
import Foundation

/// 统一的 HTTP 出口（规格 4：统一超时、重试策略、并发上限）。
/// 只有这里发网络请求：内核 REST、封面抓取、内核更新下载都走它。
final class HttpClient: @unchecked Sendable {
    static let shared = HttpClient()

    private let session: URLSession
    private let shortSession: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)

        // 只给「探活」这类 2s 级请求用：整体资源超时必须短，否则一个卡住的连接会拖住恢复流程
        let short = URLSessionConfiguration.ephemeral
        short.timeoutIntervalForRequest = 3
        short.timeoutIntervalForResource = 4
        shortSession = URLSession(configuration: short)
    }

    struct Response: Sendable {
        let data: Data
        let statusCode: Int
    }

    /// 用户可见的错误。`errorDescription` 必须是人话（带主机名），
    /// 不能漏出 `HttpError error 0` 这种默认字符串或类型名（设置页灰字直接显示它）。
    enum HttpError: Error, Sendable, LocalizedError {
        /// 第一个参数由 `describe(_:host:)` 生成，已经是中文短句（含主机名）
        case transport(String, isConnectionLevel: Bool)
        case status(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .transport(let message, _): message
            case .status(let code): "服务返回 HTTP \(code)"
            case .invalidResponse: "返回数据无法解析"
            }
        }
    }

    /// GET；timeout 为单次请求超时（探活用 2s）。
    func get(_ url: URL, timeout: TimeInterval? = nil, headers: [String: String] = [:]) async throws -> Response {
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await perform(request, using: Self.session(for: timeout, long: session, short: shortSession))
    }

    /// POST JSON。
    func post(_ url: URL, json: [String: Any], timeout: TimeInterval? = nil) async throws -> Response {
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await perform(request, using: Self.session(for: timeout, long: session, short: shortSession))
    }

    /// 只有「短超时」（探活，≤3s）才用短会话；业务请求走长会话，避免被会话级资源超时截断。
    private static func session(for timeout: TimeInterval?, long: URLSession, short: URLSession) -> URLSession {
        guard let timeout else { return long }
        return timeout <= 3 ? short : long
    }

    private func perform(_ request: URLRequest, using session: URLSession) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HttpError.invalidResponse }
            return Response(data: data, statusCode: http.statusCode)
        } catch let error as URLError {
            throw HttpError.transport(
                Self.describe(error, host: request.url?.host),
                isConnectionLevel: Self.isConnectionLevel(error)
            )
        } catch {
            // URLSession 的错误经常是 NSError 桥接过来的，直接 `as URLError` 不一定命中，
            // 那样会落到下面的兜底文案（“网络请求失败”），把超时/连接失败这些具体情况丢掉。
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                let urlError = URLError(URLError.Code(rawValue: nsError.code))
                throw HttpError.transport(
                    Self.describe(urlError, host: request.url?.host),
                    isConnectionLevel: Self.isConnectionLevel(urlError)
                )
            }
            // 原始错误只进日志（便于排查），不进用户文案
            fmLog("HTTP 底层错误：domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription) url=\(request.url?.absoluteString ?? "?")")
            throw HttpError.transport(
                "网络请求失败（\(request.url?.host ?? "未知地址")）",
                isConnectionLevel: false
            )
        }
    }

    /// 把 URLError 翻成人话（带主机名；不把 Error 类型名泄给用户）。
    static func describe(_ error: URLError, host: String?) -> String {
        let suffix = (host?.isEmpty == false) ? "（\(host!)）" : ""
        switch error.code {
        case .timedOut: return "网络请求超时\(suffix)"
        case .cannotConnectToHost: return "无法连接网络：目标没有响应\(suffix)"
        case .cannotFindHost: return "无法解析域名\(suffix)"
        case .dnsLookupFailed: return "域名解析失败\(suffix)"
        case .notConnectedToInternet: return "当前没有网络连接\(suffix)"
        case .networkConnectionLost: return "网络连接中断\(suffix)"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "安全连接失败\(suffix)"
        default: return "网络请求失败\(suffix)"
        }
    }

    /// 连接被拒/重置/超时 → 属于「内核没就绪」，界面要显示「内核正在启动」而不是报错。
    static func isConnectionLevel(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .timedOut, .notConnectedToInternet, .resourceUnavailable, .badServerResponse:
            return true
        default:
            return false
        }
    }

    /// 下载到指定路径，并回报真实进度（0…1）——内核更新用。
    func download(
        _ url: URL,
        to destination: URL,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        // 测试用 mock 会直接给一个本地文件，避免依赖 URLSession 对 file:// 的支持
        if url.isFileURL {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: url, to: destination)
            await MainActor.run { progress?(1) }
            return
        }
        let delegate = DownloadDelegate(destination: destination, onProgress: progress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        try await delegate.run(session: session, url: url)
    }

    /// 抓封面字节（内核的 /api/preview-cover/<hash> 是本地明文 HTTP）。
    func image(_ url: URL) async throws -> NSImage {
        let response = try await get(url)
        guard (200..<300).contains(response.statusCode),
              let image = NSImage(data: response.data), image.size.width > 1 else {
            throw HttpError.status(response.statusCode)
        }
        return image
    }
}

/// URLSessionDownloadTask 的进度/落盘回调。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (@MainActor (Double) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var delivered = false

    init(destination: URL, onProgress: (@MainActor (Double) -> Void)?) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(session: URLSession, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !delivered, let continuation else {
            lock.unlock()
            return
        }
        delivered = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let onProgress else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in onProgress(min(1, max(0, fraction))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 必须在这个回调里同步搬走临时文件，否则会被系统删掉
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(()))
        }
    }
}
