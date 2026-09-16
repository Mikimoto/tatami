/// 樹的走訪。bash 對應：`workmode.sh:261-328` 的五支純函式
/// （`tree_root`／`tree_seq`／`tree_ratios`／`prune_tree`／`referenced_labels`）。
///
/// 節點只有兩種：`{"window": label, "ratio": 選填}` 或
/// `{"axis": "vertical|horizontal", "children": [節點, 節點]}`。
/// vertical 是左右分，horizontal 是上下分，與 yabai 的 split_type 同義。
///
/// 走訪吃的是 JSONValue 而不是一個解析好的 Node 型別，理由與 LayoutValidator 相同：
/// 對照組是 jq，而 jq 對「不合節點形狀」的輸入有它自己的一套行為（見下），
/// 先轉成強型別就等於在移植之前先改掉那些行為。
///
/// 下面每一條都是拿 jq 1.8.2 對 `scripts/workmode.sh` 實跑出來的，不是照語意推的：
///
/// - `-r` 對容器印的是 `jq .` 的縮排格式，`tostring` 印的才是 compact——兩者不同
/// - `@tsv` 只吃純量，碰到陣列或物件是 runtime error（"is not valid in a csv row"）
/// - jq 的真值只把 `false` 與 `null` 當假，所以 `ratio: 0` **要**印出來
/// - 第三個 child 到處都被無聲忽略：jq 只碰 `children[0]` 與 `children[1]`
/// - 葉是原樣通過剪枝的（`.`），內部節點是重建的（`{axis, children}`）——
///   後者會正規化鍵序並丟掉多餘的鍵
/// - `unique` 用 jq 的跨型別全序，字串比碼位、數字比數值（5 與 5.0 併成一個）
public enum LayoutTree {
    // MARK: - tree_root（workmode.sh:269-271）

    /// 一個節點的「代表視窗」：它底下第一個葉。分割指令都以代表視窗為對象，
    /// 因為 bsp 只能分割葉節點自己的格子。
    public static func representative(_ node: JSONValue) throws -> JSONValue {
        switch node {
        case .object:
            if let window = node["window"] {
                return window
            }
            return try representative(child(node, 0))
        case .null:
            throw LayoutTreeError.nonTerminating
        default:
            throw LayoutTreeError.runtime
        }
    }

    // MARK: - tree_seq（workmode.sh:277-288）

    /// 前序走訪產生分割指令。
    ///
    /// 順序必須是前序（先做自己這一層，再遞迴進子樹）。後序會錯：田字型用後序
    /// 會先把 A 上下分掉，之後「分割 A 往東」只切開上半那格，做出 (A|B)/D。
    ///
    /// 收 callback 而不是回陣列：bash 那側 jq 是邊算邊印的，runtime error 之前
    /// 印出去的行留在 stdout 上（實測過）。回陣列的話失敗時輸出會從一行變成零行。
    public static func splits(_ node: JSONValue, emit: (Split) throws -> Void) throws {
        switch node {
        case .object:
            if node["window"] != nil {
                return
            }
            // 求值順序照抄 jq 的 `[(.children[0]|rep), .axis, (.children[1]|rep)]`：
            // 左邊先錯的輸入不該在右邊先報錯。
            let first = try child(node, 0)
            let target = try representative(first)
            let axis = node["axis"] ?? .null
            let second = try child(node, 1)
            let place = try representative(second)
            try emit(Split(target: target, axis: axis, place: place))
            try splits(first, emit: emit)
            try splits(second, emit: emit)
        case .null:
            throw LayoutTreeError.nonTerminating
        default:
            throw LayoutTreeError.runtime
        }
    }

    // MARK: - tree_ratios（workmode.sh:291-299）

    /// 有 ratio 的葉。streaming 的理由同 `splits`。
    public static func ratios(_ node: JSONValue, emit: (LeafRatio) throws -> Void) throws {
        switch node {
        case .object:
            if let window = node["window"] {
                // jq 的 `if .ratio then`：只有 false 與 null 走 else，`0` 是真。
                if let ratio = node["ratio"], isTruthy(ratio) {
                    try emit(LeafRatio(label: window, ratio: ratio))
                }
                return
            }
            try ratios(child(node, 0), emit: emit)
            try ratios(child(node, 1), emit: emit)
        case .null:
            throw LayoutTreeError.nonTerminating
        default:
            throw LayoutTreeError.runtime
        }
    }

    // MARK: - prune_tree（workmode.sh:303-317）

