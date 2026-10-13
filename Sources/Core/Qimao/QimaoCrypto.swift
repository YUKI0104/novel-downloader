import CommonCrypto
import Foundation

/// 七猫解密与下载包解包（对照 `qimao.go:602 Decrypt` / `:632 UnzipChapters`）。
/// 独立成 nonisolated 的工具，便于下载/写出在任意线程调用。
enum QimaoCrypto {
    /// qimao.go:31 `AESKeyHex`
    static let aesKeyHex = "32343263636238323330643730396531"

    /// hex → 16 字节密钥
    static let aesKey: [UInt8] = {
        var out: [UInt8] = []
        var index = aesKeyHex.startIndex
        while let next = aesKeyHex.index(index, offsetBy: 2, limitedBy: aesKeyHex.endIndex), next > index {
            if let byte = UInt8(aesKeyHex[index..<next], radix: 16) { out.append(byte) }
            index = next
        }
        return out
    }()

    /// qimao.go:602 `Decrypt`：AES-128-CBC，base64 → 前 16 字节 IV + 密文，PKCS7 去填充；失败返回原文。
    static func decrypt(_ text: String) -> String {
        guard let raw = Data(base64Encoded: text), raw.count >= 16 else { return text }
        let iv = [UInt8](raw.prefix(16))
        let cipher = [UInt8](raw.dropFirst(16))
        guard !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else { return text }

        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
            aesKey, aesKey.count, iv,
            cipher, cipher.count, &plain, plain.count, &moved
        )
        guard status == kCCSuccess else { return text }
        plain = Array(plain.prefix(moved))
        if let last = plain.last {
            let pad = Int(last)
            if pad >= 1 && pad <= 16 && pad <= plain.count {
                plain = Array(plain.prefix(plain.count - pad))
            }
        }
        return String(decoding: plain, as: UTF8.self)
    }

    /// qimao.go:632 `UnzipChapters`：解压 zip，按「文件名去扩展名」= 章节 ID 解密映射。
    static func unzipChapters(_ zipBytes: Data) throws -> [String: String] {
        var map: [String: String] = [:]
        for entry in try QimaoZip.read(zipBytes) {
            let chapterID = entry.name.hasSuffix(".txt") ? String(entry.name.dropLast(4)) : entry.name
            map[chapterID] = decrypt(String(decoding: entry.data, as: UTF8.self))
        }
        return map
    }
}
