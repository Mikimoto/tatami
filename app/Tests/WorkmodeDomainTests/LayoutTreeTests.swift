import Testing
@testable import WorkmodeDomain

/// 用 JSONValue 直接建樹，不經 parser——這一層是純規則，不該依賴解析。
/// ratio 收字面值字串而不是 Double：JSONValue.number 存的就是字面值，
/// 而 bash 那側的 `tostring` 實測逐字保留（`2.50` 不會變 `2.5`）。
private func leaf(_ label: String, ratio: String? = nil) -> JSONValue {
    var pairs: [(String, JSONValue)] = [("window", .string(label))]
    if let ratio {
        pairs.append(("ratio", .number(ratio)))
    }
    return obj(pairs)
}

private func live(_ labels: [String]) -> JSONValue {
    .array(labels.map { .string($0) })
}

/// {v, [A, {h, [B, C]}]} —— 左半 A，右邊 B 上 C 下
private let lTree = split("vertical", leaf("A"), split("horizontal", leaf("B"), leaf("C")))
/// {v, [{h,[A,D]}, {h,[B,C]}]} —— 田字
private let qTree = split("vertical",
                          split("horizontal", leaf("A"), leaf("D")),
                          split("horizontal", leaf("B"), leaf("C")))
private let oneLeaf = leaf("A", ratio: "0.75")

/// 收集器。走訪是 streaming 的（bash 那側 jq 邊算邊印，錯誤發生前印出來的行留在
/// stdout 上），所以 API 是 callback；要整份結果的測試自己收。
private func collectSplits(_ node: JSONValue) throws -> [Split] {
    var out: [Split] = []
    try LayoutTree.splits(node) { out.append($0) }
    return out
}

private func collectRatios(_ node: JSONValue) throws -> [LeafRatio] {
    var out: [LeafRatio] = []
    try LayoutTree.ratios(node) { out.append($0) }
    return out
}

private func tsvSplit(_ target: String, _ axis: String, _ place: String) -> Split {
    Split(target: .string(target), axis: .string(axis), place: .string(place))
}

// MARK: - tree_root（tests/test_workmode.sh:421-423）

/// 取根的代表視窗。
@Test func rootOfAnLShapedTreeIsItsFirstLeaf() throws {
    #expect(try LayoutTree.representative(lTree) == .string("A"))
}

/// 代表視窗是第一個**葉**，不是第一個 child——田字型的第一個 child 是內部節點，
/// 這條與上一條的差別就在這裡。
@Test func theRepresentativeIsTheFirstLeafNotTheFirstChild() throws {
    #expect(try LayoutTree.representative(qTree) == .string("A"))
}

/// 單一葉的代表是自己。
@Test func aSingleLeafRepresentsItself() throws {
    #expect(try LayoutTree.representative(oneLeaf) == .string("A"))
}

// MARK: - tree_seq（tests/test_workmode.sh:425-429）

/// L 型的前序序列。
@Test func preorderSequenceOfAnLShapedTree() throws {
    #expect(try collectSplits(lTree) == [
        tsvSplit("A", "vertical", "B"),
        tsvSplit("B", "horizontal", "C"),
    ])
}

/// 田字型的前序序列。這條是前序與後序的判別式：後序會先把 A 上下分掉，
/// 之後「分割 A 往東」只切開上半那格，做出 (A|B)/D（workmode.sh:273-276）。
/// 後序的輸出會是 A/h/D、B/h/C、A/v/B 三行，順序與這裡完全不同。
@Test func preorderSequenceOfAQuadTree() throws {
    #expect(try collectSplits(qTree) == [
        tsvSplit("A", "vertical", "B"),
        tsvSplit("A", "horizontal", "D"),
        tsvSplit("B", "horizontal", "C"),
    ])
}

/// 單一葉沒有分割指令。
@Test func aSingleLeafProducesNoSplits() throws {
    #expect(try collectSplits(oneLeaf).isEmpty)
}

// MARK: - tree_ratios（tests/test_workmode.sh:431-432）

/// 取出葉的 ratio。
@Test func ratiosPicksUpALeafRatio() throws {
    #expect(try collectRatios(oneLeaf) == [LeafRatio(label: .string("A"), ratio: .number("0.75"))])
}

/// 沒有 ratio 時回空。
@Test func ratiosAreEmptyWhenNoLeafHasOne() throws {
    #expect(try collectRatios(lTree).isEmpty)
}

