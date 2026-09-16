import WorkmodeDomain

// 這兩支原本在七個測試檔裡各自 `private` 抄一份，逐字相同。收成一份是拆檔的前置：
// 一個檔拆成兩個之後，兩邊都要用到它們，而再抄一份只會讓副本從七份變成九份。
//
// 刻意不是 `JSONValue` 的 extension：那會讓一個只在測試裡成立的簡寫看起來像
// Domain 的公開 API。它們是 fixture 的縮寫，不是型別的能力。

/// `.object` 的縮寫。鍵序照傳入的順序保留——這個 repo 的 writer 靠它。
func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
    .object(pairs.map { JSONMember(key: $0.0, value: $0.1) })
}

/// `.number` 的縮寫。收字串是因為 jq 1.8 逐字保留沒被運算過的數字字面值，
/// 而好幾組斷言驗的正是「`2.50` 沒有變成 `2.5`」。
func num(_ literal: String) -> JSONValue {
    .number(literal)
}

/// 一條 window 比對規則。`fallback` 給 `url-contains` 那種需要備援比對的規則用，
/// 不給就沒有那個鍵——兩種形狀在 layout.json 裡都是合法的。
///
/// 這支原本在 LayoutQueryTests 與 ProfileResolutionTests 各一份，後者是前者的
/// fallback 為 nil 的特例，所以留超集這份就夠。
func rule(_ label: String, _ kind: String, _ value: String,
          fallback: (String, String)? = nil) -> JSONValue
{
    var pairs: [(String, JSONValue)] = [
        ("label", .string(label)),
        ("match", .array([.string(kind), .string(value)])),
    ]
    if let fallback {
        pairs.append(("fallback", .array([.string(fallback.0), .string(fallback.1)])))
    }
    return obj(pairs)
}

/// 一個分割節點。LayoutTreeTests 與 RectTreeTests 原本各有一份逐字相同的。
func split(_ axis: String, _ first: JSONValue, _ second: JSONValue) -> JSONValue {
    obj([("axis", .string(axis)), ("children", .array([first, second]))])
}
