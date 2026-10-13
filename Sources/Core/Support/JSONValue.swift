import Foundation

/// 最小 JSON 值模型。
/// 内核（Rust）返回的 JSON 字段类型会随版本变化（score 有时是 Double 有时是 String，
/// word_number 有时是 Int 有时缺失），用强类型 struct 会写一堆脆弱的可选解析；
/// 用 JSONValue + 宽松取值器，接口小改不会让界面直接崩。
enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    /// M10：>15 位的纯整数字面量**按原文保真**，不走 Double。
    /// 短剧后台的 19 位小说 ID 走 `.number` 时尾数会被 Double 抹掉：
    /// `7613834044236631102` → `7613834044236631040`，逐字符比对必然失败。
    /// 落到这一分支的数字：`stringValue` 逐字符等于 JSON 原文，
    /// `intValue` 仍按 Int64 解析（19 位 ID < 2^63，安全）。
    case integerText(String)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let text = JSONValue.bigIntegerLiteral(c) {
            self = .integerText(text)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .null
        }
    }

    /// 只用 `Decimal` 读「指数为 0 且 >15 位」的整数字面量：
    /// JSONDecoder 对 Decimal 按 JSON 原文解析（不经过 Double），所以不丢精度。
    private static func bigIntegerLiteral(_ c: SingleValueDecodingContainer) -> String? {
        guard let d = try? c.decode(Decimal.self), d.exponent == 0 else { return nil }
        let text = NSDecimalNumber(decimal: d).stringValue
        return text.count > 15 ? text : nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .integerText(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .integerText(let s): return Int(s)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .integerText(let s): return Double(s)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .integerText(let s): return s == "true"
        case .string(let s): return s == "true"
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 取字符串，数字/布尔也转（用于「可能返回数字的文本字段」）。
    var looseString: String? { stringValue }
}

extension JSONValue {
    /// 先剥掉可能的 `{"data": …}` 外壳，便于兼容内核响应包装层变化。
    func unwrapped() -> JSONValue {
        if let data = self["data"], case .object = data { return data }
        return self
    }
}

enum FMJSON {
    static let decoder = JSONDecoder()

    static func parse(_ data: Data) throws -> JSONValue {
        try decoder.decode(JSONValue.self, from: data)
    }
}
