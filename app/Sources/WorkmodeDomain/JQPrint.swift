/// jq 把一個值變成文字的四種印法：`\(...)` 插值、`jq -r`、compact JSON、`@tsv` 的一欄。
///
/// 為什麼是 Domain 而不是 Wire：Wire 的 `JSONWriter` 是縮排形式的完整實作，而 Domain
/// 不能 import Wire（相依方向是 Wire → Domain）。這一份是最小副本，跳脫表由
/// `JSONWriterTests.escapesExactlyLikeJQ` 對真的 jq 釘住。
///
/// 為什麼要收在一起：這些印法**同時扮演兩個角色**。`Displays.matchLocation` 回傳與
/// 比對的都是 `@tsv` 轉義後的文字，所以轉義的結果會改變答案，不只是改變輸出——
/// 換句話說，它是規則的一部分而不只是印法。一份微妙寫錯的副本不會有任何訊號，
/// 而這一份走在 `validate` 與 `match_location` 的差分路徑上（`tests/diff_bash_swift.sh`
/// 拿它對真的 jq 比過），所以任何借用它的地方都繼承那份驗證。
public enum JQPrint {
    // MARK: - 值 → 文字

    /// jq 的字串插值 `\(.)`：字串直接放（不加引號），其他型別是 compact JSON。
    public static func interpolate(_ value: JSONValue) -> String {
        if case let .string(text) = value {
            return text
        }
        return compact(value)
    }

    /// `jq -r` 印一個值。`-r` **只對字串生效**（原樣印、不加引號），其餘型別照 compact。
    ///
    /// 數字逐字保留：jq 1.8 不會把 `2.50` 印成 `2.5`，而這個字串會進 argv。
    /// （只有沒被運算過的字面值才逐字保留；算術之後走 `JQNumber` 的 dtoa 模型。）
    ///
    /// 已知的刻意分歧：真的 `jq -r` 對**容器**印的是多行縮排 JSON，這裡回 compact。
    /// 縮排印法屬 Wire，Domain 不能為一條不可達的路徑依賴它——yabai 的 `.id`／
    /// `.uuid`／`.display` 一律是純量，`validate_layout` 也擋掉了容器 ratio。
    public static func raw(_ value: JSONValue) -> String {
        interpolate(value)
    }

    /// compact JSON：無空白、鍵序照來源、數字印字面值。
    public static func compact(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case let .bool(flag): flag ? "true" : "false"
        case let .number(literal): literal
        case let .string(text): "\"\(escape(text))\""
        case let .array(elements):
            "[" + elements.map(compact).joined(separator: ",") + "]"
        case let .object(members):
            "{" + members.map { "\"\(escape($0.key))\":\(compact($0.value))" }
                .joined(separator: ",") + "}"
        }
    }

    // MARK: - 跳脫

    /// JSON 字串的內層跳脫（**不含**外層引號）。與 `JSONWriter.writeString` 是同一張表：
    /// 實測 `\(.window)` 對含 U+007F 的物件吐**小寫** hex 的六字元跳脫序列（backslash u 0 0 7 f），而非 ASCII 不跳脫。
    ///
    /// 走 `unicodeScalars` 而不是 `Character`：Character 是字素叢集，拆不出要個別
    /// 跳脫的那幾個純量。
    public static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // 0x7F 也在內：jq 跳脫 DEL，儘管 JSON 規格沒要求。
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\u" + hex4(scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// 四位十六進位，**小寫**——jq 印的是小寫 hex。Domain 不能用 Foundation 的
    /// `String(format:)`，所以自己拼。
    private static func hex4(_ value: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        return String((0 ..< 4).reversed().map { digits[Int((value >> UInt32($0 * 4)) & 0xF)] })
    }

    // MARK: - @tsv

    /// `@tsv` 的一欄裡，轉義的**只有**這五個。0x00–0x1F 與 0x7F 全部逐個實測過，
    /// 其餘控制字元（含 DEL）原樣通過，雙引號也不轉義——照 CSV 的直覺加引號處理就錯了。
    /// 注意這張表與 `escape` 完全不同，兩者不可互相借用。
    public static func tsvEscape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\0": out += "\\0"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// `@tsv` 的一欄。nil ＝ jq 的 runtime error
    /// （`object ({"k":1}) is not valid in a csv row`）。
    ///
    /// 串流會在那裡中止，而**前面已經印出去的行留在 stdout 上**——所以呼叫端是
    /// 「印到出錯為止」而不是整批放棄。
    ///
    /// 數字逐字保留：`@tsv` 印的是 parser 收進來的字面值（`2.50` 不變 `2.5`）。
    public static func tsvField(_ value: JSONValue) -> String? {
        switch value {
        case .null: ""
        case let .bool(flag): flag ? "true" : "false"
        case let .number(literal): literal
        case let .string(text): tsvEscape(text)
        case .array, .object: nil
        }
    }
}
