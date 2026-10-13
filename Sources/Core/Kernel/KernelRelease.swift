import Foundation

/// 远端发布信息。
struct KernelRelease: Sendable {
    var tag: String
    var version: String
    var assetName: String
    var assetURL: URL
}

/// 发布源：真 GitHub，或测试用 mock（规格 6.3/6.4；任务书要求「更新链路用 mock 跑通」）。
protocol KernelReleaseSource: Sendable {
    func latest() async throws -> KernelRelease
}

/// 官方 GitHub Releases（规格 6.3/6.4）。
/// 查发布只走直连 `api.github.com`：加速镜像不代理 api（实测 ghfast 403 / gh-proxy 404 / ghproxy 404），
/// 留着只会在真机上白等三轮 + 日志噪音。镜像只用于 asset 下载（downloadPrefixes）。
/// 系统代理由 URLSession 默认配置自动带上。
struct GitHubReleaseSource: KernelReleaseSource {
    private static let latestPath = "repos/zhongbai2333/Tomato-Novel-Downloader/releases/latest"
    private static let apiPrefixes = [
        "https://api.github.com/",
    ]
    private static let downloadPrefixes = [
        "https://github.com/",
        "https://ghfast.top/https://github.com/",
        "https://gh-proxy.com/https://github.com/",
        "https://ghproxy.net/https://github.com/",
    ]

    func latest() async throws -> KernelRelease {
        var lastError: Error = URLError(.unknown)
        for prefix in Self.apiPrefixes {
            let latestURL = URL(string: prefix + Self.latestPath)!
            do {
                let response = try await HttpClient.shared.get(
                    latestURL,
                    timeout: 20,
                    headers: [
                        "Accept": "application/vnd.github+json",
                        "User-Agent": "FanQieMao/0.1",
                    ]
                )
                guard (200..<300).contains(response.statusCode) else {
                    // 日志与错误里都带上完整 URL（只打 prefix 会让人误判成「请求了根路径」）
                    throw KernelUpdaterError.http(response.statusCode, latestURL.host ?? latestURL.absoluteString)
                }
                let json = try FMJSON.parse(response.data)
                guard let tag = json["tag_name"]?.looseString, !tag.isEmpty,
                      let version = KernelLocator.parseVersion(from: tag) else {
                    throw KernelUpdaterError.badReleasePayload
                }
                let assetName = "\(FMAppPaths.releaseAssetNamePrefix)-\(tag)"
                var candidates: [URL] = []
                if let assets = json["assets"]?.arrayValue {
                    for asset in assets where asset["name"]?.looseString == assetName {
                        if let raw = asset["browser_download_url"]?.looseString, let url = URL(string: raw) {
                            candidates.append(url)
                        }
                    }
                }
                candidates.append(contentsOf: fallbackURLs(tag: tag, assetName: assetName))
                guard let first = candidates.first else { throw KernelUpdaterError.assetNotFound(assetName) }
                return KernelRelease(tag: tag, version: version, assetName: assetName, assetURL: first)
            } catch {
                lastError = error
                fmLog("查询 GitHub 发布失败（\(latestURL.absoluteString)）：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// 备用下载地址（主地址失败时按序重试）。
    func fallbackURLs(tag: String, assetName: String) -> [URL] {
        Self.downloadPrefixes.map {
            URL(string: $0 + "zhongbai2333/Tomato-Novel-Downloader/releases/download/\(tag)/\(assetName)")!
        }
    }
}

/// 测试用发布源：`FQM_MOCK_RELEASE_TAG` 指定假版本，
/// `FQM_MOCK_ASSET_PATH`（本地文件）或 `FQM_MOCK_ASSET_URL`（真实 HTTP）指定假 asset。
struct MockReleaseSource: KernelReleaseSource {
    let tag: String
    let assetURL: URL

    func latest() async throws -> KernelRelease {
        guard let version = KernelLocator.parseVersion(from: tag) else {
            throw KernelUpdaterError.badReleasePayload
        }
        return KernelRelease(
            tag: tag,
            version: version,
            assetName: "\(FMAppPaths.releaseAssetNamePrefix)-\(tag)",
            assetURL: assetURL
        )
    }
}

enum KernelUpdaterError: LocalizedError {
    case http(Int, String)
    case badReleasePayload
    case assetNotFound(String)
    case verifyFailed(expected: String, got: String?)
    case allDownloadsFailed(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let host): "服务返回 HTTP \(code)（\(host)）"
        case .badReleasePayload: "发布信息里没有可识别的版本号"
        case .assetNotFound(let name): "发布里没有本机架构的 asset（\(name)）"
        case .verifyFailed(let expected, let got): "下载文件跑不出预期版本（期望 \(expected)，实际 \(got ?? "无法执行")）"
        case .allDownloadsFailed(let detail): "所有下载地址都失败：\(detail)"
        }
    }
}
