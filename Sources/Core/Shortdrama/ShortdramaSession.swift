import CommonCrypto
import Foundation

/// 短剧登录态：Chromium 系浏览器 cookie 库解密。
/// 逐函数照搬 `~/code/novel-downloader/shortdrama.go`：
/// `browserSpec`(:117) / `browserSpecs`(:124) / `shortdramaSessionID`(:159) /
/// `shortdramaSessionCandidates`(:168) / `sessionFromBrowser`(:188) / `expandHome`(:246) /
/// `cookieExpired`(:255)。
///
/// 解密算法与 `browser_cookie3` 一致：钥匙串密钥 → PBKDF2(saltysalt, 1003) →
/// AES-128-CBC(iv=16 空格) → 库版本 ≥24 时去掉前 32 字节完整性前缀。
enum ShortdramaSession {
    /// shortdrama.go:117 `browserSpec`：浏览器登录态来源（钥匙串密钥服务名 + cookie 库路径）。
    struct BrowserSpec: Sendable {
        let name: String
        let keyService: String
        let cookiePath: String
    }

    /// shortdrama.go:124 `browserSpecs`（Chromium 系加密格式一致，按顺序试）
    static let browserSpecs: [BrowserSpec] = [
        BrowserSpec(name: "Chrome", keyService: "Chrome Safe Storage", cookiePath: "~/Library/Application Support/Google/Chrome/Default/Cookies"),
        BrowserSpec(name: "Edge", keyService: "Microsoft Edge Safe Storage", cookiePath: "~/Library/Application Support/Microsoft Edge/Default/Cookies"),
        BrowserSpec(name: "Brave", keyService: "Brave Safe Storage", cookiePath: "~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"),
        BrowserSpec(name: "Vivaldi", keyService: "Vivaldi Safe Storage", cookiePath: "~/Library/Application Support/Vivaldi/Default/Cookies"),
        BrowserSpec(name: "Opera", keyService: "Opera Safe Storage", cookiePath: "~/Library/Application Support/com.operasoftware.Opera/Default/Cookies"),
    ]

    /// shortdrama.go:159 `shortdramaSessionID`：取第一个可用浏览器的 sessionid（不校验服务端）。
    static func shortdramaSessionID() async throws -> String {
        let sids = try await shortdramaSessionCandidates()
        return sids[0]
    }

    /// shortdrama.go:168 `shortdramaSessionCandidates`：各浏览器候选（按浏览器顺序，已过滤过期）。
    /// M3-d：**Safari 优先**（明文 cookie，不需要钥匙串），再依次试 Chromium 系。
    static func shortdramaSessionCandidates() async throws -> [String] {
        var sids: [String] = []
        var kcErr: ShortdramaFailure?
        var fdaErr: ShortdramaFailure?

        // ── Safari 优先 ──（读被 TCC 拒时记下来，优先于「未登录」报出去）
        do {
            let sid = try SafariCookies.shortdramaSessionID()
            if !sid.isEmpty { sids.append(sid) }
        } catch let failure as ShortdramaFailure where failure.kind == .needsFullDiskAccess {
            fdaErr = failure
        } catch {
            // Safari 没装/没登录：继续试 Chromium
        }

        for b in browserSpecs {
            do {
                let sid = try await sessionFromBrowser(b)
                if !sid.isEmpty { sids.append(sid) }
            } catch {
                // 记录钥匙串问题，优先提示它而不是笼统的「未登录」
                if ShortdramaKeychain.isKeychainAccessIssue(error), kcErr == nil {
                    kcErr = (error as? ShortdramaFailure) ?? ShortdramaFailure(message: error.localizedDescription, kind: .keychain)
                }
            }
        }
        if sids.isEmpty {
            // 权限不足最有指导性，优先于钥匙串/未登录报出去
            if let fdaErr { throw fdaErr }
            if let kcErr { throw kcErr }
            throw ShortdramaFailure(
                message: "未检测到 shortdramas 登录态:请在 Safari 登录 www.shortdramas.com 后重试（也支持 Chrome/Edge 等 Chromium 浏览器）",
                kind: .noSession
            )
        }
        return sids
    }

    /// 自检用：真正读钥匙串（执行 `security -w`）的次数。正常启动 / 无浏览器登录态时应为 0。
    private static let keychainReadLock = NSLock()
    nonisolated(unsafe) private static var _keychainReads = 0
    static var keychainReads: Int {
        keychainReadLock.lock(); defer { keychainReadLock.unlock() }
        return _keychainReads
    }

    /// shortdrama.go:188 `sessionFromBrowser`：读某个浏览器的 `.shortdramas.com` sessionid 并解密。
    ///
    /// 与 Go 的唯一顺序差异：**先看 cookie 库里有没有这条 sessionid，再读钥匙串密钥**。
    /// 密钥只在真正要解密时才需要，这样「浏览器没装/没用过/没这条 cookie」不会弹出钥匙串授权，
    /// 错误文案与 Go 版逐字一致。
    static func sessionFromBrowser(_ b: BrowserSpec) async throws -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let db = expandHome(home: home, b.cookiePath)

        guard FileManager.default.fileExists(atPath: db) else {
            throw ShortdramaFailure(message: "\(b.name) 未安装或从未使用过")
        }

