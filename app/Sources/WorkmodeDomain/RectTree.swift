/// 從畫面上的矩形反推 bsp 切割樹，以及剪枝之後決定哪些 ratio 留得下來。
/// bash 對應：`rects_to_tree`（workmode.sh:361-404）與 `trim_ratios`（:416-424）。
public enum RectTreeError: Error, Equatable, Sendable {
    /// jq 的 runtime error：型別對不上（不能疊代、不能索引、不能相減）或除以零。
    /// bash 那側 rc=5、stdout 零位元組——jq 是算完整份才印，所以沒有半截輸出。
    case runtime
    /// bash 那側會無限遞迴。見 `RectTree.reconstruct` 裡那道守衛的說明。
    case nonTerminating
}

public enum RectTree {
    // MARK: - rects_to_tree

    /// 吃 `[{label,x,y,w,h}, …]`，吐樹；切不開回 null。
    ///
    /// 切線候選是每個矩形的右緣／下緣，`unique` 排序過所以 `first` 拿到的是**最左**
    /// 那條。合格條件三個都要成立：沒有矩形嚴格跨越、至少一個完全在線之下、至少
    /// 一個完全在線之上。不需要容錯值——兄弟之間的 window gap 讓左組的右緣嚴格
    /// 小於右組的左緣。
    public static func fromRects(_ value: JSONValue) throws -> JSONValue {
        try reconstruct(value)
    }

    private static func reconstruct(_ value: JSONValue) throws -> JSONValue {
        let count = try length(value)
        if count == 0 {
            return .null
        }
        if count == 1 {
            return try .object([JSONMember(key: "window",
                                           value: member(element(value, 0), "label"))])
        }
        let rects = try iterate(value)

        // 先垂直再水平：田字型兩個方向都切得開，固定選垂直（兩種樹套用出來的
        // 畫面相同）。
        var axis = "vertical"
        var key = "x", size = "w"
        var line = try cut(rects, key, size)
        if line == .null {
            axis = "horizontal"
            key = "y"; size = "h"
            line = try cut(rects, key, size)
            if line == .null {
                return .null
            }
        }

        let low = try rects.filter { try compare(add(member($0, key),
                                                     member($0, size)), line) != .greater }
        let high = try rects.filter { try compare(member($0, key), line) != .less }

        // 兩個 span 在遞迴**之前**算，與 jq 的 `as` 綁定順序一致：型別對不上時
        // 先炸的是這裡，不是子樹。
        let lowSpan = try span(low, key, size)
        let highSpan = try span(high, key, size)

        // 寬度 <= 0 的矩形同時滿足 `x >= c` 與 `x + w <= c`，於是落進切線的兩邊；
        // 子集合等於原集合時 bash 那側就永遠遞迴下去（實測掛住到 timeout，或是
        // jq `cannot allocate memory` 的 SIGABRT）。寬度全部 > 0 時兩組必定互斥
        // 且都非空，元素數嚴格遞減，這道守衛就永遠不會觸發。
        if low.count == rects.count {
            throw RectTreeError.nonTerminating
        }
        let lowTree = try reconstruct(.array(low))
        if high.count == rects.count {
            throw RectTreeError.nonTerminating
        }
        let highTree = try reconstruct(.array(high))

        if lowTree == .null || highTree == .null {
            return .null
        }

        let total = try add(lowSpan, highSpan)
        return try .object([
            JSONMember(key: "axis", value: .string(axis)),
            JSONMember(key: "children", value: .array([
                stamp(lowTree, divide(lowSpan, total)),
                stamp(highTree, divide(highSpan, total)),
            ])),
        ])
    }

    /// `if has("window") then .ratio = (($r * 100) | round / 100) else . end`。
    ///
    /// 內部節點不帶 ratio：schema 只讓葉帶，硬寫會套到錯的視窗上。
    ///
    /// `round` 是 C 的 `round()`——**逢五往遠離零的方向進**（實測 `2.5|round` 是 3、
    /// `-2.5|round` 是 -3，不是銀行家捨入），而且負零會保留符號（`-0.4|round` 印
    /// 的是 `-0`）。NaN 沒有數字字面值，jq 印的是字面的 `null`（實測 span 溢位成
    /// inf 時 `inf/inf` 就會走到這裡），所以換成 JSONValue.null。
    private static func stamp(_ node: JSONValue, _ ratio: JSONValue) throws -> JSONValue {
        guard case let .object(members) = node else { throw RectTreeError.runtime }
        guard members.contains(where: { $0.key == "window" }) else { return node }
        let scaled = try number(multiply(ratio, .number("100")))
        let value = scaled.rounded(.toNearestOrAwayFromZero) / 100
        let stamped = value.isNaN ? JSONValue.null : .number(JQNumber.text(value))
        return assign(node, key: "ratio", value: stamped)
    }

