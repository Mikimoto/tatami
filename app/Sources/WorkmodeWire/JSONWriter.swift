import Foundation
import WorkmodeDomain

/// 把 `JSONValue` 印成 `jq .` 的格式。
///
/// 下面每一條規則都是拿 jq 1.8.2 實跑出來的，不是照 JSON 規格推的——規格允許的自由度
/// 這裡全都被 jq 的實作選擇釘死了，推錯一條輸出就對不上：
///
/// - 兩個空格縮排，冒號後一個空格
/// - 空物件與空陣列不換行，就是兩個字元
/// - 數字逐字保留原始字面值（`2.50` 不會變 `2.5`）
/// - 斜線 `/` **不**跳脫，中日韓 **不**跳脫（原樣 UTF-8）
/// - U+007F（DEL）**要**跳脫。JSON 規格並不要求，這是 jq 的 quirk
/// - unicode 跳脫是六個字元且 hex **小寫**（`\u007f`，不是 `\u007F`）
///
/// 這支與同目錄的 `JSONEnvelope` 是**兩個方向相反的序列化器，不要合併**：
/// 這邊保留來源鍵序（windows 的順序決定誰先認領視窗、profiles 的第一個是 fallback），
/// 那邊要 `.sortedKeys` 讓封套鍵序穩定好做逐位元組斷言。DRY 在這裡是錯的。
public enum JSONWriter {
    /// 不含結尾換行。要寫檔的人自己加——`jq .` 的檔尾有一個換行。
    public static func format(_ value: JSONValue) -> String {
        var out = ""
        write(value, indent: 0, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, indent: Int, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case let .bool(flag):
            out += flag ? "true" : "false"
        case let .number(literal):
            // 字面值直接吐。轉成 Double 再印會讓 2.50 變 2.5、1.0 變 1。
            out += literal
        case let .string(text):
            writeString(text, into: &out)
        case let .array(items):
            // 空容器不換行。
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            let inner = pad(indent + 1)
            for (index, item) in items.enumerated() {
                out += inner
                write(item, indent: indent + 1, into: &out)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += pad(indent) + "]"
        case let .object(members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            let inner = pad(indent + 1)
            for (index, member) in members.enumerated() {
                out += inner
                writeString(member.key, into: &out)
                out += ": "
                write(member.value, indent: indent + 1, into: &out)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += pad(indent) + "}"
        }
    }

    private static func pad(_ indent: Int) -> String {
        String(repeating: " ", count: indent * 2)
    }

    /// 走 `unicodeScalars` 而不是 `Character`：Character 是字素叢集，
    /// 拆不出要個別跳脫的那幾個純量。非 ASCII 原樣附加。
    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
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
                    // 小寫 x 才會給小寫 hex：jq 印的是 `\u007f` 不是 `\u007F`。
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
