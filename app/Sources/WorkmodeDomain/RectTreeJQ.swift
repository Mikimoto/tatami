// `rects_to_tree` 與 `trim_ratios` 底下那組 jq 零件。與 LayoutValidatorJQ 是**兩份**
// 而不是一份：這裡的 compare／length／unique 收的是矩形與樹節點，錯誤要 throw
// 成 RectTreeError（bash 那側是 jq 的 runtime error 中止整個串流），而驗證那側
// 回 nil。合成一份要先統一錯誤形態，那就是改行為。
//
// 與 RectTree 分開只是型別長度。從 private 放寬成 internal 是拆檔的代價：
// Swift 的 private 是檔案範圍，跨檔的 extension 看不到它。

extension RectTree {
    enum Order { case less, equal, greater }

    /// jq 的陣列比較：逐元素，全同就比長度。
    static func compareArrays(_ lhs: [JSONValue], _ rhs: [JSONValue]) -> Order {
        for (lhsItem, rhsItem) in zip(lhs, rhs) {
            let order = compare(lhsItem, rhsItem)
            if order != .equal {
                return order
            }
        }
        return lhs.count == rhs.count ? .equal
            : (lhs.count < rhs.count ? .less : .greater)
    }

    /// jq 的物件比較：**先比排序過的鍵**，鍵數也同了才依那個順序比值。
    static func compareObjects(_ lhs: [JSONMember], _ rhs: [JSONMember]) -> Order {
        let (lhsKeys, rhsKeys) = (lhs.map(\.key).sorted { compareScalars($0, $1) == .less },
                                  rhs.map(\.key).sorted { compareScalars($0, $1) == .less })
        for (lhsKey, rhsKey) in zip(lhsKeys, rhsKeys) {
            let order = compareScalars(lhsKey, rhsKey)
            if order != .equal {
                return order
            }
        }
        if lhsKeys.count != rhsKeys.count {
            return lhsKeys.count < rhsKeys.count ? .less : .greater
        }
        for key in lhsKeys {
            let order = compare(lhs.first { $0.key == key }?.value ?? .null,
                                rhs.first { $0.key == key }?.value ?? .null)
            if order != .equal {
                return order
            }
        }
        return .equal
    }

    /// jq 的跨型別全序。數字比數值、字串比碼位（不是 String 的正規化比較）、
    /// 陣列逐項比、物件先比排序過的鍵再比對應的值。
    static func compare(_ lhs: JSONValue, _ rhs: JSONValue) -> Order {
        let (leftRank, rightRank) = (rank(lhs), rank(rhs))
        if leftRank != rightRank {
            return leftRank < rightRank ? .less : .greater
        }
        switch (lhs, rhs) {
        case let (.number(left), .number(right)):
            let (leftValue, rightValue) = (Double(left) ?? 0, Double(right) ?? 0)
            return leftValue == rightValue ? .equal : (leftValue < rightValue ? .less : .greater)
        case let (.string(left), .string(right)):
            return compareScalars(left, right)
        case let (.array(left), .array(right)):
            return compareArrays(left, right)
        case let (.object(left), .object(right)):
            return compareObjects(left, right)
        default:
            return .equal // 同 rank 的 null／false／true 只有相等一種可能。
        }
    }

    static func rank(_ value: JSONValue) -> Int {
        switch value {
        case .null: 0
        case let .bool(flag): flag ? 2 : 1
        case .number: 3
        case .string: 4
        case .array: 5
        case .object: 6
        }
    }

    /// 逐個 Unicode 碼位比大小。String 的 `<` 做的是正規化比較，jq 排的是碼位序。
    static func compareScalars(_ lhs: String, _ rhs: String) -> Order {
        var left = lhs.unicodeScalars.makeIterator()
        var right = rhs.unicodeScalars.makeIterator()
        while true {
            let (leftScalar, rightScalar) = (left.next(), right.next())
            if leftScalar == nil, rightScalar == nil {
                return .equal
            }
            guard let leftScalar else { return .less }
            guard let rightScalar else { return .greater }
            if leftScalar.value != rightScalar.value {
                return leftScalar.value < rightScalar.value ? .less : .greater
            }
        }
    }

    /// `unique`：排序後去掉相鄰的相等項。排序要穩定（jq 的是），所以拿原本的
    /// 位置當決勝負。
    static func unique(_ values: [JSONValue]) throws -> [JSONValue] {
        let ordered = values.indices.sorted { lhs, rhs in
            let verdict = compare(values[lhs], values[rhs])
            return verdict == .equal ? lhs < rhs : verdict == .less
        }
        var result: [JSONValue] = []
        for position in ordered {
            if let last = result.last, compare(last, values[position]) == .equal {
                continue
            }
            result.append(values[position])
        }
        return result
    }