    /// 把解不到視窗的葉剪掉。只剩一邊的內部節點會塌陷成那一邊——這正是 bsp 的
    /// 行為：少一個視窗，它的兄弟就佔滿那塊區域。全空時回 nil（bash 印字面的 null）。
    ///
    /// `live` 收整個 JSONValue 而不是 `[String]`：bash 是 `--argjson live`，
    /// 它可以是陣列也可以是物件（`$live[]` 取值），是別的東西就 runtime error。
    public static func prune(_ node: JSONValue, live: JSONValue) throws -> JSONValue? {
        switch node {
        case .object:
            if let window = node["window"] {
                // 留下的是**整個葉物件**，不是重建的——多餘的鍵與來源鍵序都要保住。
                return try isLive(window, in: live) ? node : nil
            }
            let left = try prune(child(node, 0), live: live)
            let right = try prune(child(node, 1), live: live)
            guard let left, let right else { return left ?? right }
            // bash 是 `{axis: .axis, children: [$l, $r]}`：鍵序被正規化成
            // axis→children，內部節點上多餘的鍵會掉，axis 不存在則寫成 null。
            return .object([JSONMember(key: "axis", value: node["axis"] ?? .null),
                            JSONMember(key: "children", value: .array([left, right]))])
        case .null:
            throw LayoutTreeError.nonTerminating
        default:
            throw LayoutTreeError.runtime
        }
    }

    // MARK: - referenced_labels（workmode.sh:324-328）

    /// 一組 trees（角色 → 樹）引用到的所有 label，去重且排序。
    ///
    /// 用途是把「要解析哪些視窗」從整份 windows 收斂到這次真的用得到的。
    /// 生效清單是總表，可以放只有某些版面用得到的項目；
    /// 沒有這道過濾，開發版面下每次都會為了總表裡的「會議」印一行「找不到」。
    ///
    /// 不 streaming：bash 是 `[ .[] | leaves ] | unique | .[]`，`unique` 要先把整個
    /// 陣列蒐集完才排序，所以中途出錯一行都不會印（實測 stdout 是空的）。
    public static func referencedLabels(_ trees: JSONValue) throws -> [JSONValue] {
        let roots: [JSONValue]
        switch trees {
        case let .array(items): roots = items
        case let .object(members): roots = members.map(\.value)
        // jq 的 `.[]` 對純量是 "Cannot iterate over number (5)"。
        default: throw LayoutTreeError.runtime
        }
        var leaves: [JSONValue] = []
        for root in roots {
            try collectLeaves(root, into: &leaves)
        }
        return unique(leaves)
    }

    private static func collectLeaves(_ node: JSONValue, into out: inout [JSONValue]) throws {
        switch node {
        case .object:
            if let window = node["window"] {
                out.append(window); return
            }
            try collectLeaves(child(node, 0), into: &out)
            try collectLeaves(child(node, 1), into: &out)
        case .null:
            throw LayoutTreeError.nonTerminating
        default:
            throw LayoutTreeError.runtime
        }
    }

    // MARK: - 共用零件

    /// `.children[n]`。children 不存在是 null，`null[0]` 在 jq 也是 null（不是錯），
    /// 越界同樣是 null；children 是別的型別才報錯（`"oops"[0]`）。
    private static func child(_ node: JSONValue, _ index: Int) throws -> JSONValue {
        switch node["children"] ?? .null {
        case .null: return .null
        case let .array(items): return index < items.count ? items[index] : .null
        default: throw LayoutTreeError.runtime
        }
    }

