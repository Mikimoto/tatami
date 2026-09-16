/// 保序的 JSON 值。
///
/// 為什麼不用 JSONSerialization：它回 NSDictionary（鍵序沒了），而且把數字解成
/// NSNumber（字面值沒了）。`layout.json` 兩者都不能失去——鍵序決定視窗認領順序與
/// default 的 fallback，字面值決定輸出能不能與 `jq .` 逐位元組相同。
///
/// 這個型別放在 Domain 而不是 Wire：LayoutValidator 是純規則、屬 Domain，
/// 而它吃 JSONValue。若 JSONValue 留在 Wire，Domain 就得反向依賴 Wire，
/// 與相依方向衝突（WorkmodeArchitectureTests 會擋）。
/// parser 與 writer 留在 Wire——它們需要 Foundation，這個型別不需要。
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// 原始字面值，不是數值。jq 1.8 逐字保留（`2.50` 不會變 `2.5`），
    /// 解成 Double 再印就對不上。要算數的人自己 `Double(literal)`。
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])
}

/// 物件成員。用 struct 而不是 tuple：enum payload 裡的 tuple 無法自動合成 Equatable。
public struct JSONMember: Equatable, Sendable {
    public let key: String
    public let value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public enum JSONParseError: Error, Equatable {
    /// offset 是位元組位置，方便對照原始輸入。
    case unexpected(byte: UInt8?, offset: Int)
    case truncated
    case trailingGarbage(offset: Int)
    case badEscape(offset: Int)
    case badUTF8(offset: Int)
}
