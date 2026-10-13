import Foundation

/// 全部落盘路径的唯一定义处（规格第 2、5、6 节）。
enum FMAppPaths {
    static let home: URL = FileManager.default.homeDirectoryForCurrentUser

    // 本 App 自己的可写目录（内核托管、日志、pid）
    static let appSupport = home.appending(path: "Library/Application Support/FanQieMao")
    static let kernelRoot = appSupport.appending(path: "kernel")
    /// 内核「当前版本」指针：软链接 → kernel/<version>/TomatoNovelDownloader
    static let currentLink = kernelRoot.appending(path: "current")
    static let pidFile = appSupport.appending(path: "kernel.pid")
    static let logsDir = appSupport.appending(path: "logs")

    // 内核数据目录（沿用旧版）
    static let kernelDataDir = home.appending(path: "Library/Caches/tomato-novel-downloader")
    static let kernelConfig = kernelDataDir.appending(path: "config.yml")

    // 旧版数据（必须能读旧文件）
    static let legacySupport = home.appending(path: "Library/Application Support/novel-downloader")
    static let settingsFile = legacySupport.appending(path: "settings.json")
    static let downloadsFile = legacySupport.appending(path: "downloads.json")
    /// M5：「最近查看」历史（搜索 / 详情），与 settings.json / downloads.json 同目录。
    static let historyFile = legacySupport.appending(path: "history.json")
    /// 内核产物落点（与旧版一致，避免改动用户已有 config.yml 的 save_path）
    static let kernelStaging = legacySupport.appending(path: "downloads")

    static let kernelPort: UInt16 = 18423

    /// 出厂内核在 App 包内的文件名（按架构，规格 5.1）。
    static var bundledKernelName: String {
        #if arch(arm64)
        return "TomatoNovelDownloader-macOS_arm64"
        #else
        return "TomatoNovelDownloader-macOS_amd64"
        #endif
    }

    /// 自动更新要下载的官方 asset 名（规格 6.3）。
    static var releaseAssetNamePrefix: String {
        #if arch(arm64)
        return "TomatoNovelDownloader-macOS_arm64"
        #else
        return "TomatoNovelDownloader-macOS_amd64"
        #endif
    }

    /// App 包内出厂内核路径（Contents/Resources/Kernel/<arch 名>）。
    static func bundledKernelURL() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let url = res.appending(path: "Kernel/\(bundledKernelName)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [appSupport, kernelRoot, logsDir, kernelDataDir, legacySupport, kernelStaging] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
