import Testing
import WorkmodeDomain
import WorkmodeEditorModel

private func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
    .object(pairs.map { JSONMember(key: $0.0, value: $0.1) })
}

@Test func readsALeaf() {
    #expect(PaneNode(obj([("window", .string("Ghostty"))])) == .window(label: "Ghostty", ratio: nil))
}

/// ratio 掛在**葉**上（`LayoutTree.swift:4-5`），保留成字串而不是 Double：它是 jq
/// 印出來的字面值，而 phase 2 改完要寫回去。測資刻意挑 Double 來回**會變**的值
/// （`0.750`→`0.75`、`2.50`→`2.5`）：`0.75` 剛好是來回不變的，用它當測資這條就是
/// 恆真句，「改走 Double」的突變不會紅。
@Test func aLeafKeepsItsRatioLiteral() {
    #expect(PaneNode(obj([("window", .string("A")), ("ratio", .number("0.750"))]))
        == .window(label: "A", ratio: "0.750"))
    #expect(PaneNode(obj([("window", .string("A")), ("ratio", .number("2.50"))]))
        == .window(label: "A", ratio: "2.50"))
}

/// 分割線的位置是**第一個 child 的 ratio**：`RectTree.swift:73-80` 產出時把
/// `lowSpan/total` 蓋在第一個 child 上，`stamp`（`:95`）只對含 `window` 的節點蓋。
/// 兩個 child 給不同的值（而且都是 Double 來回會變的字面值），左右接錯或共用
/// 同一個值都會紅。
@Test func readsASplitWithTheRatioOnItsChildren() {
    let node = obj([
        ("axis", .string("vertical")),
        ("children", .array([obj([("window", .string("A")), ("ratio", .number("0.750"))]),
                             obj([("window", .string("B")), ("ratio", .number("0.250"))])])),
    ])
    #expect(PaneNode(node) == .split(axis: "vertical",
                                     first: .window(label: "A", ratio: "0.750"),
                                     second: .window(label: "B", ratio: "0.250")))
}

/// 分割節點自己身上的 ratio 產品路徑整個忽略它——`LayoutTree.ratios`（`:78-83`）
/// 只在 `window` 分支讀 ratio，內部節點連看都不看。所以這裡也不讀：照它畫出來的
/// 分割線是一條套用之後不會出現的線，使用者會拖它、存檔、然後發現畫面沒變。
@Test func aRatioOnTheSplitItselfIsIgnoredExactlyAsTheProductPathIgnoresIt() {
    let node = obj([
        ("axis", .string("vertical")),
        ("ratio", .number("0.9")),
        ("children", .array([obj([("window", .string("A"))]),
                             obj([("window", .string("B"))])])),
    ])
    #expect(PaneNode(node) == .split(axis: "vertical",
                                     first: .window(label: "A", ratio: nil),
                                     second: .window(label: "B", ratio: nil)))
}

/// 沒有 ratio 是合法的（均分）。
@Test func aSplitWithoutARatioIsFine() {
    let node = obj([
        ("axis", .string("horizontal")),
        ("children", .array([obj([("window", .string("A"))]),
                             obj([("window", .string("B"))])])),
    ])
    #expect(PaneNode(node) == .split(axis: "horizontal",
                                     first: .window(label: "A", ratio: nil), second: .window(label: "B", ratio: nil)))
}

/// 畸形節點畫成「未指定」而不是拒絕開檔。`validate_layout` 擋得掉這些，
/// 但編輯器要能開一份還沒通過驗證的檔——不然使用者沒有辦法用它把檔修好。
@Test func anythingElseBecomesEmpty() {
    #expect(PaneNode(.null) == .empty)
    #expect(PaneNode(.string("x")) == .empty)
    #expect(PaneNode(obj([])) == .empty)
    // children 不是恰好兩個
    #expect(PaneNode(obj([("axis", .string("vertical")),
                          ("children", .array([obj([("window", .string("A"))])]))])) == .empty)
}

/// 三個 children 也是 .empty。這條與上面「一個 child」那條分開講，是因為它們
/// 抓得到的突變不同：`count == 2` 放寬成 `>= 2` 時，一個 child 的測資走不到
/// `children[1]` 以外的路徑而 crash，三個 child 的測資才會露出「靜默取前兩個、
/// 畫出與檔案不符的樹」那個形狀——UI 上沒有任何訊號。
/// 三個 children 不是假想的：`LayoutValidator` 有一條專門在報它，而
/// `rects_to_tree` 會把三個截成兩個，所以它真的會出現在 layout.json 裡。
@Test func threeChildrenIsAlsoEmpty() {
    #expect(PaneNode(obj([("axis", .string("vertical")),
                          ("children", .array([obj([("window", .string("A"))]),
                                               obj([("window", .string("B"))]),
                                               obj([("window", .string("C"))])]))])) == .empty)
}

/// 葉節點看 `window` 這個 key 存不存在，不看值的型別——與 `LayoutValidator.swift:272`
/// 及 `LayoutTree.swift:29,52` 一致。看型別的話 `{"window":null,…}` 會被 validator
/// 當葉（報「window「null」不在清單裡」）而被畫布當分割，兩邊互相矛盾且畫面零訊號。
/// 顯示文字走 `JQPrint.interpolate`，與 validator 訊息裡的那份是同一支。
@Test func aNonStringWindowIsStillALeaf() {
    #expect(PaneNode(obj([("window", .null),
                          ("axis", .string("vertical")),
                          ("children", .array([obj([("window", .string("A"))]),
                                               obj([("window", .string("B"))])]))]))
        == .window(label: "null", ratio: nil))
    #expect(PaneNode(obj([("window", .array([.string("A")]))])) == .window(label: "[\"A\"]", ratio: nil))
}

/// 非字串的 axis 不能讓 children 消失。`{"axis":"diagonal",…}` 使用者看得到
/// 「diagonal」所以知道要改哪裡；`{"axis":null,…}` 若回 `.empty`，那兩個要修的
/// children 就整個看不見了——兩者待遇要一樣。
@Test func aNonStringAxisKeepsItsChildren() {
    #expect(PaneNode(obj([("axis", .null),
                          ("children", .array([obj([("window", .string("A"))]),
                                               obj([("window", .string("B"))])]))]))
        == .split(axis: "null",
                  first: .window(label: "A", ratio: nil),
                  second: .window(label: "B", ratio: nil)))
}

/// 非數字的 ratio 保留原文而不是變成 nil（＝均分）。`LayoutValidator` 完全不檢查
/// ratio，這裡是全系統唯一看得到它的地方；靜默均分等於沒有人會告訴使用者他打錯了。
@Test func aNonNumberRatioKeepsItsText() {
    func leaf(_ ratio: JSONValue) -> PaneNode {
        PaneNode(obj([("window", .string("A")), ("ratio", ratio)]))
    }
    // 誤打成字串
    #expect(leaf(.string("0.75")) == .window(label: "A", ratio: "0.75"))
    #expect(leaf(.null) == .window(label: "A", ratio: "null"))
}

/// window 優先於 axis，與 `LayoutValidator` 的順序一致（兩者都有時 axis 完全不看）。
@Test func windowWinsOverAxis() {
    let node = obj([
        ("window", .string("A")),
        ("axis", .string("vertical")),
        ("children", .array([obj([("window", .string("B"))]),
                             obj([("window", .string("C"))])])),
    ])
    #expect(PaneNode(node) == .window(label: "A", ratio: nil))
}
