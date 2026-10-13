import Foundation

/// 内核定位与版本（规格 5.1：用户指定 > Application Support 的 current > 包内出厂）。
struct KernelLocation: Sendable {
    enum Source: String, Sendable {
        case userSpecified
        case managed
        case bundled
    }

    let url: URL
    let source: Source
    var displaySource: String {
        switch source {
        case .userSpecified: "用户指定"
        case .managed: "自动更新目录"
        case .bundled: "App 包内出厂"
        }
    }
}

enum KernelLocator {
    /// 解析顺序：用户指定 → kernel/current → 包内出厂（按架构）。
    static func resolve(userSpecified: String?) -> KernelLocation? {
        if let raw = userSpecified?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return KernelLocation(url: url, source: .userSpecified)
            }
        }
        if let managed = resolvedCurrentTarget() {
            return KernelLocation(url: managed, source: .managed)
        }
        if let bundled = FMAppPaths.bundledKernelURL() {
            return KernelLocation(url: bundled, source: .bundled)
        }
        return nil
    }

    /// `kernel/current` 软链接指向的真实文件（失效/普通文件都返回 nil）。
    static func resolvedCurrentTarget() -> URL? {
        let fm = FileManager.default
        let link = FMAppPaths.currentLink
        let values = try? link.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return nil }
            let target = URL(fileURLWithPath: dest, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            return fm.isExecutableFile(atPath: target.path) ? target : nil
        }
        // 也容忍 current 是普通可执行文件（手工放置的情况）
        return fm.isExecutableFile(atPath: link.path) ? link : nil
    }

    /// 读取内核 `--version`：`Tomato Novel Downloader v2.4.15` → `2.4.15`。
    static func version(of url: URL) -> String? {
        let out = KernelProcess.runAndCapture(url.path, ["--version"], timeout: 10)
        return parseVersion(from: out)
    }

    static func parseVersion(from text: String) -> String? {
        guard let range = text.range(of: #"(\d+)\.(\d+)\.(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    /// 语义化版本比较（规格 6.3.2）。
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = numbers(lhs), r = numbers(rhs)
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}
