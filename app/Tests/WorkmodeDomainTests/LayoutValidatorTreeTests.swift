import Testing
@testable import WorkmodeDomain

// `validate_layout` 遞迴的樹節點檢查（workmode.sh:59-72 的 check，呼叫點 :93-94）。
// 路徑是 <地點>.<profile>.trees.<角色>，往下每層接 .0 或 .1。
//
// fixture 在 LayoutValidatorFixtures.swift。

// ---- 遞迴的樹節點檢查（workmode.sh:59-72 的 check，呼叫點 :93-94）------------
// 路徑是 <地點>.<profile>.trees.<角色>，往下每層接 .0 或 .1。
// 這一段全部掛哨兵：輸出分不出「這條規則不觸發」與「整個串流當場結束」。

/// 四條訊息之一。windows 是空的，所以任何 window 值都不在清單裡。
@Test func reportsAWindowThatIsNotInTheLabelList() {
    #expect(LayoutValidator.validate(treeConfig(obj([("window", .string("NOPE"))]))) == [
        .structural("aaa.P.trees.main：window「NOPE」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

@Test func acceptsAWindowThatMatchesALabel() {
    let config = treeConfig(obj([("window", .string("A"))]), windows: windowList([.string("A")]))
    #expect(LayoutValidator.validate(config) == [sentinelProblem])
}

/// `IN($labels[])` 用 jq 的 `==`，比的是**數值**不是字面值——1.5 對得上 1.50。
@Test func matchesAWindowLabelByNumericValue() {
    let config = treeConfig(obj([("window", .number("1.5"))]),
                            windows: windowList([.number("1.50")]))
    #expect(LayoutValidator.validate(config) == [sentinelProblem])
}

/// 四條訊息之二。
@Test func reportsAnAxisThatIsNeitherVerticalNorHorizontal() {
    let node = obj([("axis", .string("diag")), ("children", .array([.null, .null]))])
    #expect(LayoutValidator.validate(treeConfig(node)) == [
        .structural("aaa.P.trees.main：axis「diag」不是 vertical 或 horizontal"),
        sentinelProblem,
    ])
}

/// 四條訊息之三。數量文字是實測值——1 個與 3 個都印阿拉伯數字，沒有單複數變化。
@Test func reportsAChildCountOtherThanTwo() {
    let one = obj([("axis", .string("vertical")),
                   ("children", .array([obj([("window", .string("A"))])]))])
    #expect(LayoutValidator.validate(treeConfig(one, windows: windowList([.string("A")]))) == [
        .structural("aaa.P.trees.main：children 有 1 個，必須恰好 2 個"),
        sentinelProblem,
    ])
}

/// 四條訊息之四。
@Test func reportsANodeWithNeitherWindowNorAxis() {
    #expect(LayoutValidator.validate(treeConfig(.object([]))) == [
        .structural("aaa.P.trees.main：節點既沒有 window 也沒有 axis"),
        sentinelProblem,
    ])
}

/// `type != "object"`——**陣列也不是物件**，null 也是（`null | type` 是 "null"）。
/// 角色層不套 `// empty`，所以 null 與 false 在這裡照報，不像子節點的位置會被略過。
@Test func reportsATreeNodeThatIsNotAnObject() {
    for bad in [JSONValue.array([]), .array([.number("1"), .number("2")]), .null,
                .string("x"), .number("7"), .bool(true), .bool(false)]
    {
        #expect(LayoutValidator.validate(treeConfig(bad)) == [
            .structural("aaa.P.trees.main：節點不是物件"),
            sentinelProblem,
        ], "節點 \(bad)")
    }
}

/// `has("window")` 優先於 `has("axis")`——兩者都有時只走 window 那條，axis 與
/// children 完全不檢查。對照組：拿掉 window 之後同一個節點會吐 axis ＋ children
/// 兩條（實測），所以把判斷順序對調一定會讓這條紅。
@Test func prefersTheWindowBranchOverTheAxisBranch() {
    let both = obj([("window", .string("A")), ("axis", .string("diag")),
                    ("children", .array([]))])
    #expect(LayoutValidator.validate(treeConfig(both)) == [
        .structural("aaa.P.trees.main：window「A」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
    let axisOnly = obj([("axis", .string("diag")), ("children", .array([]))])
    #expect(LayoutValidator.validate(treeConfig(axisOnly)) == [
        .structural("aaa.P.trees.main：axis「diag」不是 vertical 或 horizontal"),
        .structural("aaa.P.trees.main：children 有 0 個，必須恰好 2 個"),
        sentinelProblem,
    ])
}

