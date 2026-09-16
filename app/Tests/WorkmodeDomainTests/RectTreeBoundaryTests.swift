import Testing
@testable import WorkmodeDomain

// rects_to_tree 與 trim_ratios 的邊界，全部是 2026-08-14 拿 jq 1.8.2 對
// scripts/workmode.sh 實跑挖出來的，不是照語意推的。與主檔分開是因為它一條語料都
// 不用（每條自己造最小的輸入），共用的只有 RectTreeFixtures.swift 那兩支建構子。
//
// 最後一組驗 jq 的 dtoa：ratio 是**算出來的**數字，layout.json 那條「字面值逐字
// 保留」在這裡不適用。

// MARK: - rects_to_tree 的邊界（2026-08-14 對 jq 1.8.2 實測）

@Test func aWindowWithNoLabelKeyBecomesAWindowOfNull() throws {
    let rects = JSONValue.array([
        rect(nil, "0", "0", "10", "10"),
        rect(nil, "20", "0", "10", "10"),
    ])
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.null, "0.5"), leaf(.null, "0.5")))
}

@Test func anExplicitNullLabelIsIndistinguishableFromAMissingOne() throws {
    let rects = JSONValue.array([
        rect(.null, "0", "0", "10", "10"),
        rect(.string("B"), "20", "0", "10", "10"),
    ])
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.null, "0.5"), leaf(.string("B"), "0.5")))
}

/// 座標全部缺席時每個候選切線都是 null，而 `$cx != null` 把它讀成「切不開」。
@Test func rectanglesWithNoCoordinatesAtAllCannotBeSplit() throws {
    let rects = JSONValue.array([
        obj([("label", .string("A"))]),
        obj([("label", .string("B"))]),
    ])
    #expect(try RectTree.fromRects(rects) == .null)
}

@Test func aRectangleFullyInsideAnotherLeavesNoCutLine() throws {
    let rects = JSONValue.array([
        rect(.string("A"), "0", "0", "100", "100"),
        rect(.string("B"), "10", "10", "10", "10"),
    ])
    #expect(try RectTree.fromRects(rects) == .null)
}

@Test func anLShapeSplitsVerticallyThenHorizontally() throws {
    let rects = JSONValue.array([
        rect(.string("A"), "0", "0", "100", "200"),
        rect(.string("B"), "100", "0", "100", "100"),
        rect(.string("C"), "100", "100", "100", "100"),
    ])
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.string("A"), "0.5"),
                 split("horizontal", leaf(.string("B"), "0.5"), leaf(.string("C"), "0.5"))))
}

/// 五個一排：每一層都取最左那條切線，所以樹一路往右長，而每一層的 ratio 都是
/// 「這一個 vs 右邊剩下全部」。
@Test func fiveInARowNestFiveDeepToTheRight() throws {
    let rects = JSONValue.array((0 ..< 5).map {
        rect(.string(String(UnicodeScalar(UInt8(65 + $0)))), String($0 * 100), "0", "100", "100")
    })
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.string("A"), "0.2"),
                 split("vertical", leaf(.string("B"), "0.25"),
                       split("vertical", leaf(.string("C"), "0.33"),
                             split("vertical", leaf(.string("D"), "0.5"),
                                   leaf(.string("E"), "0.5"))))))
}

@Test func fractionalCoordinatesAreNotRoundedBeforeTheRatioIsTaken() throws {
    let rects = JSONValue.array([
        rect(.string("A"), "0", "0", "1.5", "10"),
        rect(.string("B"), "1.5", "0", "2.5", "10"),
    ])
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.string("A"), "0.38"), leaf(.string("B"), "0.63")))
}

/// `length == 0` 收掉的不只是空陣列：null、`{}`、數字 0 與空字串都是 0。
@Test func everyValueWhoseJQLengthIsZeroReconstructsToNull() throws {
    for input in [JSONValue.null, .object([]), .number("0"), .string("")] {
        #expect(try RectTree.fromRects(input) == .null)
    }
}

