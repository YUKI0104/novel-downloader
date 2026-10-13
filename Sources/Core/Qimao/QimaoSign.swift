import CryptoKit
import Foundation

/// 七猫签名 / 请求头 / 书号归一化 / 文件名工具。
///
/// 逐函数照搬 `~/code/novel-downloader/qimao/qimao.go`：
///   `sign`(:54) / `stableHash`(:72) / `requestHeaders`(:83) /
///   `ExtractBookID`(:117) / `isAllDigits`(:133) / `SafeFilename`(:146) / `stripHTML`(:156)
/// **签名算法禁改**（SignKey、排序拼接、md5 hex 全部原样）。
enum QimaoSign {
    /// qimao.go:29 `SignKey`
    static let signKey = "d3dGiJc651gSQ8w1"

    /// qimao.go:36-44 `versions`（21 个 app-version，按 stableHash 取模选）
    static let versions = [
        "73720", "73700", "73620", "73600", "73500", "73420", "73400",
        "73328", "73325", "73320", "73300", "73220", "73200", "73100",
        "73000", "72900", "72820", "72800", "70720", "62010", "62112",
    ]

    /// qimao.go:54 `sign`：sorted keys 的 "k=v" 拼接 + SIGN_KEY，md5 hex（小写）。
    static func sign(_ params: [String: String]) -> String {
        var joined = ""
        for key in params.keys.sorted() {
            joined += key + "=" + (params[key] ?? "")
        }
        let digest = Insecure.MD5.hash(data: Data((joined + signKey).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// qimao.go:72 `stableHash`：模拟 Dart `string.hashCode`（确定性 signed 32-bit）。
    /// Go 里 `for _, ch := range s` 是**码点**（rune），所以这里用 unicodeScalars。
    static func stableHash(_ s: String) -> Int32 {
        var h: Int64 = 0
        for scalar in s.unicodeScalars {
            h = (h &* 31 &+ Int64(scalar.value)) & 0xFFFF_FFFF
        }
        if h >= 0x8000_0000 {
            h -= 0x1_0000_0000
        }
        return Int32(truncatingIfNeeded: h)
    }

    /// qimao.go:83 `requestHeaders`：8 个固定头 + 按书号选 app-version + sign，最后加 UA。
    /// 注意：sign 只覆盖前面那 8 个头（UA 是后加的，不参与签名）——照搬。
    static func requestHeaders(bookID: String = "") -> [String: String] {
        var h: Int64 = 0
        if !bookID.isEmpty {
            h = Int64(stableHash(bookID))
        }
        let idx: Int
        if h < 0 {
            idx = Int(-h % Int64(versions.count))
        } else {
            idx = Int(h % Int64(versions.count))
        }

        var headers: [String: String] = [
            "AUTHORIZATION": "",
            "app-version": versions[idx],
            "application-id": "com.****.reader",
            "channel": "unknown",
            "net-env": "1",
            "platform": "android",
            "qm-params": "",
            "reg": "0",
        ]
        headers["sign"] = sign(headers)
        headers["User-Agent"] = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        return headers
    }

    /// qimao.go:117 `ExtractBookID`：链接 → 裸数字 ID；纯数字原样；否则原样返回。
    static func extractBookID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"qimao\.com/shuku/(\d+)"#, #"wtzw\.com/article-detail/(\d+)"#] {
            if let range = trimmed.range(of: pattern, options: .regularExpression) {
                let matched = String(trimmed[range])
                if let digits = matched.range(of: #"\d+"#, options: .regularExpression) {
                    return String(matched[digits])
                }
            }
        }
        if isAllDigits(trimmed) { return trimmed }
        return trimmed
    }

    /// qimao.go:133 `isAllDigits`
    static func isAllDigits(_ s: String) -> Bool {
        if s.isEmpty { return false }
        return s.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// qimao.go:146 `SafeFilename`：去掉 `[<>:"/\|?*]`，再 trim ". "，空则 "book"。
    static func safeFilename(_ name: String) -> String {
        var s = name.replacingOccurrences(of: #"[<>:"/\\|?*]"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return s.isEmpty ? "book" : s
    }

    /// qimao.go:156 `stripHTML`：去掉 `<...>`。
    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    }

    /// Go `url.Values.Encode()` 的等价物：key 排序、`+` 表示空格、其余按 RFC3986 转义。
    /// 七猫的 sign 是对**解码后**的键值算的，这里只需要和 Go 生成同样的查询串。
    static func queryEncode(_ params: [String: String]) -> String {
        params.keys.sorted().map { key in
            "\(escape(key))=\(escape(params[key] ?? ""))"
        }.joined(separator: "&")
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
