// `validate_layout` 底下那組 jq 語意的模擬。每一支都對應 jq 的一個內建，而且每一支
// 的行為都是拿 jq 1.8 實跑回推的，不是照文件抄的——`length` 對數字保留字面值、
// `group_by` 排序過、跨型別比較有全序、`//` 只把 null 與 false 當假值。
//
// 與 LayoutValidator 分開只是型別長度。從 private 放寬成 internal 是拆檔的代價：
// Swift 的 private 是檔案範圍，跨檔的 extension 看不到它。

extension LayoutValidator {
    /// jq 的 `length`：物件與陣列是成員數，字串是**碼位**數（`😀a` 是 2 不是 3），
    /// 數字是絕對值——jq 1.8 保留字面值、只去掉負號（實測 `-2.50` 的 length 印成
    /// `2.50`），null 是 0。boolean 沒有 length，jq 在那裡 runtime error → nil。
    static func jqLength(_ value: JSONValue) -> JSONValue? {
        switch value {
        case let .object(members): .number("\(members.count)")
        case let .array(elements): .number("\(elements.count)")
        case let .string(text): .number("\(text.unicodeScalars.count)")
        case let .number(literal):
            .number(literal.hasPrefix("-") ? String(literal.dropFirst()) : literal)
        case .null: .number("0")
        case .bool: nil
        }
    }

    /// jq 的 `[0]`／`[1]`。呼叫端的 children 已經過 `// []`，所以 null 與 false 到不了
    /// 這裡，boolean 也早在 length 就中止了；剩下物件、字串、數字都是
    /// `Cannot index … with number` → nil。陣列取不到的位置回 null，讓呼叫端的
    /// `// empty` 去跳過它。
    static func jqIndex(_ value: JSONValue, _ slot: Int) -> JSONValue? {
        guard case let .array(elements) = value else { return nil }
        return slot < elements.count ? elements[slot] : .null
    }

    /// `$pv.windows // (($root.windows // []) + ($lv.windows // []))` 再 `map(.label)`。
    ///
    /// 與 `windows_for` 同一套語意：profile 自己有 windows 就**整塊取代**，否則是
    /// 最外層接上地點層。空陣列在 jq 是 truthy，所以 `"windows": []` 是取代而不是沿用。
    /// 回 nil 代表 jq 在這裡 runtime error、整個串流結束。
    static func effectiveLabels(profile: JSONValue,
                                location: JSONValue,
                                root: JSONValue) -> [JSONValue]?
    {
        let source: JSONValue
        switch alternative(profile[LayoutQuery.reservedKey], .null) {
        case .null:
            guard let merged = jqAdd(alternative(root[LayoutQuery.reservedKey], .array([])),
                                     alternative(location[LayoutQuery.reservedKey], .array([])))
            else { return nil }
            source = merged
        case let own:
            source = own
        }
        return jqMapLabel(source)
    }

    /// jq 的 `to_entries`。物件的 key 是字串；**陣列也合法**，key 是索引數字。
    /// 其他型別是 `... has no keys`，回 nil。
    static func jqToEntries(_ value: JSONValue)
        -> [(key: JSONValue, value: JSONValue)]?
    {
        switch value {
        case let .object(members):
            members.map { (key: .string($0.key), value: $0.value) }
        case let .array(elements):
            elements.enumerated().map { (key: .number("\($0.offset)"), value: $0.element) }
        default:
            nil
        }
    }

    /// jq 的 `+`：兩個陣列串接，兩個物件合併（右邊蓋左邊，鍵序照左邊的插入順序）。
    /// 其他組合回 nil——jq 對 array+object 當場報錯，而 string+string、number+number
    /// 雖然算得出來，結果也不是 map 走得動的東西，所以中止的結果相同。
    static func jqAdd(_ lhs: JSONValue, _ rhs: JSONValue) -> JSONValue? {
        switch (lhs, rhs) {
        case let (.array(left), .array(right)):
            return .array(left + right)
        case let (.object(left), .object(right)):
            var members = left
            for member in right {
                if let existing = members.firstIndex(where: { $0.key == member.key }) {
                    members[existing] = member
                } else {
                    members.append(member)
                }
            }
            return .object(members)
        default:
            return nil
        }
    }

