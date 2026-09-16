import Testing
@testable import WorkmodeDomain

// 從矩形反推切割樹（rects_to_tree）與剪枝後留比例（trim_ratios）。斷言分三類：
//   1. tests/test_workmode.sh 既有的 21 處呼叫（11 處 rects_to_tree、10 處
//      trim_ratios，其中兩條完整往返同時算進兩邊），每條都標了它翻譯自哪一行
//   2. 2026-08-14 拿 jq 1.8.2 對 scripts/workmode.sh 實跑挖出來的邊界
//   3. jq 的 dtoa（JQNumber）——ratio 是**算出來的**數字，字面值保留那條在這裡
//      不適用，輸出走的是 jq 自己的印法
//
// 第 2 類不是湊數：`.children = [...]` 是賦值所以會**補**出 children 鍵、三個
// children 會被截成兩個、`0` 與 `""` 是真值所以 `//` 不接手、字串 ratio 因為
// jq 的跨型別全序而大於任何數字、寬度為 0 的矩形會同時落進兩邊而讓 bash 無限
// 遞迴——這些從程式碼一條都讀不出來。

// MARK: - test_workmode.sh 的語料（座標逐字相同）

private let rLR = JSONValue.array([
    rect(.string("A"), "24", "43", "1692", "1349"),
    rect(.string("B"), "1724", "43", "1692", "1349"),
])
private let rTB = JSONValue.array([
    rect(.string("A"), "24", "43", "3392", "670"),
    rect(.string("B"), "24", "722", "3392", "670"),
])
private let rThree = JSONValue.array([
    rect(.string("A"), "0", "0", "1000", "1000"),
    rect(.string("B"), "1000", "0", "1000", "1000"),
    rect(.string("C"), "2000", "0", "1000", "1000"),
])
private let rQuad = JSONValue.array([
    rect(.string("A"), "0", "0", "1000", "1000"),
    rect(.string("B"), "1000", "0", "1000", "1000"),
    rect(.string("C"), "0", "1000", "1000", "1000"),
    rect(.string("D"), "1000", "1000", "1000", "1000"),
])
private let rOne = JSONValue.array([rect(.string("A"), "0", "0", "100", "100")])
private let rOverlap = JSONValue.array([
    rect(.string("A"), "0", "0", "100", "100"),
    rect(.string("B"), "0", "0", "100", "100"),
])
private let rNeg = JSONValue.array([
    rect(.string("A"), "-2536", "-608", "1200", "1385"),
    rect(.string("B"), "-1300", "-608", "1200", "1385"),
])
private let rChat = JSONValue.array([
    rect(.string(""), "-2536", "-608", "626", "1385"),
    rect(.string("Chat"), "-1900", "-608", "1878", "1385"),
])
private let rChatInverted = JSONValue.array([
    rect(.string("Chat"), "-2536", "-608", "626", "1385"),
    rect(.string(""), "-1900", "-608", "1878", "1385"),
])

// MARK: - rects_to_tree（test_workmode.sh:526-543）

@Test func twoSideBySideWindowsBecomeAVerticalSplit() throws {
    #expect(try RectTree.fromRects(rLR)
        == split("vertical", leaf(.string("A"), "0.5"), leaf(.string("B"), "0.5")))
}

@Test func twoStackedWindowsBecomeAHorizontalSplit() throws {
    #expect(try RectTree.fromRects(rTB)
        == split("horizontal", leaf(.string("A"), "0.5"), leaf(.string("B"), "0.5")))
}

@Test func threeInARowTakeTheLeftmostCutSoTheTreeLeansRight() throws {
    #expect(try RectTree.fromRects(rThree)
        == split("vertical", leaf(.string("A"), "0.33"),
                 split("vertical", leaf(.string("B"), "0.5"), leaf(.string("C"), "0.5"))))
}