        // 库版本 ≥24 才有 32 字节 SHA256 完整性前缀
        var needStrip = false
        if let v = try? await ShortdramaKeychain.runCmd(timeout: 20, executable: "/usr/bin/sqlite3", args: [db, "SELECT value FROM meta WHERE key='version'"]),
           let n = Int(String(decoding: v, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), n >= 24 {
            needStrip = true
        }

        let hexOut: Data
        do {
            hexOut = try await ShortdramaKeychain.runCmd(timeout: 20, executable: "/usr/bin/sqlite3", args: [
                db,
                "SELECT hex(encrypted_value), expires_utc FROM cookies WHERE host_key='.shortdramas.com' AND name='sessionid' LIMIT 1",
            ])
        } catch {
            throw ShortdramaFailure(message: "\(b.name) 无该 cookie")
        }
        let row = String(decoding: hexOut, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !row.isEmpty else { throw ShortdramaFailure(message: "\(b.name) 无该 cookie") }

        // sqlite3 默认列分隔符是 "|"
        let cols = row.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var expires: Int64 = 0
        if cols.count == 2 { expires = Int64(cols[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        if cookieExpired(expires) {
            throw ShortdramaFailure(message: "\(b.name) 的登录会话已过期")
        }

        // ── 到这里才真正需要密钥 ──
        ShortdramaSession.noteKeychainRead()
        let keyOut: Data
        do {
            keyOut = try await ShortdramaKeychain.runCmd(timeout: 20, executable: "/usr/bin/security", args: [
                "-q", "find-generic-password", "-w", "-s", b.keyService,
            ])
        } catch {
            if ShortdramaKeychain.isKeychainAccessIssue(error) { throw ShortdramaKeychain.keychainErr(error) }
            throw ShortdramaFailure(message: "\(b.name) 未安装或从未使用过")
        }
        // Go: pbkdf2.Key(bytes.TrimSpace(key), []byte("saltysalt"), 1003, 16, sha1.New)
        let key = Data(String(decoding: keyOut, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let derived = pbkdf2SHA1(password: key, salt: Data("saltysalt".utf8), rounds: 1003, keyLength: 16)
        guard derived.count == 16 else { throw ShortdramaFailure(message: "钥匙串密钥派生失败") }

        guard let raw = decodeHex(cols[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ShortdramaFailure(message: "cookie 十六进制解析失败")
        }
        guard raw.count >= 3, String(decoding: raw.prefix(3), as: UTF8.self) == "v10" else {
            throw ShortdramaFailure(message: "cookie 格式不支持")
        }
        let cipherBytes = [UInt8](raw.dropFirst(3))
        guard !cipherBytes.isEmpty, cipherBytes.count % kCCBlockSizeAES128 == 0 else {
            throw ShortdramaFailure(message: "cookie 格式不支持")
        }

        let iv = [UInt8](repeating: 0x20, count: 16) // bytes.Repeat([]byte(" "), 16)
        var plain = [UInt8](repeating: 0, count: cipherBytes.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
            [UInt8](derived), derived.count, iv,
            cipherBytes, cipherBytes.count, &plain, plain.count, &moved
        )
        guard status == kCCSuccess else { throw ShortdramaFailure(message: "cookie 解密失败") }
        plain = Array(plain.prefix(moved))
        // PKCS7 去填充
        if let last = plain.last {
            let pad = Int(last)
            if pad >= 1 && pad <= 16 && pad <= plain.count { plain = Array(plain.prefix(plain.count - pad)) }
        }
        if needStrip && plain.count >= 32 { plain = Array(plain.dropFirst(32)) }
        return String(decoding: plain, as: UTF8.self)
    }

    /// shortdrama.go:246 `expandHome`
    static func expandHome(home: String, _ p: String) -> String {
        if p.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(p.dropFirst(2))) }
        return p
    }

    /// shortdrama.go:255 `cookieExpired`：Chromium 过期时间戳（微秒，自 1601-01-01）。
    /// 0 = 会话级 cookie（浏览器关闭才清）。
    static func cookieExpired(_ expiresUTC: Int64) -> Bool {
        if expiresUTC <= 0 { return false }
        let date = Date(timeIntervalSince1970: Double(expiresUTC) / 1_000_000 - 11_644_473_600)
        return Date() > date
    }

    /// 自检用：逐个浏览器摊开探测结果（不改变上面的算法，只把每个浏览器的错误单独暴露出来）。
    static func diagnoseBrowsers() async -> [(name: String, detail: String)] {
        var out: [(String, String)] = []
        for b in browserSpecs {
            do {
                let sid = try await sessionFromBrowser(b)
                out.append((b.name, sid.isEmpty ? "找到空 sessionid" : "找到 sessionid（已过滤过期）"))
            } catch {
                out.append((b.name, error.localizedDescription))
            }
        }
        return out
    }

    // MARK: - 解密底座（Go: golang.org/x/crypto/pbkdf2 + crypto/aes）

    /// PBKDF2-HMAC-SHA1（Go: `pbkdf2.Key(pass, salt, iter, keyLen, sha1.New)`）。
    static func pbkdf2SHA1(password: Data, salt: Data, rounds: UInt32, keyLength: Int) -> Data {
        guard !password.isEmpty, !salt.isEmpty, keyLength > 0 else { return Data() }
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status: Int32 = password.withUnsafeBytes { pw in
            salt.withUnsafeBytes { s in
                derived.withUnsafeMutableBufferPointer { out in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                        s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        rounds,
                        out.baseAddress, out.count
                    )
                }
            }
        }
        return status == kCCSuccess ? Data(derived) : Data()
    }

    /// Go: `encoding/hex.DecodeString`（奇数长度/非法字符返回 nil）。
    static func decodeHex(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return Data(out)
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30            // 0-9
        case 0x61...0x66: return c - 0x61 + 10       // a-f
        case 0x41...0x46: return c - 0x41 + 10       // A-F
        default: return nil
        }
    }

    private static func noteKeychainRead() {
        keychainReadLock.lock()
        _keychainReads += 1
        keychainReadLock.unlock()
    }
}