    /// jq 的 `map(.label)`。`map` 對物件是走過它的**值**，對純量報錯；
    /// 元素只有物件與 null 取得了 `.label`（`null.label` 合法，回 null）。
    static func jqMapLabel(_ value: JSONValue) -> [JSONValue]? {
        let elements: [JSONValue]
        switch value {
        case let .array(items): elements = items
        case let .object(members): elements = members.map(\.value)
        default: return nil
        }
        var labels: [JSONValue] = []
        for element in elements {
            switch element {
            case .object: labels.append(element["label"] ?? .null)
            case .null: labels.append(.null)
            default: return nil
            }
        }
        return labels
    }

    /// `unique` 與 `group_by(.)` 都先排序，所以一次排序供兩者用。回傳相異值個數
    /// （`unique | length`）與出現兩次以上的相異值（`map(select(length > 1) | .[0])`，
    /// 已經是排序過的順序——那正是訊息裡重複清單的順序，不是來源順序）。
    static func jqGroups(_ values: [JSONValue]) -> (distinct: Int, repeated: [JSONValue]) {
        let sorted = values.sorted { jqCompare($0, $1) == .less }
        var distinct = 0
        var repeated: [JSONValue] = []
        var index = 0
        while index < sorted.count {
            var end = index + 1
            while end < sorted.count, jqCompare(sorted[index], sorted[end]) == .equal {
                end += 1
            }
            distinct += 1
            if end - index > 1 {
                repeated.append(sorted[index])
            }
            index = end
        }
        return (distinct, repeated)
    }

    /// jq 的 `join("、")`：null 變空字串，數字印**字面值**（jq 1.8 保留 `1.50`），
    /// 陣列與物件加不動（`string ("") and object ({}) cannot be added`）→ nil。
    static func jqJoin(_ values: [JSONValue]) -> String? {
        var parts: [String] = []
        for value in values {
            switch value {
            case .null: parts.append("")
            case let .bool(flag): parts.append(flag ? "true" : "false")
            case let .number(literal): parts.append(literal)
            case let .string(text): parts.append(text)
            case .array, .object: return nil
            }
        }
        return parts.joined(separator: "、")
    }

    enum JQOrder { case less, equal, greater }

    /// jq 的陣列比較：逐元素，全同就比長度。
    static func jqCompareArrays(_ lhs: [JSONValue], _ rhs: [JSONValue]) -> JQOrder {
        for (lhsItem, rhsItem) in zip(lhs, rhs) {
            let order = jqCompare(lhsItem, rhsItem)
            if order != .equal {
                return order
            }
        }
        return lhs.count == rhs.count ? .equal
            : (lhs.count < rhs.count ? .less : .greater)
    }

    /// jq 的物件比較：先比鍵（排序過的整份），一樣才依那個順序比值。
    static func jqCompareObjects(_ lhs: [JSONMember], _ rhs: [JSONMember]) -> JQOrder {
        let sortedLeft = lhs.sorted { compareScalars($0.key, $1.key) == .less }
        let sortedRight = rhs.sorted { compareScalars($0.key, $1.key) == .less }
        for (lhsMember, rhsMember) in zip(sortedLeft, sortedRight) {
            let order = compareScalars(lhsMember.key, rhsMember.key)
            if order != .equal {
                return order
            }
        }
        if sortedLeft.count != sortedRight.count {
            return sortedLeft.count < sortedRight.count ? .less : .greater
        }
        for (lhsMember, rhsMember) in zip(sortedLeft, sortedRight) {
            let order = jqCompare(lhsMember.value, rhsMember.value)
            if order != .equal {
                return order
            }
        }
        return .equal
    }