/// `$rs[]` 吃物件時走的是它的**值**，而 `map` 又把結果變回陣列，所以物件形狀
/// 的矩形集合照樣反推得出來。
@Test func anObjectOfRectanglesIteratesItsValues() throws {
    let rects = obj([
        ("a", rect(.string("A"), "0", "0", "10", "10")),
        ("b", rect(.string("B"), "20", "0", "10", "10")),
    ])
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.string("A"), "0.5"), leaf(.string("B"), "0.5")))
}

@Test func aSingleElementListOfNullYieldsAWindowOfNull() throws {
    #expect(try RectTree.fromRects(.array([.null])) == leaf(.null))
}

@Test func twoNullsHaveNoCoordinatesSoTheyCannotBeSplit() throws {
    #expect(try RectTree.fromRects(.array([.null, .null])) == .null)
}

/// jq 的 `length` 對 boolean 直接報錯，對數字回絕對值——所以 `-3` 走的是「三個
/// 元素」那條，然後在 `$rs[]` 上炸掉。
@Test func rootsThatJQCannotIterateAreRuntimeErrors() throws {
    for input in [JSONValue.bool(true), .number("2.5"), .number("-3"), .string("ab")] {
        #expect(throws: RectTreeError.runtime) { try RectTree.fromRects(input) }
    }
}

/// `length == 1` 走 `.[0].label`：物件與字串在索引那一步炸，數字在取 label 那一步炸。
@Test func singleElementRootsThatCannotBeIndexedAreRuntimeErrors() throws {
    for input in [JSONValue.object([("k", JSONValue.number("1"))]
                      .map { JSONMember(key: $0.0, value: $0.1) }),
    .string("a"), .number("1"), .array([.number("5")])] {
        #expect(throws: RectTreeError.runtime) { try RectTree.fromRects(input) }
    }
}

/// 字串座標在 `span` 的減法上炸（`"010" - "0"`），不是在加法上——`+` 對兩個
/// 字串是串接。
@Test func stringCoordinatesSurviveAdditionAndDieOnSubtraction() throws {
    let rects = JSONValue.array([
        rect(.string("A"), "0", "0", "10", "10"),
        rect(.string("B"), "20", "0", "10", "10"),
    ])
    func stringified(_ value: JSONValue) -> JSONValue {
        guard case let .array(items) = value else { return value }
        return .array(items.map { item in
            guard case let .object(members) = item else { return item }
            return .object(members.map { member in
                guard case let .number(literal) = member.value else { return member }
                return JSONMember(key: member.key, value: .string(literal))
            })
        })
    }
    #expect(throws: RectTreeError.runtime) { try RectTree.fromRects(stringified(rects)) }
}

/// 寬度為 0 的矩形同時滿足 `x >= c` 與 `x + w <= c`，於是落進切線的**兩邊**，
/// 子集合等於原集合、遞迴永遠不收斂。bash 那側實測是掛住到 timeout 或
/// `cannot allocate memory` 的 SIGABRT，沒有可鏡射的輸出。
@Test func zeroWidthRectanglesWouldMakeBashRecurseForever() throws {
    let rects = JSONValue.array([
        rect(.string("A"), "0", "0", "0", "0"),
        rect(.string("B"), "10", "0", "0", "0"),
    ])
    #expect(throws: RectTreeError.nonTerminating) { try RectTree.fromRects(rects) }
}

/// span 溢位成 inf 時 `inf / inf` 是 NaN，而 NaN 沒有數字字面值——jq 印的是字面的
/// `null`。這一條釘的是「中途算出來的數字不可以走印法」：印法把 inf 收斂成 DBL_MAX
/// （jq 也是這樣印的），先收斂就變成 `ratio: 1`，一個看起來完全正常的錯答案。
@Test func aSpanThatOverflowsToInfinityStampsANullRatio() throws {
    let rects = JSONValue.array([
        rect(.string("A"), "-10", "0", "5", "10"),
        rect(.string("C"), "0", "0", "1e999", "10"),
    ])
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.string("A"), "0"),
                 obj([("window", .string("C")), ("ratio", .null)])))
}