    /// 給編輯器用：把拖出來的比例收成與 `stamp` 同形的字面值。
    ///
    /// 與 `stamp` 共用 `round(r*100)/100` 是重點——`--save` 寫出來的 ratio 與
    /// 編輯器寫出來的必須長一樣，否則同一個值在兩條路徑下會產生一個無意義的
    /// 全檔 diff。這裡不夾範圍：夾是編輯器的政策（`DropZone` 那側做），
    /// 這一支只做換算。
    ///
    /// 非有限回 nil。`stamp` 那側把 NaN 寫成 JSON 的 `null`（jq 印不出 NaN），
    /// 但編輯器有更好的選擇：整個不改。
    public static func ratioLiteral(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        let scaled = (value * 100).rounded(.toNearestOrAwayFromZero) / 100
        return JQNumber.text(scaled)
    }

    private static func cut(_ rects: [JSONValue], _ key: String, _ size: String) throws -> JSONValue {
        var candidates: [JSONValue] = []
        for rect in rects {
            try candidates.append(add(member(rect, key),
                                      member(rect, size)))
        }
        for candidate in try unique(candidates) {
            var spanning = 0, below = 0, above = 0
            for rect in rects {
                let near = try member(rect, key)
                let far = try add(near, member(rect, size))
                if compare(near, candidate) == .less, compare(far, candidate) == .greater {
                    spanning += 1
                }
                if compare(far, candidate) != .greater {
                    below += 1
                }
                if compare(near, candidate) != .less {
                    above += 1
                }
            }
            if spanning == 0, below > 0, above > 0 {
                return candidate
            }
        }
        // `first` 對空陣列回 null，而候選本身也可能是 null（座標整個缺席時
        // `.x + .w` 就是 null）。呼叫端的 `$cx != null` 把兩者讀成同一件事。
        return .null
    }

    /// `(map(.[$k] + .[$s]) | max) - (map(.[$k]) | min)`。
    private static func span(_ rects: [JSONValue], _ key: String, _ size: String) throws -> JSONValue {
        var largest: JSONValue?
        var smallest: JSONValue?
        for rect in rects {
            let near = try member(rect, key)
            let far = try add(near, member(rect, size))
            if largest == nil || compare(far, largest!) == .greater {
                largest = far
            }
            if smallest == nil || compare(near, smallest!) == .less {
                smallest = near
            }
        }
        return try subtract(largest ?? .null, smallest ?? .null)
    }

    // MARK: - trim_ratios

    /// 只留佔比 > 0.53 的葉。
    ///
    /// 0.53 = 0.5 加上 0.03 的容忍。apply_ratio 設完會量一次，發現目標視窗沒有比
    /// sibling 寬就翻成 1-ratio，所以小邊的佔比寫進設定會排出比原本更大的視窗。
    public static func trim(_ value: JSONValue) throws -> JSONValue {
        // `type != "object"` 原樣回傳——陣列也算，所以陣列裡的葉不會被走訪。
        guard case let .object(members) = value else { return value }

        if members.contains(where: { $0.key == "window" }) {
            if exceedsThreshold(alternative(value["ratio"] ?? .null, .number("0"))) {
                return value
            }
            return .object(members.filter { $0.key != "ratio" })
        }

        // `.children = [...]` 是**賦值**不是重建物件：其他鍵與鍵序都留著，本來沒有
        // children 的節點會被補出一個，而第三個以後的 child 會被整個換掉的陣列吃掉。
        let children = value["children"] ?? .null
        let first = try trim(element(children, 0))
        let second = try trim(element(children, 1))
        return assign(value, key: "children", value: .array([first, second]))
    }

    /// `(.ratio // 0) > 0.53`。`//` 只接手 null 與 false，所以 `0` 與 `""` 都自己
    /// 去比；而 jq 的全序是 null < false < true < 數字 < 字串 < 陣列 < 物件，
    /// 於是任何字串、陣列、物件都「大於」0.53，`true` 則不是。
    private static func exceedsThreshold(_ value: JSONValue) -> Bool {
        compare(value, .number("0.53")) == .greater
    }
}

private extension Array {
    /// `filter` 的 throwing 版本，讓述詞裡的 `try` 不用另外包一層。
    func filter(_ isIncluded: (Element) throws -> Bool) rethrows -> [Element] {
        var kept: [Element] = []
        for item in self where try isIncluded(item) {
            kept.append(item)
        }
        return kept
    }
}
