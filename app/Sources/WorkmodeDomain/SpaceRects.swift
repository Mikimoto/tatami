/// `space_rects` 的結果。
///
/// 兩半分開回而不是併成一個物件：bash 那側 `.rects` 走 stdout、`.dropped` 走
/// **stderr** 且是給人看的一句話，把它們併在一起就得讓這一層決定那句話長什麼樣，
/// 而訊息是印法不是規則。
public struct SpaceRectsResult: Equatable, Sendable {
    /// 給 rects_to_tree 吃的矩形陣列。永遠是 `.array`，空的時候是 `[]` 不是 null。
    public let rects: JSONValue
    /// 因為完全重疊而被丟掉的那些（已經整理成與 rects 同形的物件）。
    /// 呼叫端要的是它們的 `app`。
    public let dropped: [JSONValue]

    public init(rects: JSONValue, dropped: [JSONValue]) {
        self.rects = rects
        self.dropped = dropped
    }
}

public enum SpaceRectsError: Error, Equatable, Sendable {
    /// jq 的 runtime error：`.[]` 碰到純量、字串索引碰到非物件、`floor` 碰到非數字。
    ///
    /// bash 那側**不會**因此回非零：函式的最後一個命令是第二個 jq，而第一個 jq 炸掉
    /// 之後它讀到的是空輸入，於是零次過濾、exit 0、零位元組（實測四種壞輸入
    /// ——壞 JSON、根不是陣列、frame 是字串、idmap 是陣列——rc 全部是 0）。
    /// 所以呼叫端收到這個要印零位元組並 exit 0，不是 exit 5。
    case runtime
}

/// 把 yabai 的視窗清單整理成 rects_to_tree 吃的矩形。
/// bash 對應：`space_rects <wins> <idmap>`（workmode.sh:458-475）。
public enum SpaceRects {
    /// - Parameters:
    ///   - windows: `yabai -m query --windows --space N` 的輸出。
    ///   - idmap: `{"<window id>": "<label>"}`，既有規則已經認出來的那些。
    ///   - idText: jq 的 `tostring`。由呼叫端供給而不是這一層自己算：容器的 compact
    ///     形式要靠 Wire 的 writer（連字串跳脫的 `` quirk 都得一致），而 Domain
    ///     不能依賴 Wire。純量的部分呼叫端照樣得供，否則兩條路會漂移。
    ///
    /// 濾掉浮動與最小化的：它們不在 bsp 樹裡，而浮動視窗還會橫跨切割線。
    /// 完全重疊的一組（yabai stack）只留一個：重疊的矩形之間找不到切割線。
    /// 沒有 label 的留空字串，不是丟掉：它們要撐著切割結構與比例。
    public static func compute(windows: JSONValue, idmap: JSONValue,
                               idText: (JSONValue) -> String) throws -> SpaceRectsResult
    {
        var built: [JSONValue] = []
        var keys: [[Double]] = []

        for element in try iterate(windows) {
            guard try isManaged(element) else { continue }

            let identifier = try member(element, "id")
            let frame = try member(element, "frame")
            let originX = try floored(member(frame, "x"))
            let originY = try floored(member(frame, "y"))
            let width = try floored(member(frame, "w"))
            let height = try floored(member(frame, "h"))

            // 鍵序照 bash 的物件建構式，一個都不能換位置：rects_to_tree 讀它，
            // 而差分比的是位元組。
            try built.append(.object([
                JSONMember(key: "id", value: identifier),
                JSONMember(key: "app", value: member(element, "app")),
                JSONMember(key: "title",
                           value: alternative(member(element, "title"), .string(""))),
                JSONMember(key: "label", value: label(idmap, idText(identifier))),
                JSONMember(key: "x", value: .number(originX.text)),
                JSONMember(key: "y", value: .number(originY.text)),
                JSONMember(key: "w", value: .number(width.text)),
                JSONMember(key: "h", value: .number(height.text)),
            ]))
            keys.append([originX.value, originY.value, width.value, height.value])
        }

        // `group_by([.x,.y,.w,.h])`：先照鍵排序再把相等的切成一段。jq 的排序是穩定的，
        // 而 Swift 的 `sorted(by:)` 不保證，所以拿原本的位置當決勝負——同一組之內留下
        // 來的必須是**來源順序**的第一個（實測）。
        let ordered = built.indices.sorted { lhs, rhs in
            let verdict = compare(keys[lhs], keys[rhs])
            return verdict == 0 ? lhs < rhs : verdict < 0
        }

        var heads: [Int] = []
        var dropped: [JSONValue] = []
        for position in ordered {
            if let previous = heads.last, compare(keys[previous], keys[position]) == 0 {
                dropped.append(built[position])
            } else {
                heads.append(position)
            }
        }

        // `sort_by(.x, .y)`：只看 x 與 y，所以 x/y 相同而 w/h 不同的兩組維持 group_by
        // 排出來的先後。一樣要穩定，一樣拿位置決勝負。
        let sorted = heads.enumerated()
            .sorted { lhs, rhs in
                let verdict = compare(Array(keys[lhs.element].prefix(2)),
                                      Array(keys[rhs.element].prefix(2)))
                return verdict == 0 ? lhs.offset < rhs.offset : verdict < 0
            }
            .map { built[$0.element] }

        return SpaceRectsResult(rects: .array(sorted), dropped: dropped)
    }

