import Foundation

/// Safari 登录态读取器（M3-d）—— Safari 的 cookie 库是 `binarycookies` 格式。
///
/// 与 Chromium 系的关键区别：
/// - **value 是明文**，不加密 → 不需要钥匙串、不需要 PBKDF2/AES；
/// - 但文件在 `~/Library/Containers/com.apple.Safari/...`，受 macOS 隐私保护（TCC），
///   只有拿到「完全磁盘访问权限」的 app 才能读，否则 `Operation not permitted`。
///
/// 格式（文件头**大端**、页内**小端**，别写反）：
/// - 文件头：`"cook"`(4B) + 页数 `uint32 BE` + 每页大小数组 `uint32 BE`
/// - 每页：页头 `uint32 LE`(0x00000100) + 本页 cookie 数 `uint32 LE` + 各条 cookie
/// - 每条 cookie：`size/unknown/flags/has_port/domain_offset/name_offset/path_offset/value_offset`（uint32 LE）
///   + `expiry`(double LE, Mac 绝对时间＝自 2001-01-01 的秒) + `creation`(double LE) + `comment_offset`(uint32 LE)
///   + 各字符串（NUL 结尾，偏移相对本条起始）
enum SafariCookies {
    /// 本机 Safari 的 cookie 库路径（`FQM_SD_SAFARI_COOKIES` 可临时改成测试夹具，自检用）。
    static let defaultPath = "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"

    static var currentPath: String {
        ProcessInfo.processInfo.environment["FQM_SD_SAFARI_COOKIES"] ?? defaultPath
    }

    struct Cookie: Sendable {
        var domain: String
        var name: String
        var value: String
        /// Mac 绝对时间（自 2001-01-01 的秒）；0 = 会话级 cookie
        var expiry: Double
    }

    struct ParseResult: Sendable {
        var pageCount: Int
        var cookies: [Cookie]
    }

    /// 自检证据用的摘要（不含 cookie 值，host 脱敏）。
    struct Summary: Sendable {
        var pageCount = 0
        var cookieCount = 0
        var distinctHostCount = 0
        var hostSamples: [String] = []
        var hasShortdramaSession = false
        var shortdramaExpired = false
        var sessionHost = ""
        var sessionIDLength = 0
        var sessionExpiryDescription = ""
        var failure: String?
        var needsFullDiskAccess = false
    }

    // MARK: - 文件读取 + TCC 判定