/// 前序的前半：自己的 axis 檢查在遞迴**之前**。父 axis 拼錯、左子 label 不存在，
/// 兩則訊息的先後就是這個。實測 bash：
///     aaa.P.trees.main：axis「diag」不是 vertical 或 horizontal
///     aaa.P.trees.main.0：window「NOPE」不在生效的 windows 清單裡
@Test func checksTheAxisBeforeRecursingIntoChildren() {
    let node = obj([("axis", .string("diag")),
                    ("children", .array([obj([("window", .string("NOPE"))]),
                                         obj([("window", .string("A"))])]))])
    #expect(LayoutValidator.validate(treeConfig(node, windows: windowList([.string("A")]))) == [
        .structural("aaa.P.trees.main：axis「diag」不是 vertical 或 horizontal"),
        .structural("aaa.P.trees.main.0：window「NOPE」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

/// 前序的後半：左子在右子**之前**。上一條只有左子壞，左右對調它照樣全綠
/// （單一違規的 fixture 兩種順序輸出相同），所以這裡兩個子都壞且訊息可區分。
@Test func recursesIntoTheLeftChildBeforeTheRight() {
    let node = obj([("axis", .string("vertical")),
                    ("children", .array([obj([("window", .string("L"))]),
                                         obj([("window", .string("R"))])]))])
    #expect(LayoutValidator.validate(treeConfig(node)) == [
        .structural("aaa.P.trees.main.0：window「L」不在生效的 windows 清單裡"),
        .structural("aaa.P.trees.main.1：window「R」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

/// 數量檢查在遞迴之前，而且只有 [0] 與 [1] 被遞迴——第三個以後連看都不看。
@Test func onlyRecursesIntoTheFirstTwoChildren() {
    let node = obj([("axis", .string("vertical")),
                    ("children", .array([obj([("window", .string("X"))]),
                                         obj([("window", .string("Y"))]),
                                         obj([("window", .string("Z"))])]))])
    #expect(LayoutValidator.validate(treeConfig(node)) == [
        .structural("aaa.P.trees.main：children 有 3 個，必須恰好 2 個"),
        .structural("aaa.P.trees.main.0：window「X」不在生效的 windows 清單裡"),
        .structural("aaa.P.trees.main.1：window「Y」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

/// 巢狀路徑逐層接 .0／.1。
@Test func usesDottedIndexPathsForNestedNodes() {
    let inner = obj([("axis", .string("horizontal")),
                     ("children", .array([obj([("window", .string("A"))]),
                                          obj([("window", .string("BAD"))])]))])
    let node = obj([("axis", .string("vertical")),
                    ("children", .array([inner, obj([("window", .string("A"))])]))])
    #expect(LayoutValidator.validate(treeConfig(node, windows: windowList([.string("A")]))) == [
        .structural("aaa.P.trees.main.0.1：window「BAD」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

/// `(.children // [])[0] // empty`：null 與 false 的位置**不遞迴**。
@Test func skipsNullAndFalseChildSlots() {
    let node = obj([("axis", .string("vertical")), ("children", .array([.null, .bool(false)]))])
    #expect(LayoutValidator.validate(treeConfig(node)) == [sentinelProblem])
}

/// jq 只有 null 與 false 是 falsy——`0` 與 `""` 照樣遞迴，然後報「節點不是物件」。
/// 少了這條，「用 Swift 的 falsy 直覺跳過空字串／零」會全綠。
@Test func recursesIntoFalsyButNonNullChildSlots() {
    let node = obj([("axis", .string("vertical")),
                    ("children", .array([.number("0"), .string("")]))])
    #expect(LayoutValidator.validate(treeConfig(node)) == [
        .structural("aaa.P.trees.main.0：節點不是物件"),
        .structural("aaa.P.trees.main.1：節點不是物件"),
        sentinelProblem,
    ])
}

/// children 缺（或元素不足兩個）時缺的位置是 null → `// empty` → 不遞迴。
@Test func aMissingChildrenCountsAsZeroWithoutRecursing() {
    #expect(LayoutValidator.validate(treeConfig(obj([("axis", .string("vertical"))]))) == [
        .structural("aaa.P.trees.main：children 有 0 個，必須恰好 2 個"),
        sentinelProblem,
    ])
}

/// `\(.window)` 對非字串值：數字保留**字面值**（`1.50` 不會變 `1.5`），
/// 物件與陣列是緊湊 JSON。全部實測自 bash。
@Test func rendersNonStringWindowValuesLikeJQ() {
    let cases: [(JSONValue, String)] = [
        (.number("1.50"), "1.50"),
        (.object([]), "{}"),
        (obj([("a", .number("1"))]), #"{"a":1}"#),
        (.array([]), "[]"),
        (.array([.number("1"), .number("2")]), "[1,2]"),
        (.bool(true), "true"),
        (.null, "null"),
    ]
    for (value, rendered) in cases {
        #expect(LayoutValidator.validate(treeConfig(obj([("window", value)]))) == [
            .structural("aaa.P.trees.main：window「\(rendered)」不在生效的 windows 清單裡"),
            sentinelProblem,
        ], "window=\(rendered)")
    }
}

/// axis 那條走同一套插值。
@Test func rendersNonStringAxisValuesLikeJQ() {
    for (value, rendered) in [(JSONValue.number("1.50"), "1.50"),
                              (.object([]), "{}"), (.array([]), "[]"),
                              (.bool(true), "true"), (.null, "null")]
    {
        let node = obj([("axis", value), ("children", .array([.null, .null]))])
        #expect(LayoutValidator.validate(treeConfig(node)) == [
            .structural("aaa.P.trees.main：axis「\(rendered)」不是 vertical 或 horizontal"),
            sentinelProblem,
        ], "axis=\(rendered)")
    }
}

/// 容器裡的字串照 JSON 跳脫，與 `JSONWriter` 同一套——含 U+007F → `\u007f` 那個
/// quirk，而非 ASCII **不**跳脫。輸入側的控制字元寫 `\u{...}` 不打真字元，
/// 否則被誰改成別的字元不會有人發現。實測 bash 的整串輸出就是斷言裡那一行。
@Test func escapesStringsInsideRenderedContainersLikeJQ() {
    let value = obj([("k", .string("q\"b\\s\u{0009}z")),
                     ("n", .array([.number("1"), obj([("b", .null)])])),
                     ("c", .bool(true)),
                     ("u", .string("中\u{1F600}")),
                     ("d", .string("\u{007F}"))])
    let rendered = #"{"k":"q\"b\\s\tz","n":[1,{"b":null}],"c":true,"u":"中"# + "\u{1F600}"
        + #"","d":"\u007f"}"#
    #expect(LayoutValidator.validate(treeConfig(obj([("window", value)]))) == [
        .structural("aaa.P.trees.main：window「\(rendered)」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

/// `$pv.trees // {}` 是 truthy 就直接 `to_entries`——字串、數字、true 都在那裡
/// runtime error（`has no keys`），整個串流結束。
@Test func aNonIterableTreesStopsTheWholePass() {
    for bad in [JSONValue.string("str"), .number("42"), .bool(true)] {
        #expect(LayoutValidator.validate(treeConfigRaw(bad)).isEmpty, "trees=\(bad)")
    }
}

/// null 與 false 走 `// {}` 變成空物件——一個角色都沒有，不觸發也不中止。
/// 注意 `has("trees")` 仍為真，所以也不報「缺 trees」。與上面那條是一組對照。
@Test func aNullOrFalseTreesIsSkippedWithoutStopping() {
    for skipped in [JSONValue.null, .bool(false)] {
        #expect(LayoutValidator.validate(treeConfigRaw(skipped)) == [sentinelProblem],
                "trees=\(skipped)")
    }
}

/// **陣列是例外**：`to_entries` 對陣列合法，角色名變成索引數字。
@Test func anArrayTreesUsesNumericRoleNames() {
    let config = treeConfigRaw(.array([obj([("window", .string("BAD"))])]))
    #expect(LayoutValidator.validate(config) == [
        .structural("aaa.P.trees.0：window「BAD」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

/// 角色依來源鍵序，不排序。
@Test func checksTreeRolesInSourceOrder() {
    let config = treeConfigRaw(obj([("zz", obj([("window", .string("B1"))])),
                                    ("aa", obj([("window", .string("B2"))]))]))
    #expect(LayoutValidator.validate(config) == [
        .structural("aaa.P.trees.zz：window「B1」不在生效的 windows 清單裡"),
        .structural("aaa.P.trees.aa：window「B2」不在生效的 windows 清單裡"),
        sentinelProblem,
    ])
}

/// 一個角色中止的是**整個串流**——後面的角色與後面的地點一條都不檢查。
@Test func aStoppedRoleSwallowsTheRolesAfterIt() {
    let config = treeConfigRaw(obj([
        ("r1", obj([("axis", .string("vertical")), ("children", .number("2"))])),
        ("r2", obj([("window", .string("BAD"))])),
    ]))
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// children 是物件時 `length` 算得出來（成員數），數量訊息**先落地**，然後
/// `{}[0]` 報 `Cannot index object with number`、整個串流結束。
@Test func anObjectChildrenReportsItsCountThenStopsThePass() {
    let node = obj([("axis", .string("vertical")), ("children", .object([]))])
    #expect(LayoutValidator.validate(treeConfig(node))
        == [.structural("aaa.P.trees.main：children 有 0 個，必須恰好 2 個")])
}

/// 成員數剛好 2 時連訊息都沒有，直接中止——零輸出。與上面那條是一組對照，
/// 少一個就分不出「數量檢查先跑」與「整條在 length 就死了」。
@Test func anObjectChildrenWithTwoMembersStopsThePassSilently() {
    let node = obj([("axis", .string("vertical")),
                    ("children", obj([("a", .number("1")), ("b", .number("2"))]))])
    #expect(LayoutValidator.validate(treeConfig(node)).isEmpty)
}

/// 字串的 length 是**碼位**數，不是 UTF-16 code unit：`😀a` 是 2 不是 3，
/// 所以它連數量訊息都沒有就中止。
@Test func aStringChildrenCountsCodePointsThenStopsThePass() {
    let three = obj([("axis", .string("vertical")), ("children", .string("abc"))])
    #expect(LayoutValidator.validate(treeConfig(three))
        == [.structural("aaa.P.trees.main：children 有 3 個，必須恰好 2 個")])
    let two = obj([("axis", .string("vertical")), ("children", .string("\u{1F600}a"))])
    #expect(LayoutValidator.validate(treeConfig(two)).isEmpty)
}

/// 數字的 length 是絕對值，而且 jq 1.8 保留字面值、只去掉負號——實測 `-2.50`
/// 的 length 印成 `2.50`。算完照樣死在 `5[0]`（`Cannot index number with number`）。
@Test func aNumberChildrenCountsItsAbsoluteValueLiteral() {
    for (literal, rendered) in [("5", "5"), ("-5", "5"), ("2.5", "2.5"),
                                ("-2.50", "2.50"), ("3.0", "3.0")]
    {
        let node = obj([("axis", .string("vertical")), ("children", .number(literal))])
        #expect(LayoutValidator.validate(treeConfig(node))
            == [.structural("aaa.P.trees.main：children 有 \(rendered) 個，必須恰好 2 個")],
            "children=\(literal)")
    }
    for literal in ["2", "-2"] {
        let node = obj([("axis", .string("vertical")), ("children", .number(literal))])
        #expect(LayoutValidator.validate(treeConfig(node)).isEmpty, "children=\(literal)")
    }
}

/// boolean **沒有 length**，jq 在那裡就 runtime error——數量訊息連產生的機會都沒有，
/// 但同一個節點的 axis 訊息已經先落地了。這一條同時釘住中止點與那個先後。
@Test func aBooleanChildrenStopsThePassBeforeTheCountMessage() {
    let node = obj([("axis", .string("diag")), ("children", .bool(true))])
    #expect(LayoutValidator.validate(treeConfig(node))
        == [.structural("aaa.P.trees.main：axis「diag」不是 vertical 或 horizontal")])
}