// MARK: - prune_tree（tests/test_workmode.sh:434-441）

/// 全部都在時樹不變。
@Test func pruneKeepsTheWholeTreeWhenEveryLabelIsLive() throws {
    #expect(try LayoutTree.prune(lTree, live: live(["A", "B", "C"])) == lTree)
}

/// 缺 C 時右子樹塌陷成 B。只剩一邊的內部節點塌成那一邊，是 bsp 的語意而不是
/// 簡化——少一個視窗，它的兄弟就佔滿那塊區域（workmode.sh:302-303）。
@Test func pruneCollapsesTheRightSubtreeWhenCIsMissing() throws {
    #expect(try LayoutTree.prune(lTree, live: live(["A", "B"]))
        == split("vertical", leaf("A"), leaf("B")))
}

/// 缺 A 時整棵換成右子樹。
@Test func pruneReplacesTheTreeWithItsRightSubtreeWhenAIsMissing() throws {
    #expect(try LayoutTree.prune(lTree, live: live(["B", "C"]))
        == split("horizontal", leaf("B"), leaf("C")))
}

/// 只剩 A 時塌成單葉。
@Test func pruneCollapsesToASingleLeaf() throws {
    #expect(try LayoutTree.prune(lTree, live: live(["A"])) == leaf("A"))
}

/// 全缺時回 null（bash 印字面的 `null`，這裡是 nil）。
@Test func pruneReturnsNothingWhenEveryLabelIsMissing() throws {
    #expect(try LayoutTree.prune(lTree, live: live([])) == nil)
}

/// 單葉缺席回 null。
@Test func pruneReturnsNothingForAMissingSingleLeaf() throws {
    #expect(try LayoutTree.prune(oneLeaf, live: live([])) == nil)
}

// MARK: - referenced_labels（tests/test_workmode.sh:454-456）

/// 一組 trees（角色 → 樹），不是單一棵樹。
/// 刻意讓 second 重複引用 main 已經有的 C，驗證去重。
private let treesTwo = obj([
    ("main", split("vertical", leaf("A"), split("horizontal", leaf("B"), leaf("C")))),
    ("second", leaf("C", ratio: "0.75")),
])
private let treesOne = obj([("main", leaf("A"))])

/// 列出所有被引用到的 label。
@Test func referencedLabelsListsEveryLabelOnce() throws {
    #expect(try LayoutTree.referencedLabels(treesTwo)
        == [.string("A"), .string("B"), .string("C")])
}

/// 單葉只有一個。
@Test func referencedLabelsOfASingleLeaf() throws {
    #expect(try LayoutTree.referencedLabels(treesOne) == [.string("A")])
}

/// 沒有樹時回空。
@Test func referencedLabelsOfNoTreesAreEmpty() throws {
    #expect(try LayoutTree.referencedLabels(.object([])).isEmpty)
}

// MARK: - 反推 → 剪枝 的往返（tests/test_workmode.sh:569-573 的 prune 那一段）

//
// 那兩條斷言是 trim_ratios(prune_tree(rects_to_tree(...)))，而 rects_to_tree 與
// trim_ratios 還沒移植。這裡釘住中間那一段：實測 `rects_to_tree` 對兩組 rect 的
// 輸出就是下面兩棵樹（second 螢幕實測：Chat 1878 對上一個沒有 label 的 626）。

/// 剪掉沒 label 的鄰居後，Chat 這片葉連同它的 0.75 原樣留下——塌陷保留的是
/// 整個葉物件而不只是 window。
@Test func pruningTheUnlabelledNeighbourKeepsChatsRatio() throws {
    let measured = split("vertical", leaf("", ratio: "0.25"), leaf("Chat", ratio: "0.75"))
    #expect(try LayoutTree.prune(measured, live: live(["Chat"])) == leaf("Chat", ratio: "0.75"))
}

/// 較大的那個沒 label 時，留下的是小邊那片葉，帶的是它自己的 0.25
/// （後續 trim_ratios 才把它丟掉）。
@Test func pruningTheUnlabelledNeighbourKeepsTheSmallSidesRatio() throws {
    let measured = split("vertical", leaf("Chat", ratio: "0.25"), leaf("", ratio: "0.75"))
    #expect(try LayoutTree.prune(measured, live: live(["Chat"])) == leaf("Chat", ratio: "0.25"))
}

// MARK: - 從 bash 實測補的邊界（既有斷言沒涵蓋，但移植必須複製）