/// 兩邊都是 1e308 時只有**總和**溢位，兩個比例都收斂成 0（不是 0.5）。
@Test func onlyTheSumOverflowingSendsBothRatiosToZero() throws {
    let rects = JSONValue.array([
        rect(.string("A"), "-1e308", "0", "1e308", "10"),
        rect(.string("B"), "0", "0", "1e308", "10"),
    ])
    #expect(try RectTree.fromRects(rects)
        == split("vertical", leaf(.string("A"), "0"), leaf(.string("B"), "0")))
}

// MARK: - trim_ratios 的邊界（2026-08-14 對 jq 1.8.2 實測）

/// `.children = [...]` 是**賦值**：本來沒有 children 的內部節點會被補出一個。
@Test func anInternalNodeWithNoChildrenGainsOneMadeOfTwoNulls() throws {
    #expect(try RectTree.trim(obj([("axis", .string("v"))]))
        == obj([("axis", .string("v")), ("children", .array([.null, .null]))]))
}

@Test func aMissingSecondChildIsFilledInWithNull() throws {
    let input = obj([("axis", .string("v")),
                     ("children", .array([leaf(.string("A"), "0.9")]))])
    #expect(try RectTree.trim(input)
        == obj([("axis", .string("v")),
                ("children", .array([leaf(.string("A"), "0.9"), .null]))]))
}

/// 賦值換掉的是整個陣列，所以第三個 child 直接消失。
@Test func aThirdChildIsDroppedBecauseTheWholeArrayIsReplaced() throws {
    let input = obj([("axis", .string("v")),
                     ("children", .array([leaf(.string("A"), "0.9"),
                                          leaf(.string("B")), leaf(.string("C"))]))])
    #expect(try RectTree.trim(input)
        == obj([("axis", .string("v")),
                ("children", .array([leaf(.string("A"), "0.9"), leaf(.string("B"))]))]))
}

@Test func childrenThatCannotBeIndexedByNumberAreRuntimeErrors() throws {
    for children in [JSONValue.string("xy"), obj([("a", num("1"))])] {
        let input = obj([("axis", .string("v")), ("children", children)])
        #expect(throws: RectTreeError.runtime) { try RectTree.trim(input) }
    }
}

/// `//` 只接手 null 與 false。`0` 與 `""` 都是真值，所以它們自己去跟 0.53 比——
/// 而 jq 的全序把字串排在所有數字之上，空字串於是「大於」0.53。
@Test func theAlternativeOperatorOnlyCatchesNullAndFalse() throws {
    #expect(try RectTree.trim(leaf(.string("A"), "0")) == leaf(.string("A")))
    #expect(try RectTree.trim(obj([("window", .string("A")), ("ratio", .null)]))
        == leaf(.string("A")))
    #expect(try RectTree.trim(obj([("window", .string("A")), ("ratio", .bool(false))]))
        == leaf(.string("A")))
    #expect(try RectTree.trim(obj([("window", .string("A")), ("ratio", .string(""))]))
        == obj([("window", .string("A")), ("ratio", .string(""))]))
}

/// jq 的跨型別全序：null < false < true < 數字 < 字串 < 陣列 < 物件。
/// 所以 `true` 留不下來而任何字串、陣列、物件都留得下來。
@Test func theThresholdComparisonUsesJQCrossTypeOrdering() throws {
    #expect(try RectTree.trim(obj([("window", .string("A")), ("ratio", .bool(true))]))
        == leaf(.string("A")))
    for kept in [JSONValue.string("x"), .array([]), .object([])] {
        let node = obj([("window", .string("A")), ("ratio", kept)])
        #expect(try RectTree.trim(node) == node)
    }
}

