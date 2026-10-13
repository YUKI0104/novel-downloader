import Foundation

/// 内核返回体（`/api/status`）。
struct KernelStatus: Sendable, Equatable {
    var version: String
    var saveDir: String
    var bindAddr: String
}

/// 下载任务状态（`/api/jobs`）。
struct KernelJob: Sendable, Equatable {
    var id: Int
    var state: String
    var message: String?
    var savedChapters: Int
    var chapterTotal: Int

    var isFinished: Bool { state == "done" }
    var isFailed: Bool { state == "failed" || state == "cancelled" }
}

enum KernelServiceError: LocalizedError {
    /// 连接层面的失败（内核没起来 / 正在重启）——界面必须显示「内核正在启动」，不是报错
    case kernelUnavailable(String)
    case http(Int)
    case message(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .kernelUnavailable: "内核正在启动，请稍候…"
        case .http(let code): "内核返回 HTTP \(code)"
        case .message(let text): text
        case .decoding(let text): "内核返回内容无法解析：\(text)"
        }
    }

    var isKernelUnavailable: Bool {
        if case .kernelUnavailable = self { return true }
        return false
    }
}

/// 内核 REST 客户端（规格 4：接口与旧版一致）。
/// 连接层的失败按规格 5.3 退避重试 0.5/1/2/3s，并把「内核正在启动」的信号交给上层，
/// 不允许把 connection refused 直接抛给用户。
@MainActor
final class KernelService {
    static let shared = KernelService()

    /// 连接失败时通知 KernelManager 去拉起/等待内核（由 AppModel 注入）。
    var onTransportFailure: (() async -> Void)?

    private let base = URL(string: "http://127.0.0.1:\(FMAppPaths.kernelPort)")!

    /// 内核服务根地址（封面等相对路径用它拼绝对地址）。
    var baseURL: URL { base }

    private static let retryDelays: [Duration] = [
        .milliseconds(500), .milliseconds(1000), .milliseconds(2000), .milliseconds(3000)
    ]

    // MARK: - 端点

    func status(timeout: TimeInterval = 2) async throws -> KernelStatus {
        let json = try await request(path: "/api/status", timeout: timeout, allowRetry: false)
        return KernelStatus(
            version: json["version"]?.looseString ?? "",
            saveDir: json["save_dir"]?.looseString ?? "",
            bindAddr: json["bind_addr"]?.looseString ?? ""
        )
    }

    /// 探活：2s 超时，只关心 HTTP 200。
    func probe(timeout: TimeInterval = 2) async -> KernelStatus? {
        try? await status(timeout: timeout)
    }

    func search(_ keyword: String) async throws -> JSONValue {
        try await request(path: "/api/search", query: ["q": keyword])
    }

    func preview(_ bookID: String) async throws -> JSONValue {
        try await request(path: "/api/preview/\(bookID)", timeout: 60)
    }

    func createJob(bookID: String, start: Int?, end: Int?) async throws -> Int {
        var body: [String: Any] = ["book_id": bookID]
        if let start, start > 0 { body["range_start"] = start }
        if let end, end > 0 { body["range_end"] = end }
        let json = try await request(path: "/api/jobs", method: "POST", body: body)
        guard let id = json["id"]?.intValue else {
            throw KernelServiceError.message("创建下载任务失败：内核没有返回任务 ID")
        }
        return id
    }

    func jobStatus(_ id: Int) async throws -> KernelJob? {
        let json = try await request(path: "/api/jobs", query: ["id": String(id)], timeout: 15, allowRetry: false)
        guard let first = json["items"]?.arrayValue?.first else { return nil }
        var job = KernelJob(
            id: id,
            state: first["state"]?.looseString ?? "",
            message: first["message"]?.looseString,
            savedChapters: first["progress"]?["saved_chapters"]?.intValue ?? 0,
            chapterTotal: first["progress"]?["chapter_total"]?.intValue ?? 0
        )
        if job.message?.isEmpty == true { job.message = nil }
        return job
    }

    func library() async throws -> JSONValue {
        try await request(path: "/api/library", timeout: 20)
    }

    /// 封面绝对地址（内核返回相对路径 /api/preview-cover/<hash>）。
    func coverURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        if path.hasPrefix("/") { return URL(string: base.absoluteString + path) }
        return URL(string: base.absoluteString + "/" + path)
    }

    // MARK: - 带退避重试的请求

    func request(
        path: String,
        query: [String: String] = [:],
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: TimeInterval? = nil,
        allowRetry: Bool = true
    ) async throws -> JSONValue {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw KernelServiceError.message("请求地址不合法") }

        let attempts = allowRetry ? 4 : 1
        var lastError: KernelServiceError = .kernelUnavailable("连接内核失败")

        for attempt in 0..<attempts {
            do {
                return try await sendOnce(url: url, method: method, body: body, timeout: timeout)
            } catch let error as KernelServiceError {
                lastError = error
                if !error.isKernelUnavailable { throw error }
                // 内核没就绪：通知上层去拉起/等待，然后按规格退避。
                // 注意：探活/健康检查（allowRetry == false）不能触发回调——
                // 那些请求本身就跑在启动流程里，回调会等回自己，直接自锁。
                if allowRetry, attempt == 0 { await onTransportFailure?() }
                if attempt < attempts - 1 {
                    try? await Task.sleep(for: Self.retryDelays[min(attempt, Self.retryDelays.count - 1)])
                }
            }
        }
        throw lastError
    }

    private func sendOnce(url: URL, method: String, body: [String: Any]?, timeout: TimeInterval?) async throws -> JSONValue {
        let response: HttpClient.Response
        do {
            switch method {
            case "POST":
                response = try await HttpClient.shared.post(url, json: body ?? [:], timeout: timeout)
            default:
                response = try await HttpClient.shared.get(url, timeout: timeout)
            }
        } catch let error as HttpClient.HttpError {
            switch error {
            case .transport(let text, let connectionLevel) where connectionLevel:
                throw KernelServiceError.kernelUnavailable(text)
            case .transport(let text, _):
                throw KernelServiceError.message("请求内核失败：\(text)")
            case .status(let code):
                throw KernelServiceError.http(code)
            case .invalidResponse:
                throw KernelServiceError.message("内核返回了无法识别的响应")
            }
        }

        guard (200..<300).contains(response.statusCode) else {
            throw KernelServiceError.http(response.statusCode)
        }
        guard let json = try? FMJSON.parse(response.data) else {
            throw KernelServiceError.decoding("响应不是 JSON")
        }
        if let message = json["error"]?.looseString, !message.isEmpty {
            throw KernelServiceError.message(message)
        }
        return json
    }
}