/// jq 的真值只把 `false` 與 `null` 當假，`0` 是**真**——所以 ratio 為 0 要印出來。
/// 照直覺寫成「非零才印」會靜默少一行。
@Test func aZeroRatioIsStillEmitted() throws {
    #expect(try collectRatios(obj([("window", .string("A")), ("ratio", .number("0"))]))
        == [LeafRatio(label: .string("A"), ratio: .number("0"))])
}

/// ratio 是 false 或 null 時跳過（jq 的 `if .ratio then` 只有這兩個值會走 else）。
@Test func aFalseOrNullRatioIsSkipped() throws {
    #expect(try collectRatios(obj([("window", .string("A")), ("ratio", .bool(false))])).isEmpty)
    #expect(try collectRatios(obj([("window", .string("A")), ("ratio", .null)])).isEmpty)
}

/// ratio 只掛在葉上有意義：內部節點的 ratio 不會被走訪到。
@Test func aRatioOnAnInternalNodeIsIgnored() throws {
    let node = obj([("axis", .string("vertical")), ("ratio", .number("0.5")),
                    ("children", .array([leaf("A"), leaf("B")]))])
    #expect(try collectRatios(node).isEmpty)
}

/// 葉是**原樣**通過剪枝的：多餘的鍵與來源鍵序都保留（bash 那側是 `.`，不是重建）。
@Test func pruneKeepsALeafVerbatimIncludingUnknownKeys() throws {
    let odd = obj([("ratio", .number("0.75")), ("window", .string("A")), ("zz", .number("1"))])
    let tree = split("vertical", odd, leaf("B"))
    #expect(try LayoutTree.prune(tree, live: live(["A"])) == odd)
}

/// 內部節點則相反：bash 是 `{axis: .axis, children: [...]}`，所以鍵序被正規化成
/// axis→children，而且**多餘的鍵會掉**。這不是可以「順手保留」的細節，輸出要與
/// jq 逐位元組相同。
@Test func pruneRebuildsInternalNodesAndDropsTheirExtraKeys() throws {
    let odd = obj([("children", .array([leaf("A"), leaf("B")])),
                   ("axis", .string("vertical")),
                   ("extra", .number("9"))])
    #expect(try LayoutTree.prune(odd, live: live(["A", "B"]))
        == split("vertical", leaf("A"), leaf("B")))
}

/// axis 不存在時重建成 `{"axis": null, …}`——不是省略那個鍵。
@Test func pruneRebuildsAMissingAxisAsNull() throws {
    let noAxis = obj([("children", .array([leaf("A"), leaf("B")]))])
    #expect(try LayoutTree.prune(noAxis, live: live(["A", "B"]))
        == obj([("axis", .null), ("children", .array([leaf("A"), leaf("B")]))]))
}

/// 第三個 child 到處都被無聲忽略：jq 只碰 children[0] 與 children[1]。
@Test func aThirdChildIsIgnoredEverywhere() throws {
    let three = obj([("axis", .string("v")),
                     ("children", .array([leaf("A"), leaf("B"), leaf("C")]))])
    #expect(try collectSplits(three) == [tsvSplit("A", "v", "B")])
    #expect(try LayoutTree.prune(three, live: live(["A", "B", "C"]))
        == split("v", leaf("A"), leaf("B")))
    #expect(try LayoutTree.referencedLabels(.array([three])) == [.string("A"), .string("B")])
}

/// unique 的排序是 jq 的碼位序，不是地區化比較：`_`（U+005F）排在 `B` 與 `a` 之間。
/// 用 Swift 的 `String <` 會拿到 Unicode 正規化後的順序，那與 jq 對不上。
@Test func referencedLabelsSortByCodePoint() throws {
    let trees = JSONValue.array([leaf("b"), leaf("B"), leaf("a"), leaf("A"),
                                 leaf("中"), leaf("_"), leaf("")])
    #expect(try LayoutTree.referencedLabels(trees)
        == [.string(""), .string("A"), .string("B"), .string("_"),
            .string("a"), .string("b"), .string("中")])
}

