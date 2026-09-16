import WorkmodeDomain

/// 給 UI 看的樹。`LayoutDocument` 的投影，不是它的儲存形式——真正的資料是
/// `JSONValue`，這個型別每次都是從那裡算出來的。
///
/// **`ratio` 掛在葉節點上，不在分割節點上。** 節點只有兩種形狀
/// （`LayoutTree.swift:4-5`）：`{"window": label, "ratio": 選填}` 與
/// `{"axis": …, "children": [節點, 節點]}`。分割線的位置是**第一個 child 的
/// ratio**——`RectTree.swift:73-80` 產出時就是把 `lowSpan/total` 蓋在第一個 child 上，
/// 而 `stamp`（`:95`）只對含 `window` 的節點蓋。讀的那一側同樣只認葉：
/// `LayoutTree.ratios`（`:78-83`）在 `window` 分支才看 ratio，內部節點連看都不看。
///
/// `ratio` 是 `String?` 而不是 `Double?`：它是 jq 印出來的字面值，`0.750` 與
/// `0.75` 是不同的位元組（`Double` 來回會把前者變成後者），而 phase 2 改完要寫回
/// 同一份檔。`nil` 只代表「這個鍵不存在」，不代表「值看不懂」——看不懂的值照原樣
/// 帶著，UI 解不出 `Double` 就用 0.5 畫，但字面值仍在畫面上給使用者看。
/// `indirect`：`split` 的 payload 含 `PaneNode` 自己，沒有它編不過
/// （`recursive enum 'PaneNode' is not marked 'indirect'`）。
public indirect enum PaneNode: Equatable, Sendable {
    case window(label: String, ratio: String?)
    case split(axis: String, first: PaneNode, second: PaneNode)
    /// 畸形或缺漏。畫成虛線的「未指定」，不是錯誤——編輯器要能開一份還沒通過
    /// `validate_layout` 的檔，否則使用者沒辦法用它把檔修好。
    case empty
}

public extension PaneNode {
    /// 從 layout.json 的一個節點讀出來。
    ///
    /// `window` 優先於 `axis`，與 `LayoutValidator.treeChecks` 同一個順序：
    /// 兩者都有時 axis 與 children 完全不看。
    ///
    /// 三個欄位都是「鍵存在就收下，值看不懂也保留原樣」而不是回 `.empty`，理由同一個：
    /// 編輯器要能開一份還沒通過 `validate_layout` 的檔，並讓使用者看得到錯在哪。
    /// 藏起來的節點沒有辦法被修好。
    ///
    /// 值不是字串時走 `JQPrint.interpolate`，是為了與 validator 講一樣的話——
    /// 它的訊息（`LayoutValidator.swift:278`）用的就是這一支，兩邊的顯示文字才會一致。
    init(_ value: JSONValue) {
        guard case let .object(members) = value else {
            self = .empty
            return
        }
        // 看 key 存不存在而不是看值的型別，與 `LayoutValidator.swift:272` 及
        // `LayoutTree.swift:29,52` 一致。實測過型別判定的後果：
        // `{"window":null,"axis":"vertical","children":[A,B]}` 會讓 validator 報
        // 「window「null」不在生效的 windows 清單裡」（當它是葉），而畫布畫出 A｜B 的
        // 分割（當它是分割）——兩個訊息互相矛盾，而畫面上零訊號。
        if let window = members.first(where: { $0.key == "window" })?.value {
            self = .window(label: JQPrint.interpolate(window),
                           ratio: Self.literal(of: "ratio", in: members))
            return
        }
        guard let axis = members.first(where: { $0.key == "axis" })?.value,
              case let .array(children)? = members.first(where: { $0.key == "children" })?.value,
              children.count == 2
        else {
            self = .empty
            return
        }
        // `axis` 非法（`diagonal`）與 `axis` 非字串（`null`）待遇要一樣：前者使用者
        // 看得到「diagonal」所以知道要改哪裡，後者若回 `.empty`，那兩個要修的 children
        // 就整個看不見了。
        // 分割節點上的 `ratio` **刻意不讀**：產品路徑整個忽略它（`LayoutTree.ratios`
        // 只在 `window` 分支看 ratio），所以照它畫出來的分割線是一條套用之後不會出現
        // 的線——比不畫更糟，使用者會拖它、存檔、然後發現畫面沒變。分割線要畫就讀
        // 第一個 child 的 ratio。
        self = .split(axis: JQPrint.interpolate(axis),
                      first: PaneNode(children[0]), second: PaneNode(children[1]))
    }

    /// 鍵存在就收下字面值，值看不懂也照原樣帶著。非數字的 ratio（誤打成字串的
    /// `"0.75"`、`null`、`true`）不能靜默變成「沒有 ratio」＝均分：`LayoutValidator`
    /// 完全不檢查 ratio，這裡是全系統唯一看得到它的地方，不出聲就沒人會出聲。
    private static func literal(of key: String, in members: [JSONMember]) -> String? {
        guard let value = members.first(where: { $0.key == key })?.value else { return nil }
        return JQPrint.interpolate(value)
    }
}