    /// 读文件并解析；读被 TCC 拒时抛 `needsFullDiskAccess`（与「没有登录态」严格区分）。
    static func load(path: String = currentPath) throws -> ParseResult {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ShortdramaFailure(message: "Safari 未安装或从未使用过")
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expanded), options: [.mappedIfSafe])
        } catch {
            let ns = error as NSError
            fmLog("Safari cookie 读取失败 path=\(expanded) domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            if isPermissionDenied(error) {
                throw ShortdramaFailure(
                    message: "开启完全磁盘访问权限读取Safari登录态（系统设置 → 隐私与安全性 → 完全磁盘访问权限；授权后若仍读不到，请完全退出重新打开）",
                    kind: .needsFullDiskAccess
                )
            }
            throw ShortdramaFailure(message: "读取 Safari cookie 失败：\(ns.domain) \(ns.code) \(ns.localizedDescription)")
        }
        return try parse(data: data)
    }

    /// TCC / EPERM 判定（`Data(contentsOf:)` 会桥成 NSCocoaErrorDomain 257 或 POSIX EPERM）。
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 257 { return true } // NSFileReadNoPermissionError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 1 { return true }   // EPERM
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == 1 { return true }
        let text = ns.localizedDescription
        return text.contains("Operation not permitted") || text.contains("permission") || text.contains("权限")
    }

    // MARK: - 解析

    /// binarycookies 解析（多页全扫；损坏宽度/越界一律当格式错误，不崩）。
    static func parse(data: Data) throws -> ParseResult {
        let bytes = [UInt8](data)
        func u32BE(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        func u32LE(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func f64LE(_ o: Int) -> Double? {
            guard o >= 0, o + 8 <= bytes.count else { return nil }
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(bytes[o + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: raw)
        }

        guard bytes.count >= 8, bytes[0] == 0x63, bytes[1] == 0x6F, bytes[2] == 0x6F, bytes[3] == 0x6B else {
            throw ShortdramaFailure(message: "Safari cookie 文件格式不认识（缺少 cook 头）")
        }
        guard let pageCountRaw = u32BE(4), pageCountRaw <= 4096 else {
            throw ShortdramaFailure(message: "Safari cookie 文件格式不认识（页数异常）")
        }
        let pageCount = Int(pageCountRaw)
        var sizes: [Int] = []
        var offset = 8
        for _ in 0..<pageCount {
            guard let raw = u32BE(offset) else { throw ShortdramaFailure(message: "Safari cookie 文件不完整（页大小缺失）") }
            sizes.append(Int(raw))
            offset += 4
        }

        var cookies: [Cookie] = []
        for (pageIndex, size) in sizes.enumerated() {
            guard size >= 8, offset + size <= bytes.count else {
                throw ShortdramaFailure(message: "Safari cookie 文件不完整（页越界：页\(pageIndex) size=\(size) offset=\(offset) 文件长=\(bytes.count)）")
            }
            let pageEnd = offset + size
            guard let countRaw = u32LE(offset + 4) else { throw ShortdramaFailure(message: "Safari cookie 文件不完整（页头缺失）") }
            let count = Int(countRaw)
            // 真实 Safari 布局：page+8 是**首条记录相对页首的偏移**（= 12 + 4×条数），
            // 不是记录长度；记录从那里开始按 size 顺序排列。（任务书写的“page+8=size”与实际不符）
            var p = offset + 8
            if let first = u32LE(offset + 8), Int(first) == 12 + 4 * count {
                p = offset + Int(first)
            }
            for recordIndex in 0..<count {
                guard p + 52 <= pageEnd, let recordSizeRaw = u32LE(p) else {
                    throw ShortdramaFailure(message: "Safari cookie 文件不完整（条目越界：页\(pageIndex) 第\(recordIndex)条 起点=\(p) 页范围=\(offset)..\(pageEnd)）")
                }
                let recordSize = Int(recordSizeRaw)
                guard recordSize >= 52, p + recordSize <= pageEnd else {
                    throw ShortdramaFailure(message: "Safari cookie 文件不完整（条目长度异常：页\(pageIndex) 第\(recordIndex)条 size=\(recordSize) 起点=\(p) 页范围=\(offset)..\(pageEnd) 页内条数=\(count)）")
                }
                let recordStart = p
                guard let domainOffset = u32LE(recordStart + 16),
                      let nameOffset = u32LE(recordStart + 20),
                      let valueOffset = u32LE(recordStart + 28),
                      let expiry = f64LE(recordStart + 32) else {
                    throw ShortdramaFailure(message: "Safari cookie 文件不完整（条目字段缺失）")
                }
                func string(at raw: UInt32) -> String {
                    guard raw != 0 else { return "" }
                    var i = recordStart + Int(raw)
                    var out: [UInt8] = []
                    while i < recordStart + recordSize, bytes[i] != 0 {
                        out.append(bytes[i])
                        i += 1
                    }
                    return String(decoding: out, as: UTF8.self)
                }
                let domain = string(at: domainOffset)
                if !domain.isEmpty {
                    cookies.append(Cookie(domain: domain, name: string(at: nameOffset), value: string(at: valueOffset), expiry: expiry))
                }
                p = recordStart + recordSize
            }
            offset = pageEnd
        }
        return ParseResult(pageCount: pageCount, cookies: cookies)
    }

    // MARK: - 取 shortdramas sessionid

    /// 取 host 含 `shortdramas.com` 且 `name == "sessionid"` 的那条；大会话级（expiry==0）不过期，已过期跳过。
    /// 找不到/全过期 → `.noSession`；读被拒 → `.needsFullDiskAccess`。
    static func shortdramaSessionID(path: String = currentPath) throws -> String {
        let result = try load(path: path)
        var expired = false
        for cookie in result.cookies where cookie.domain.contains("shortdramas.com") && cookie.name == "sessionid" {
            if cookie.expiry > 0, Date(timeIntervalSinceReferenceDate: cookie.expiry) < Date() {
                expired = true
                continue
            }
            return cookie.value
        }
        if expired {
            throw ShortdramaFailure(message: "Safari 的登录会话已过期:请在 Safari 重新登录 www.shortdramas.com", kind: .noSession)
        }
        throw ShortdramaFailure(message: "Safari 里没有 shortdramas 登录态:请在 Safari 登录 www.shortdramas.com 后重试", kind: .noSession)
    }

    // MARK: - 自检诊断（脱敏）

    static func diagnose(path: String = currentPath) -> Summary {
        var summary = Summary()
        do {
            let result = try load(path: path)
            summary.pageCount = result.pageCount
            summary.cookieCount = result.cookies.count
            let hosts = Set(result.cookies.map(\.domain))
            summary.distinctHostCount = hosts.count
            summary.hostSamples = hosts.sorted().prefix(5).map(maskHost)
            let now = Date()
            for cookie in result.cookies where cookie.domain.contains("shortdramas.com") && cookie.name == "sessionid" {
                if cookie.expiry > 0, Date(timeIntervalSinceReferenceDate: cookie.expiry) < now {
                    summary.shortdramaExpired = true
                } else {
                    summary.hasShortdramaSession = true
                    summary.sessionHost = maskHost(cookie.domain)
                    summary.sessionIDLength = cookie.value.count
                    summary.sessionExpiryDescription = expiryText(cookie.expiry)
                }
            }
        } catch let failure as ShortdramaFailure {
            summary.failure = failure.message
            summary.needsFullDiskAccess = failure.kind == .needsFullDiskAccess
        } catch {
            summary.failure = error.localizedDescription
        }
        return summary
    }

    /// 自检用：把 cookie 文件的结构摊开（页数/页大小/每页条数/对不齐位置），不含 cookie 值。
    static func structure(path: String = currentPath) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expanded), options: [.mappedIfSafe]) else {
            return "结构dump：读取失败（\(expanded)）"
        }
        let b = [UInt8](data)
        func u32BE(_ o: Int) -> UInt32? { guard o >= 0, o + 4 <= b.count else { return nil }; return UInt32(b[o]) << 24 | UInt32(b[o+1]) << 16 | UInt32(b[o+2]) << 8 | UInt32(b[o+3]) }
        func u32LE(_ o: Int) -> UInt32? { guard o >= 0, o + 4 <= b.count else { return nil }; return UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24 }
        var out = "文件长=\(b.count) magic=\(String(decoding: b.prefix(4), as: UTF8.self))"
        guard let pc = u32BE(4) else { return out + " 读不到页数" }
        out += " 页数=\(pc)"
        var sizes: [Int] = []
        var o = 8
        for _ in 0..<Int(pc) { guard let s = u32BE(o) else { break }; sizes.append(Int(s)); o += 4 }
        out += " 页大小=\(sizes) 页表结束=\(o) 页大小和=\(sizes.reduce(0,+)) 推断总长=\(o + sizes.reduce(0,+))"
        var off = 8 + 4 * Int(pc)
        for (pi, size) in sizes.enumerated() {
            guard size >= 8, off + size <= b.count else { out += " | 页\(pi)越界 off=\(off) size=\(size)"; break }
            let end = off + size
            let hdr = u32LE(off) ?? 0
            let cnt = u32LE(off + 4) ?? 0
            out += " | 页\(pi) \(off)..\(end) 头=\(String(format: "%08x", hdr)) 条数=\(cnt) 首记录偏移=\(u32LE(off + 8) ?? 0)"
            if pi <= 2 {
                let hexEnd = min(off + 80, end)
                let hex = b[off..<hexEnd].map { String(format: "%02x", $0) }.joined(separator: " ")
                out += " hex=\(hex)"
            }
            var p = off + 8
            var ri = 0
            while p + 52 <= end {
                guard let rs = u32LE(p), rs >= 52, p + Int(rs) <= end else {
                    out += " 第\(ri)条异常 size=\(u32LE(p) ?? 0) 起点=\(p)"
                    break
                }
                p += Int(rs)
                ri += 1
            }
            if p != end { out += " 页尾 p=\(p) vs end=\(end)" }
            off = end
        }
        return out
    }

    /// host 脱敏：只留头 2 位 + 尾 8 位。
    static func maskHost(_ host: String) -> String {
        guard host.count > 12 else { return String(host.prefix(2)) + "***" }
        return host.prefix(2) + "***" + host.suffix(8)
    }

    /// sessionid 值脱敏：只留头 4 位 + 长度。
    static func maskValue(_ value: String) -> String {
        "\(value.prefix(4))***（\(value.count) 字符）"
    }

    /// cookie 过期时间：Mac 绝对时间 → 可读日期；0 = 会话级。
    static func expiryText(_ expiry: Double) -> String {
        if expiry <= 0 { return "会话级（不过期）" }
        let date = Date(timeIntervalSinceReferenceDate: expiry)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