/// jq 的跨型別全序：null < false < true < 數字 < 字串。數字之間比數值，
/// 所以 5 與 5.0 是同一個（實測 `[5.0,5] | unique` 回 `[5.0]`，留的是第一個）。
@Test func referencedLabelsFollowJQsTotalOrder() throws {
    let trees = JSONValue.array([
        obj([("window", .string("s"))]), obj([("window", .number("5"))]),
        obj([("window", .bool(true))]), obj([("window", .null)]),
        obj([("window", .bool(false))]), obj([("window", .number("5.0"))]),
    ])
    #expect(try LayoutTree.referencedLabels(trees)
        == [.null, .bool(false), .bool(true), .number("5"), .string("s")])
}

/// bash 那側 `null | has("window")` 是 **false 而不是錯**，而 `null.children[0]`
/// 又是 null，於是 rep 對著 null 永遠遞迴下去——實測 tree_seq 掛住直到 timeout、
/// prune_tree 直接 SIGABRT。無窮迴圈沒有可鏡射的輸出，所以這裡停下來回報。
/// 這種節點 validate_layout 本來就擋得掉（節點必須有 window 或 axis+children）。
@Test func aDegenerateNodeStopsInsteadOfRecursingForever() throws {
    let noWindowNoChildren = obj([("axis", .string("vertical"))])
    #expect(throws: LayoutTreeError.nonTerminating) {
        try LayoutTree.representative(noWindowNoChildren)
    }
    #expect(throws: LayoutTreeError.nonTerminating) { try collectSplits(.null) }
    #expect(throws: LayoutTreeError.nonTerminating) { try collectRatios(.null) }
    #expect(throws: LayoutTreeError.nonTerminating) {
        try LayoutTree.prune(.null, live: live(["A"]))
    }
}

/// 非物件的節點在 bash 那側是 jq 的 runtime error（`Cannot check whether array
/// has a string key`），exit code 5。
@Test func aNonObjectNodeIsARuntimeError() throws {
    #expect(throws: LayoutTreeError.runtime) { try LayoutTree.representative(.array([])) }
    #expect(throws: LayoutTreeError.runtime) { try LayoutTree.representative(.number("5")) }
    #expect(throws: LayoutTreeError.runtime) { try collectSplits(.string("s")) }
}

/// children 不是陣列也不是 null：`"oops"[0]` 在 jq 是 runtime error。
@Test func nonArrayChildrenAreARuntimeError() throws {
    let bad = obj([("axis", .string("v")), ("children", .string("oops"))])
    #expect(throws: LayoutTreeError.runtime) { try collectSplits(bad) }
}

/// 走訪是 streaming 的：bash 那側先印出來的行留在 stdout 上，之後才 exit 5。
/// 所以 API 不能是「算完整份再回傳」——那會讓失敗時的輸出從一行變成零行。
@Test func splitsEmittedBeforeAnErrorAreKept() throws {
    let bad = split("v", leaf("A"),
                    split("h", leaf("B"), obj([("axis", .string("x")),
                                               ("children", .string("bad"))])))
    var seen: [Split] = []
    #expect(throws: LayoutTreeError.runtime) {
        try LayoutTree.splits(bad) { seen.append($0) }
    }
    #expect(seen == [tsvSplit("A", "v", "B")])
}

/// referenced_labels 相反：bash 那側 `[ .[] | leaves ] | unique` 要先把整個陣列
/// 蒐集完才排序，所以中途出錯**一行都不會印**。實測確認過 stdout 是空的。
@Test func referencedLabelsEmitNothingWhenTheyFailPartway() throws {
    let trees = obj([("a", leaf("A")),
                     ("b", obj([("axis", .string("h")), ("children", .string("bad"))]))])
    #expect(throws: LayoutTreeError.runtime) { try LayoutTree.referencedLabels(trees) }
}

/// live 清單不是可迭代的東西時，bash 是 `Cannot iterate over string ("A")`，rc=5。
/// 物件則可以——`$live[]` 取的是它的值。
@Test func theLiveListMustBeIterable() throws {
    #expect(throws: LayoutTreeError.runtime) {
        try LayoutTree.prune(leaf("A"), live: .string("A"))
    }
    #expect(try LayoutTree.prune(leaf("A"), live: obj([("k", .string("A"))])) == leaf("A"))
}

/// 比對用的是 JSON 值相等，不是字串——window 為 null 且 live 含 null 時會留下。
@Test func pruneMatchesByJSONValueNotByText() throws {
    #expect(try LayoutTree.prune(obj([("window", .null)]), live: .array([.null]))
        == obj([("window", .null)]))
    #expect(try LayoutTree.prune(obj([("window", .number("5"))]), live: .array([.number("5.0")]))
        == obj([("window", .number("5"))]))
}