    private static func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case let .bool(flag): flag
        default: true
        }
    }

    /// `.window | IN($live[])`。比的是 JSON 值相等而不是文字，所以 5 與 5.0 相等。
    private static func isLive(_ label: JSONValue, in live: JSONValue) throws -> Bool {
        let candidates: [JSONValue]
        switch live {
        case let .array(items): candidates = items
        case let .object(members): candidates = members.map(\.value)
        // jq: "Cannot iterate over string (\"A\")"。
        default: throw LayoutTreeError.runtime
        }
        return candidates.contains { order($0, label) == .same }
    }

    /// jq 的 `unique`（= `group_by(.) | map(.[0])`）：排序後取每組第一個。
    ///
    /// 用原始位置當決勝是必要的——Swift 的 `sorted` 不保證穩定，而數值相等但字面值
    /// 不同時 jq 留的是**第一個**（實測 `[5.0,5] | unique` 回 `[5.0]`、
    /// `[5,5.0] | unique` 回 `[5]`）。
    private static func unique(_ values: [JSONValue]) -> [JSONValue] {
        let sorted = values.enumerated().sorted { lhs, rhs in
            switch order(lhs.element, rhs.element) {
            case .ascending: true
            case .descending: false
            case .same: lhs.offset < rhs.offset
            }
        }.map(\.element)

        var out: [JSONValue] = []
        for value in sorted {
            if let last = out.last, order(last, value) == .same {
                continue
            }
            out.append(value)
        }
        return out
    }

    private enum Ordering {
        case ascending, same, descending
    }

    /// jq 的跨型別全序：null < false < true < 數字 < 字串 < 陣列 < 物件（實測）。
    private static func rank(_ value: JSONValue) -> Int {
        switch value {
        case .null: 0
        case let .bool(flag): flag ? 2 : 1
        case .number: 3
        case .string: 4
        case .array: 5
        case .object: 6
        }
    }

    private static func order(_ lhs: JSONValue, _ rhs: JSONValue) -> Ordering {
        let (left, right) = (rank(lhs), rank(rhs))
        if left != right {
            return left < right ? .ascending : .descending
        }

        switch (lhs, rhs) {
        case let (.number(left), .number(right)):
            // 比數值不比字面值。解不出 Double 的字面值（超出範圍）退回碼位比較，
            // 那至少仍是個全序——JSONParser 收得下的整數字面值可以長到 Double 表示
            // 不了，而 jq 自己在那個範圍也已經不精確了。
            guard let leftValue = Double(left), let rightValue = Double(right) else {
                return compare(left, right)
            }
            if leftValue == rightValue {
                return .same
            }
            return leftValue < rightValue ? .ascending : .descending
        case let (.string(left), .string(right)):
            return compare(left, right)
        case let (.array(left), .array(right)):
            return compare(left, right)
        case let (.object(left), .object(right)):
            // jq 先比排序過的鍵陣列，鍵相同才比那個順序下的值。
            let leftKeys = left.map(\.key).sorted { compare($0, $1) == .ascending }
            let rightKeys = right.map(\.key).sorted { compare($0, $1) == .ascending }
            let byKeys = compare(leftKeys.map(JSONValue.string), rightKeys.map(JSONValue.string))
            if byKeys != .same {
                return byKeys
            }
            return compare(leftKeys.map { key in left.first { $0.key == key }?.value ?? .null },
                           rightKeys.map { key in right.first { $0.key == key }?.value ?? .null })
        default:
            // null 與 bool 沒有內容，rank 已經分完。
            return .same
        }
    }

    /// 字串比**碼位**，不是 Swift 的 `<`——後者走 Unicode 正規化，
    /// `e` + U+0301 會與預組合的 `é` 相等，jq 不會。UTF-8 的位元組序與碼位序一致，
    /// 所以這樣比與 jq 的結果相同。
    private static func compare(_ lhs: String, _ rhs: String) -> Ordering {
        let left = Array(lhs.unicodeScalars)
        let right = Array(rhs.unicodeScalars)
        for index in 0 ..< min(left.count, right.count) where left[index] != right[index] {
            return left[index].value < right[index].value ? .ascending : .descending
        }
        if left.count == right.count {
            return .same
        }
        return left.count < right.count ? .ascending : .descending
    }

    private static func compare(_ lhs: [JSONValue], _ rhs: [JSONValue]) -> Ordering {
        for (left, right) in zip(lhs, rhs) {
            let result = order(left, right)
            if result != .same {
                return result
            }
        }
        if lhs.count == rhs.count {
            return .same
        }
        return lhs.count < rhs.count ? .ascending : .descending
    }
}

/// 一筆分割指令。bash 那側是 `<target>\t<axis>\t<place>` 一行。
///
/// 三個欄位收 JSONValue 而不是 String：jq 不強制它們是字串（axis 缺席就是 null、
/// window 可以是數字），而 `@tsv` 對每種型別的印法不同，硬轉成 String 會把那個
/// 差別提前燒進 Domain。怎麼印是 CLI 的事。
public struct Split: Equatable, Sendable {
    public let target: JSONValue
    public let axis: JSONValue
    public let place: JSONValue

    public init(target: JSONValue, axis: JSONValue, place: JSONValue) {
        self.target = target
        self.axis = axis
        self.place = place
    }
}

/// 一片帶 ratio 的葉。bash 那側是 `<label>\t<ratio>` 一行。
public struct LeafRatio: Equatable, Sendable {
    public let label: JSONValue
    public let ratio: JSONValue

    public init(label: JSONValue, ratio: JSONValue) {
        self.label = label
        self.ratio = ratio
    }
}

public enum LayoutTreeError: Error, Equatable, Sendable {
    /// jq 的 runtime error：`has` 碰到非物件、`.[0]` 碰到非陣列、`.[]` 碰到純量。
    /// bash 那側的 exit code 是 5。
    case runtime
    /// bash 在這種節點上不會終止：`null | has("window")` 是 **false 而不是錯**，
    /// 而 `null.children[0]` 又是 null，於是遞迴永遠往下走。實測 `tree_seq` 掛住
    /// 直到 timeout、`prune_tree` 直接 SIGABRT。
    ///
    /// 無窮迴圈沒有可鏡射的輸出，所以這裡停下來回報，而不是假裝有個回傳值。
    /// 這種節點 `validate_layout` 本來就擋得掉（節點必須有 window 或 axis+children），
    /// 所以真正的管線走不到這條路。
    case nonTerminating
}
