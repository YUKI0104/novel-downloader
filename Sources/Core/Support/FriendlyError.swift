import Foundation

/// 面向用户的错误文案（M1.6：用户可见文案一律中文短句，绝不出现英文系统串/类型名）。
///
/// 规则：
///   · 已定义 `LocalizedError` 的错误直接用它自己的中文 `errorDescription`；
///   · 系统错误（URLError / NSError / CocoaError…）只做**分类翻译**，原文与 domain/code 只进日志；
///   · 兜底只给一句中文，不把 `error.localizedDescription` 拼进界面。
enum FriendlyError {
    static func text(_ error: Error) -> String {
        switch error {
        case let error as FanqieError: return error.errorDescription ?? "操作失败"
        case let error as KernelServiceError: return error.errorDescription ?? "内核请求失败"
        case let error as KernelError: return error.errorDescription ?? "内核未就绪"
        case let error as KernelUpdaterError: return error.errorDescription ?? "更新失败"
        case let error as KernelManager.KernelPrepError: return error.errorDescription ?? "内核准备失败"
        case let error as DownloadCenter.DownloadError: return error.errorDescription ?? "下载失败"
        case let error as LibraryStore.LibraryError: return error.errorDescription ?? "操作失败"
        case let error as KernelProcess.KernelProcessError: return error.errorDescription ?? "内核进程操作失败"
        default: break
        }

        // 系统错误：分类翻译（不显示原文）
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return networkText(URLError(URLError.Code(rawValue: nsError.code)), host: nil)
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "文件不存在"
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "没有文件访问权限"
            case NSFileWriteOutOfSpaceError: return "磁盘空间不足"
            default: return "文件操作失败"
            }
        }
        fmLog("未分类错误（只进日志）：domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
        return "操作失败，请稍后重试"
    }

    /// 网络类错误 → 中文短句（可选带主机名）。`connectionLevel` 用于内核「正在启动」判定。
    static func networkText(_ error: URLError, host: String?) -> String {
        let suffix = (host?.isEmpty == false) ? "（\(host!)）" : ""
        let target = (host?.isEmpty == false) ? host! : "网络"
        switch error.code {
        case .timedOut: return "连接 \(target) 超时"
        case .cannotFindHost, .dnsLookupFailed: return "找不到服务器 \(target)"
        case .cannotConnectToHost: return "无法连接 \(target)"
        case .notConnectedToInternet: return "当前没有网络连接"
        case .networkConnectionLost: return "网络连接中断"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "安全连接失败\(suffix)"
        default: return "网络请求失败\(suffix)"
        }
    }
}