@Test func theThresholdItselfIsExcludedButAnythingAboveItIsKept() throws {
    #expect(try RectTree.trim(leaf(.string("A"), "0.53")) == leaf(.string("A")))
    #expect(try RectTree.trim(leaf(.string("A"), "0.5300000001"))
        == leaf(.string("A"), "0.5300000001"))
}

/// `del(.ratio)` 只拿掉那一個鍵，其餘的鍵與鍵序原封不動——這棵樹會被寫回
/// layout.json，鍵序一動就是一個沒有意義的全檔 diff。
@Test func deletingTheRatioLeavesEveryOtherKeyWhereItWas() throws {
    let input = obj([("ratio", num("0.2")), ("window", .string("A")), ("z", num("1"))])
    #expect(try RectTree.trim(input) == obj([("window", .string("A")), ("z", num("1"))]))

    let kept = obj([("ratio", num("0.9")), ("window", .string("A")), ("z", num("1"))])
    #expect(try RectTree.trim(kept) == kept)
}

@Test func assigningChildrenKeepsTheSurroundingKeysInPlace() throws {
    let input = obj([("axis", .string("v")), ("q", num("7")),
                     ("children", .array([leaf(.string("A"), "0.9"),
                                          leaf(.string("B"), "0.1")]))])
    #expect(try RectTree.trim(input)
        == obj([("axis", .string("v")), ("q", num("7")),
                ("children", .array([leaf(.string("A"), "0.9"), leaf(.string("B"))]))]))
}

/// `type != "object"` 原樣回傳，陣列也算——所以陣列裡的葉不會被走訪。
@Test func anythingThatIsNotAnObjectIsReturnedUntouched() throws {
    let array = JSONValue.array([leaf(.string("A"), "0.9")])
    #expect(try RectTree.trim(array) == array)
    for scalar in [JSONValue.number("5"), .string("s"), .bool(true), .bool(false)] {
        #expect(try RectTree.trim(scalar) == scalar)
    }
}

// MARK: - jq 的 dtoa（ratio 是算出來的，不走字面值保留）

@Test func computedNumbersPrintTheWayJQPrintsThem() {
    #expect(JQNumber.text(0) == "0")
    #expect(JQNumber.text(-0.0) == "-0")
    #expect(JQNumber.text(1) == "1")
    #expect(JQNumber.text(0.5) == "0.5")
    #expect(JQNumber.text(0.33) == "0.33")
    #expect(JQNumber.text(-1.01) == "-1.01")
    #expect(JQNumber.text(123.45) == "123.45")
    #expect(JQNumber.text(10) == "10")
}

/// 高位門檻是 `decpt > 位數 + 15`，不是固定的量級：`1e15` 印成整數而 `1e16`
/// 印成指數，但兩位有效數字的 `1.2e16` 又印回整數。
@Test func theExponentThresholdMovesWithTheNumberOfSignificantDigits() {
    #expect(JQNumber.text(1e15) == "1000000000000000")
    #expect(JQNumber.text(1e16) == "1e+16")
    #expect(JQNumber.text(1.2e16) == "12000000000000000")
    #expect(JQNumber.text(1.2e17) == "1.2e+17")
    #expect(JQNumber.text(1.23e17) == "123000000000000000")
    #expect(JQNumber.text(1.23e18) == "1.23e+18")
    #expect(JQNumber.text(1.234567890123456e31) == "1.234567890123456e+31")
}

/// 低位門檻是 `decpt <= -4`，而指數一定帶正負號且至少兩位。
@Test func smallNumbersSwitchToExponentAtTenToTheMinusFive() {
    #expect(JQNumber.text(0.0001) == "0.0001")
    #expect(JQNumber.text(1e-5) == "1e-05")
    #expect(JQNumber.text(1.234e-5) == "1.234e-05")
    #expect(JQNumber.text(1e-100) == "1e-100")
    #expect(JQNumber.text(1e100) == "1e+100")
    #expect(JQNumber.text(-1e-5) == "-1e-05")
}