    /// jq 的 `length`。boolean 沒有 length（runtime error），數字回**絕對值**，
    /// 字串回碼位數。
    static func length(_ value: JSONValue) throws -> Double {
        switch value {
        case .null: return 0
        case .bool: throw RectTreeError.runtime
        case let .number(literal): return abs(Double(literal) ?? 0)
        case let .string(text): return Double(text.unicodeScalars.count)
        case let .array(items): return Double(items.count)
        case let .object(members): return Double(members.count)
        }
    }

    /// `$rs[]`：陣列走元素，物件走**值**，其餘報錯。
    static func iterate(_ value: JSONValue) throws -> [JSONValue] {
        switch value {
        case let .array(items): return items
        case let .object(members): return members.map(\.value)
        default: throw RectTreeError.runtime
        }
    }

    /// `.[<n>]`：陣列取元素（越界回 null），null 回 null，其餘報錯。
    static func element(_ value: JSONValue, _ index: Int) throws -> JSONValue {
        switch value {
        case let .array(items): return index < items.count ? items[index] : .null
        case .null: return .null
        default: throw RectTreeError.runtime
        }
    }

    /// `.[<key>]`：物件取值（沒有回 null），null 回 null，其餘報錯。
    static func member(_ value: JSONValue, _ key: String) throws -> JSONValue {
        switch value {
        case .object: return value[key] ?? .null
        case .null: return .null
        default: throw RectTreeError.runtime
        }
    }

    /// `a // b`：只有 null 與 false 讓位。
    static func alternative(_ value: JSONValue, _ fallback: JSONValue) -> JSONValue {
        switch value {
        case .null, .bool(false): fallback
        default: value
        }
    }

    /// 有這個鍵就就地換值，沒有就接在最後面——jq 的 `.k = v` 就是這個語意，而
    /// 鍵序一動寫回 layout.json 就是一個沒有意義的全檔 diff。
    static func assign(_ value: JSONValue, key: String, value newValue: JSONValue) -> JSONValue {
        guard case let .object(members) = value else { return value }
        guard members.contains(where: { $0.key == key }) else {
            return .object(members + [JSONMember(key: key, value: newValue)])
        }
        return .object(members.map {
            $0.key == key ? JSONMember(key: key, value: newValue) : $0
        })
    }

    // MARK: - jq 的算術

    //
    // 只有 `+` 吃得下容器（字串串接、陣列串接、物件合併），而 `-` 只吃數字與陣列、
    // `*` 與 `/` 只吃數字。這不是簡化：座標是字串時 `+` 串得起來但 `-` 會炸，
    // 所以 span 永遠只可能回數字或陣列，`/` 也就永遠看不到字串。

    static func number(_ value: JSONValue) throws -> Double {
        guard case let .number(literal) = value, let parsed = Double(literal) else {
            throw RectTreeError.runtime
        }
        return parsed
    }

    /// 中途算出來的數字**不能**走 JQNumber.text——它是印法，會把 inf 收斂成
    /// DBL_MAX，而 jq 只在印的時候收斂、算的時候留著 inf。實測 `w: 1e999` 的矩形
    /// 讓 span 變成 inf，`inf / inf` 是 NaN 而 jq 印 `null`；先收斂成 DBL_MAX 就
    /// 變成 `1`，一個看起來完全正常的錯答案。`String(Double)` 是最短往返表示，
    /// `inf`／`-inf`／`nan` 都原封不動回得來。
    static func literal(_ value: Double) -> JSONValue {
        .number(String(value))
    }

    static func add(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        switch (lhs, rhs) {
        case (.null, _): return rhs
        case (_, .null): return lhs
        case (.number, .number):
            return try literal(number(lhs) + number(rhs))
        case let (.string(left), .string(right)): return .string(left + right)
        case let (.array(left), .array(right)): return .array(left + right)
        case let (.object(left), .object(right)):
            var merged = left.map { member in
                JSONMember(key: member.key,
                           value: right.first { $0.key == member.key }?.value ?? member.value)
            }
            merged += right.filter { member in !left.contains { $0.key == member.key } }
            return .object(merged)
        default: throw RectTreeError.runtime
        }
    }

    static func subtract(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        if case let .array(left) = lhs, case let .array(right) = rhs {
            return .array(left.filter { item in !right.contains { compare($0, item) == .equal } })
        }
        return try literal(number(lhs) - number(rhs))
    }

    static func multiply(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        try literal(number(lhs) * number(rhs))
    }

    /// 除以零在 jq 是 runtime error，不是 inf——所以兩個 span 都是 0 的時候整份
    /// 設定會靜默通不過（rc=5、零輸出），不會產生一棵帶 inf 的樹。
    static func divide(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        let divisor = try number(rhs)
        let dividend = try number(lhs)
        if divisor == 0 {
            throw RectTreeError.runtime
        }
        return literal(dividend / divisor)
    }
}
