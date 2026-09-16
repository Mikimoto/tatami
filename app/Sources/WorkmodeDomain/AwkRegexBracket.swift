// bracket 表達式 `[...]`：範圍、否定、字面的 `]`、以及 `[:alpha:]` 那組具名類別。
//
// 與 AwkRegexParser 分開只是型別長度。它是同一個 Parser 的一部分，唯一的呼叫端
// 是 `parsePrimary` 看到 `[` 的時候。

extension AwkRegex.Parser {
    mutating func parseBracket() throws -> AwkRegex.Node {
        index += 1 // 吃掉 `[`
        var negated = false
        if peek() == UInt8(ascii: "^") {
            negated = true
            index += 1
        }
        var members = ByteSet()
        var isFirst = true
        while true {
            guard let byte = peek() else { throw AwkRegexError.syntax }
            // 緊接在 `[` 或 `[^` 後面的 `]` 是字面的（`[]a]` 是 `]` 與 `a` 兩個字元）。
            if byte == UInt8(ascii: "]"), !isFirst {
                index += 1
                break
            }
            isFirst = false
            if byte == UInt8(ascii: "["), peek(1) == UInt8(ascii: ":") {
                try insertNamedClass(into: &members)
                continue
            }
            let low = try bracketByte()
            // `-` 在結尾（`[a-]`）是字面的減號，不是範圍的開頭。
            if peek() == UInt8(ascii: "-"), let after = peek(1), after != UInt8(ascii: "]") {
                index += 1
                let high = try bracketByte()
                if low <= high {
                    for value in low ... high {
                        members.insert(value)
                    }
                }
                // low > high（`[z-a]`）在 awk 是未定義行為，見型別的 doc。
                continue
            }
            members.insert(low)
        }
        return .cclass(members, negated: negated)
    }

    mutating func bracketByte() throws -> UInt8 {
        guard let byte = peek() else { throw AwkRegexError.syntax }
        if byte == UInt8(ascii: "\\") {
            index += 1
            guard !atEnd else { throw AwkRegexError.syntax }
            return escapeByte()
        }
        index += 1
        return byte
    }

    /// `[:digit:]` 這種。LC_ALL=C，所以全部都只認 ASCII。
    mutating func insertNamedClass(into members: inout ByteSet) throws {
        let start = index
        index += 2 // 吃掉 `[:`
        var name: [UInt8] = []
        while let byte = peek(), byte != UInt8(ascii: ":") {
            name.append(byte)
            index += 1
        }
        guard peek() == UInt8(ascii: ":"), peek(1) == UInt8(ascii: "]") else {
            // 不是完整的 `[:…:]`，退回去當普通字元處理。
            index = start
            let literal = try bracketByte()
            members.insert(literal)
            return
        }
        index += 2
        guard let test = Self.namedClasses[String(decoding: name, as: UTF8.self)] else {
            // awk 印一行 `unknown character class: foo` 到 stderr 就**繼續跑**
            // ——rc 仍是 0，那個類別只是什麼都不加（實測 `[[:foo:]a]` 等於
            // `[a]`、`[^[:foo:]]` 配得上任何東西）。所以這裡不能 throw。
            return
        }
        for value in UInt8.min ... UInt8.max where test(value) {
            members.insert(value)
        }
    }

    static let namedClasses: [String: @Sendable (UInt8) -> Bool] = [
        "alpha": { isAlpha($0) },
        "digit": { isDigit($0) },
        "alnum": { isAlpha($0) || isDigit($0) },
        "upper": { $0 >= 0x41 && $0 <= 0x5A },
        "lower": { $0 >= 0x61 && $0 <= 0x7A },
        "space": { $0 == 0x20 || ($0 >= 0x09 && $0 <= 0x0D) },
        "blank": { $0 == 0x20 || $0 == 0x09 },
        "punct": { isGraph($0) && !isAlpha($0) && !isDigit($0) },
        "print": { $0 >= 0x20 && $0 < 0x7F },
        "graph": { isGraph($0) },
        "cntrl": { $0 < 0x20 || $0 == 0x7F },
        "xdigit": { isDigit($0) || ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x66 },
    ]
}