    // MARK: - jq 的 floor 與它的印法

    /// `floor`。回值與文字一起給：值拿去排序與分組，文字進輸出。
    ///
    /// 算出來的數字**不再是字面值**——`layout.json` 那條「逐字保留」在這裡不適用，
    /// jq 改用它自己的 dtoa（實測 `2.50 | floor` 是 `2`、`1e3 | floor` 是 `1000`）。
    static func floored(_ literal: String) -> (value: Double, text: String)? {
        guard let raw = Double(literal) else { return nil }
        var value = raw.rounded(.down)
        // 溢位的字面值（`1e999`）Swift 解成 inf，而 jq 收斂到 DBL_MAX 再印
        // （實測 `1e999 | floor` → `1.7976931348623157e+308`）。
        if value.isInfinite {
            value = value < 0 ? -Double.greatestFiniteMagnitude : .greatestFiniteMagnitude
        }
        return (value, JQNumber.text(value))
    }

    static func flooredText(_ literal: String) -> String? {
        floored(literal)?.text
    }

    // MARK: - jq 的零件

    /// `ManagedWindow.matches` 的 throwing 外衣：這一支的呼叫端用 `throws` 表示
    /// jq 的串流中止，而 predicate 那邊用 nil。只有錯誤的形狀不同，判斷是同一份。
    private static func isManaged(_ element: JSONValue) throws -> Bool {
        guard let managed = ManagedWindow.matches(element) else { throw SpaceRectsError.runtime }
        return managed
    }

    /// `$m[.id | tostring] // ""`。`$m` 是 null 時 `null[k]` 是 null（不是錯），
    /// 於是收斂成空字串；是陣列或純量就報錯（`Cannot index array with string`）。
    private static func label(_ idmap: JSONValue, _ key: String) throws -> JSONValue {
        switch idmap {
        case .null: return .string("")
        case .object: return alternative(idmap[key] ?? .null, .string(""))
        default: throw SpaceRectsError.runtime
        }
    }

    private static func floored(_ value: JSONValue) throws -> (value: Double, text: String) {
        guard case let .number(literal) = value, let result = floored(literal) else {
            throw SpaceRectsError.runtime
        }
        return result
    }

    /// `X // fallback`：假值（null 與 false）才退讓，`0`、`""`、`[]`、`{}` 都是真值。
    private static func alternative(_ value: JSONValue, _ fallback: JSONValue) -> JSONValue {
        switch value {
        case .null: fallback
        case let .bool(flag): flag ? value : fallback
        default: value
        }
    }

    private static func iterate(_ value: JSONValue) throws -> [JSONValue] {
        switch value {
        case let .array(items): return items
        case let .object(members): return members.map(\.value)
        default: throw SpaceRectsError.runtime
        }
    }

    private static func member(_ value: JSONValue, _ key: String) throws -> JSONValue {
        switch value {
        case .null: return .null
        case .object: return value[key] ?? .null
        default: throw SpaceRectsError.runtime
        }
    }

    /// 兩個等長的數字鍵陣列比大小。floor 之後全是數字，所以不需要 jq 的跨型別全序。
    private static func compare(_ lhs: [Double], _ rhs: [Double]) -> Int {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? -1 : 1
        }
        return 0
    }
}