@Test func aQuadTriesVerticalBeforeHorizontal() throws {
    #expect(try RectTree.fromRects(rQuad)
        == split("vertical",
                 split("horizontal", leaf(.string("A"), "0.5"), leaf(.string("C"), "0.5")),
                 split("horizontal", leaf(.string("B"), "0.5"), leaf(.string("D"), "0.5"))))
}

@Test func aLoneWindowIsALeafWithNoRatioBecauseItHasNoParentSplit() throws {
    #expect(try RectTree.fromRects(rOne) == leaf(.string("A")))
}

@Test func fullyOverlappingRectanglesHaveNoCutLine() throws {
    #expect(try RectTree.fromRects(rOverlap) == .null)
}

@Test func noRectanglesAtAllIsNull() throws {
    #expect(try RectTree.fromRects(.array([])) == .null)
}

@Test func negativeCoordinatesStillSplit() throws {
    #expect(try RectTree.fromRects(rNeg)
        == split("vertical", leaf(.string("A"), "0.5"), leaf(.string("B"), "0.5")))
}

// MARK: - trim_ratios（test_workmode.sh:546-559）

@Test func theWiderSideOfASplitKeepsItsRatio() throws {
    #expect(try RectTree.trim(leaf(.string("Chat"), "0.75")) == leaf(.string("Chat"), "0.75"))
}

@Test func theNarrowerSideDropsItsRatio() throws {
    #expect(try RectTree.trim(leaf(.string("X"), "0.25")) == leaf(.string("X")))
}

@Test func anEvenSplitIsNotWorthWriting() throws {
    #expect(try RectTree.trim(leaf(.string("X"), "0.5")) == leaf(.string("X")))
}

@Test func withinThreeHundredthsOfEvenCountsAsEven() throws {
    #expect(try RectTree.trim(leaf(.string("X"), "0.52")) == leaf(.string("X")))
}

@Test func pastThreeHundredthsTheRatioIsWorthWriting() throws {
    #expect(try RectTree.trim(leaf(.string("X"), "0.54")) == leaf(.string("X"), "0.54"))
}

@Test func aLeafThatNeverHadARatioSurvivesUntouched() throws {
    #expect(try RectTree.trim(leaf(.string("X"))) == leaf(.string("X")))
}

@Test func nullPassesStraightThrough() throws {
    #expect(try RectTree.trim(.null) == .null)
}

@Test func whenTheWiderSideIsASubtreeTheWholeSplitLosesItsRatios() throws {
    let input = split("vertical", leaf(.string("A"), "0.33"),
                      split("vertical", leaf(.string("B"), "0.5"), leaf(.string("C"), "0.5")))
    let expected = split("vertical", leaf(.string("A")),
                         split("vertical", leaf(.string("B")), leaf(.string("C"))))
    #expect(try RectTree.trim(input) == expected)
}

// MARK: - 反推 → 剪枝 → 留比例 的完整往返（test_workmode.sh:566-574）

@Test func theUnlabelledNeighbourHoldsUpTheRatioSoChatMeasuresThreeQuarters() throws {
    #expect(try RectTree.fromRects(rChat)
        == split("vertical", leaf(.string(""), "0.25"), leaf(.string("Chat"), "0.75")))
}

@Test func chatKeepsThreeQuartersAfterTheUnlabelledNeighbourIsPruned() throws {
    let tree = try RectTree.fromRects(rChat)
    let pruned = try #require(try LayoutTree.prune(tree, live: .array([.string("Chat")])))
    #expect(try RectTree.trim(pruned) == leaf(.string("Chat"), "0.75"))
}

@Test func whenTheUnlabelledNeighbourIsTheWiderOneNothingIsKept() throws {
    let tree = try RectTree.fromRects(rChatInverted)
    let pruned = try #require(try LayoutTree.prune(tree, live: .array([.string("Chat")])))
    #expect(try RectTree.trim(pruned) == leaf(.string("Chat")))
}