    /// jq 的全序：null < false < true < 數字 < 字串 < 陣列 < 物件。
    static func jqCompare(_ lhs: JSONValue, _ rhs: JSONValue) -> JQOrder {
        let (leftRank, rightRank) = (jqRank(lhs), jqRank(rhs))
        if leftRank != rightRank {
            return leftRank < rightRank ? .less : .greater
        }
        switch (lhs, rhs) {
        case let (.number(left), .number(right)):
            // 比的是數值不是字面值——jq 的 1.50 與 1.5 是同一個值。
            let (leftValue, rightValue) = (Double(left) ?? 0, Double(right) ?? 0)
            return leftValue == rightValue ? .equal : (leftValue < rightValue ? .less : .greater)
        case let (.string(left), .string(right)):
            return compareScalars(left, right)
        case let (.array(left), .array(right)):
            return jqCompareArrays(left, right)
        case let (.object(left), .object(right)):
            return jqCompareObjects(left, right)
        default:
            return .equal // 同 rank 的 null／false／true 只有相等一種可能。
        }
    }

    static func jqRank(_ value: JSONValue) -> Int {
        switch value {
        case .null: 0
        case let .bool(flag): flag ? 2 : 1
        case .number: 3
        case .string: 4
        case .array: 5
        case .object: 6
        }
    }

    /// 逐個 Unicode 碼位比大小。不能用 String 的 `<`——它做的是正規化比較，
    /// 而 jq 排的是碼位序（實測 `["b","A"] | sort` 得 `["A","b"]`，大寫在前）。
    static func compareScalars(_ lhs: String, _ rhs: String) -> JQOrder {
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

    /// jq 的 `a // b`：a 不存在、是 null、或是 false 時取 b。
    static func alternative(_ value: JSONValue?, _ fallback: JSONValue) -> JSONValue {
        guard let value else { return fallback }
        switch value {
        case .null, .bool(false): return fallback
        default: return value
        }
    }

    /// jq 的 `length == 0`。物件與陣列看成員數，字串看字元數，數字看數值是否為零
    /// （jq 的 length 對數字回絕對值），null 是 0。boolean **沒有** length，
    /// jq 在那裡 runtime error，所以回 nil。
    static func jqLengthIsZero(_ value: JSONValue) -> Bool? {
        switch value {
        case let .object(members): members.isEmpty
        case let .array(elements): elements.isEmpty
        case let .string(text): text.isEmpty
        case let .number(literal): Double(literal) == 0
        case .null: true
        case .bool: nil
        }
    }

    /// jq 的 `test("\\s")` 認的是 Unicode 空白，不只半形空格——實測它對全形空白
    /// U+3000 與 NBSP U+00A0 都 match。標準庫的 isWhitespace 在那 9 個碼位上與 jq
    /// 逐一相符，所以不需要 Foundation 的 CharacterSet，Domain 得以維持零 import。
    ///
    /// `public`（原本是隱含的 internal）：編輯器的 `LayoutName` 共用同一支。抄第二份
    /// 的那一份不會有東西驗它，而它認得的空白包含全形空白 U+3000 與 NBSP——
    /// `contains(" ")` 放行的名字 validator 會擋，而畫面上那個名字看起來完全正常。
    public static func containsWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isWhitespace }
    }

    /// 編輯器掃孤兒窗格時比 label 用的**同一支**比較。
    ///
    /// **不可以在 `WorkmodeEditorModel` 那側自己寫一份 `==`。** 編輯器認的相等與
    /// validator 認的相等一旦漂移，症狀是「掃過了但 ⌘S 還是被擋」或「掃掉了不該掃
    /// 的」，而那兩個 label 在畫面上長得一模一樣。`treeChecks`（`LayoutValidator.swift:281`）
    /// 用的就是底下這支 `jqCompare`。
    ///
    /// 開成 public 的先例是 `containsWhitespace`（上面那支，為 `LayoutName` 開的）。
    public static func labelEquals(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        jqCompare(lhs, rhs) == .equal
    }
}
