import Foundation
import WorkmodeDomain

/// 手寫的保序 JSON parser。走位元組而不是 Character：字串內容要原樣保留，
/// 而且錯誤位置用位元組 offset 才對得回原始輸入。
public enum JSONParser {
    public static func parse(_ text: String) throws -> JSONValue {
        var cursor = Cursor(bytes: Array(text.utf8))
        cursor.skipWhitespace()
        let value = try cursor.parseValue()
        cursor.skipWhitespace()
        guard cursor.atEnd else { throw JSONParseError.trailingGarbage(offset: cursor.offset) }
        return value
    }

    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0

        var atEnd: Bool {
            offset >= bytes.count
        }

        var current: UInt8? {
            atEnd ? nil : bytes[offset]
        }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                offset += 1
            }
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard current == byte else {
                    throw JSONParseError.unexpected(byte: current, offset: offset)
                }
                offset += 1
            }
        }

        mutating func parseValue() throws -> JSONValue {
            guard let byte = current else { throw JSONParseError.truncated }
            switch byte {
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "\""): return try .string(parseString())
            case UInt8(ascii: "["): return try .array(parseArray())
            case UInt8(ascii: "{"): return try .object(parseObject())
            default: return try .number(parseNumberLiteral())
            }
        }

        mutating func parseArray() throws -> [JSONValue] {
            offset += 1 // 吃掉 [
            var items: [JSONValue] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                offset += 1; return items
            }
            while true {
                skipWhitespace()
                try items.append(parseValue())
                skipWhitespace()
                switch current {
                case UInt8(ascii: ","): offset += 1
                case UInt8(ascii: "]"): offset += 1; return items
                case nil: throw JSONParseError.truncated
                default: throw JSONParseError.unexpected(byte: current, offset: offset)
                }
            }
        }

        mutating func parseObject() throws -> [JSONMember] {
            offset += 1 // 吃掉 {
            var members: [JSONMember] = []
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                offset += 1; return members
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else {
                    throw JSONParseError.unexpected(byte: current, offset: offset)
                }
                let key = try parseString()
                skipWhitespace()
                guard current == UInt8(ascii: ":") else {
                    throw JSONParseError.unexpected(byte: current, offset: offset)
                }
                offset += 1
                skipWhitespace()
                // 重複鍵不合併也不報錯：jq 的行為是後者勝出，但那是 jq 的事；
                // 這一層原樣保留，要不要擋由 validate 決定。
                try members.append(JSONMember(key: key, value: parseValue()))
                skipWhitespace()
                switch current {
                case UInt8(ascii: ","): offset += 1
                case UInt8(ascii: "}"): offset += 1; return members
                case nil: throw JSONParseError.truncated
                default: throw JSONParseError.unexpected(byte: current, offset: offset)
                }
            }
        }

        mutating func parseString() throws -> String {
            offset += 1 // 吃掉開頭的 "
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []

            /// raw 收原樣的位元組（非 ASCII 直接過），碰到跳脫才 flush 成字串。
            func flushRaw() throws {
                guard !raw.isEmpty else { return }
                guard let decoded = String(bytes: raw, encoding: .utf8) else {
                    throw JSONParseError.badUTF8(offset: offset)
                }
                scalars.append(contentsOf: decoded.unicodeScalars)
                raw.removeAll(keepingCapacity: true)
            }

            while true {
                guard let byte = current else { throw JSONParseError.truncated }
                if byte == UInt8(ascii: "\"") {
                    offset += 1
                    try flushRaw()
                    return String(scalars)
                }
                if byte != UInt8(ascii: "\\") {
                    raw.append(byte)
                    offset += 1
                    continue
                }
                try flushRaw()
                offset += 1 // 吃掉反斜線
                guard let escape = current else { throw JSONParseError.truncated }
                offset += 1
                if let scalar = Self.singleByteEscapes[escape] {
                    scalars.append(scalar)
                } else if escape == UInt8(ascii: "u") {
                    try scalars.append(parseUnicodeEscape())
                } else {
                    throw JSONParseError.badEscape(offset: offset - 1)
                }
            }
        }

        /// JSON 的八個單位元組跳脫。寫成表而不是 switch：這是一份對照表，沒有八種
        /// 邏輯，只有八筆資料——而 switch 的每個 case 都算一個分支。
        /// `\b` 與 `\f` 沒有 Swift 字面值，用碼位寫。
        static let singleByteEscapes: [UInt8: Unicode.Scalar] = [
            UInt8(ascii: "\""): "\"",
            UInt8(ascii: "\\"): "\\",
            UInt8(ascii: "/"): "/",
            UInt8(ascii: "b"): Unicode.Scalar(0x08)!,
            UInt8(ascii: "f"): Unicode.Scalar(0x0C)!,
            UInt8(ascii: "n"): "\n",
            UInt8(ascii: "r"): "\r",
            UInt8(ascii: "t"): "\t",
        ]

        /// `\uXXXX`，含代理對。呼叫時反斜線與 `u` 都已經吃掉了。
        ///
        /// 高代理沒跟低代理就是壞資料，這裡 throw 而不是輸出半個代理：那會讓字串
        /// 在之後某個無關的地方壞掉，很難追。
        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let first = try parseHex4()
            guard first >= 0xD800, first <= 0xDBFF else {
                guard let scalar = Unicode.Scalar(first) else {
                    throw JSONParseError.badEscape(offset: offset)
                }
                return scalar
            }
            guard current == UInt8(ascii: "\\") else {
                throw JSONParseError.badEscape(offset: offset)
            }
            offset += 1
            guard current == UInt8(ascii: "u") else {
                throw JSONParseError.badEscape(offset: offset)
            }
            offset += 1
            let second = try parseHex4()
            guard second >= 0xDC00, second <= 0xDFFF else {
                throw JSONParseError.badEscape(offset: offset)
            }
            let combined = 0x10000
                + (UInt32(first - 0xD800) << 10)
                + UInt32(second - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else {
                throw JSONParseError.badEscape(offset: offset)
            }
            return scalar
        }

        mutating func parseHex4() throws -> UInt16 {
            var value: UInt16 = 0
            for _ in 0 ..< 4 {
                guard let byte = current else { throw JSONParseError.truncated }
                let digit: UInt16
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit = UInt16(byte - 48)
                case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit = UInt16(byte - 87)
                case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit = UInt16(byte - 55)
                default: throw JSONParseError.badEscape(offset: offset)
                }
                value = value << 4 | digit
                offset += 1
            }
            return value
        }

        /// 刻意寬鬆：只收集看起來像數字的位元組，不驗證形狀，所以 `1.2.3` 會被當成
        /// 一個 token 收下而 jq 會拒絕。這是已知的嚴格度落差，留給之後的 validate
        /// 補——parser 只負責照原樣讀進來。
        mutating func parseNumberLiteral() throws -> String {
            let start = offset
            while let byte = current,
                  (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                  || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")
                  || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e")
                  || byte == UInt8(ascii: "E")
            {
                offset += 1
            }
            guard offset > start else {
                throw JSONParseError.unexpected(byte: current, offset: offset)
            }
            return String(decoding: bytes[start ..< offset], as: UTF8.self)
        }
    }
}
