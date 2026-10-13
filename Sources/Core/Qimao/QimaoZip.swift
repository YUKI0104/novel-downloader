import Compression
import Foundation

/// 最小 ZIP 读写（无第三方依赖）。
///
/// 读：下载包是服务端打好的 zip（章节 ID 为文件名），这里自己解析中央目录 +
/// 用 `Compression` 的 raw deflate（`COMPRESSION_ZLIB` 在 Apple 平台上就是裸 deflate）
/// 解压，**不调用外部 unzip**。
/// 写：EPUB 需要自己打 zip（`mimetype` 必须第一个且 STORED，其余 deflate）。
enum QimaoZip {

    enum ZipError: Error, LocalizedError {
        case badArchive(String)
        var errorDescription: String? {
            switch self {
            case .badArchive(let why): "压缩包解析失败（\(why)）"
            }
        }
    }

    struct Entry: Sendable {
        var name: String
        var data: Data
    }

    // MARK: - 读

    /// 解析 zip → 条目列表（解压后）。
    static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { throw ZipError.badArchive("找不到 EOCD") }
        let count = Int(u16(bytes, eocd + 10))
        let cdOffset = Int(u32(bytes, eocd + 16))

        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(bytes, p) == 0x0201_4B50 else {
                throw ZipError.badArchive("中央目录条目签名不对 @\(p)")
            }
            let method = u16(bytes, p + 10)
            let compSize = Int(u32(bytes, p + 20))
            let rawSize = Int(u32(bytes, p + 24))
            let nameLen = Int(u16(bytes, p + 28))
            let extraLen = Int(u16(bytes, p + 30))
            let commentLen = Int(u16(bytes, p + 32))
            let localOffset = Int(u32(bytes, p + 42))
            guard p + 46 + nameLen <= bytes.count else { throw ZipError.badArchive("条目名越界") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue } // 目录

            // 本地头：拿真实数据起点（本地头的 name/extra 长度可能与中央目录不同）
            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4B50 else {
                throw ZipError.badArchive("本地头签名不对 @\(localOffset)")
            }
            let lNameLen = Int(u16(bytes, localOffset + 26))
            let lExtraLen = Int(u16(bytes, localOffset + 28))
            let start = localOffset + 30 + lNameLen + lExtraLen
            let end = start + compSize
            guard end <= bytes.count else { throw ZipError.badArchive("条目数据越界 \(name)") }

            let raw = Data(bytes[start..<end])
            let payload: Data
            switch method {
            case 0: payload = raw
            case 8:
                guard let inflated = inflate(raw, expected: rawSize) else {
                    throw ZipError.badArchive("deflate 解压失败 \(name)")
                }
                payload = inflated
            default:
                throw ZipError.badArchive("不支持的压缩方式 \(method)（\(name)）")
            }
            entries.append(Entry(name: name, data: payload))
        }
        return entries
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var i = bytes.count - 22
        while i >= 0 {
            if u32(bytes, i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    // MARK: - 写

    struct OutEntry {
        var name: String
        var data: Data
        var stored: Bool = false // mimetype 必须 STORED
    }

    /// 打 zip：deflate（方法 8），`stored=true` 的条目原样存。
    static func write(_ entries: [OutEntry]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let payload: Data
            let method: UInt16
            if entry.stored {
                payload = entry.data
                method = 0
            } else if let deflated = deflate(entry.data) {
                payload = deflated
                method = 8
            } else {
                payload = entry.data
                method = 0
            }
            let localOffset = UInt32(out.count)

            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            out.append(contentsOf: u16le(20))                     // version needed
            out.append(contentsOf: u16le(0))                      // flags
            out.append(contentsOf: u16le(method))
            out.append(contentsOf: u16le(0))                    // mod time
            out.append(contentsOf: u16le(0))                    // mod date
            out.append(contentsOf: u32le(crc))
            out.append(contentsOf: u32le(UInt32(payload.count)))
            out.append(contentsOf: u32le(UInt32(entry.data.count)))
            out.append(contentsOf: u16le(UInt16(nameBytes.count)))
            out.append(contentsOf: u16le(0))                      // extra len
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(contentsOf: u16le(20))                 // version made by
            central.append(contentsOf: u16le(20))                 // version needed
            central.append(contentsOf: u16le(0))
            central.append(contentsOf: u16le(method))
            central.append(contentsOf: u16le(0))
            central.append(contentsOf: u16le(0))
            central.append(contentsOf: u32le(crc))
            central.append(contentsOf: u32le(UInt32(payload.count)))
            central.append(contentsOf: u32le(UInt32(entry.data.count)))
            central.append(contentsOf: u16le(UInt16(nameBytes.count)))
            central.append(contentsOf: u16le(0))                  // extra
            central.append(contentsOf: u16le(0))                  // comment
            central.append(contentsOf: u16le(0))                  // disk
            central.append(contentsOf: u16le(0))                  // internal attrs
            central.append(contentsOf: u32le(0))                  // external attrs
            central.append(contentsOf: u32le(localOffset))
            central.append(contentsOf: nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out.append(contentsOf: central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        out.append(contentsOf: u16le(0))                          // disk
        out.append(contentsOf: u16le(0))                          // cd start disk
        out.append(contentsOf: u16le(UInt16(entries.count)))
        out.append(contentsOf: u16le(UInt16(entries.count)))
        out.append(contentsOf: u32le(UInt32(central.count)))
        out.append(contentsOf: u32le(cdOffset))
        out.append(contentsOf: u16le(0))                          // comment len
        return out
    }

    private static func u16le(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func u32le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: - deflate / crc32

    static func inflate(_ input: Data, expected: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        let capacity = max(expected, 1) + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let capacity = input.count + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}
