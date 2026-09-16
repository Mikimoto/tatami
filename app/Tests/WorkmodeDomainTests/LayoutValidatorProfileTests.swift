import Testing
@testable import WorkmodeDomain

// `validate_layout` 的 profile 層（workmode.sh:85-92 的四條）與生效的 windows 清單。
// 與地點層分開，因為它接在地點層那五條**之後**、同一個地點的 jq 串流裡，所以每個
// fixture 都要先讓地點層全過——那是 locationWith 存在的理由。
//
// fixture 在 LayoutValidatorFixtures.swift。

// MARK: - profile 層的四條檢查（workmode.sh:85-92）

//
// 這一段接在地點層那五條之後、同一個地點的 jq 串流裡。每則訊息都是 bash 實跑取得：
//   bash -c 'source scripts/workmode.sh; json=$(cat); validate_layout "$json"' <<< '<json>'
// 中止那幾條一律用「後面再放一個名稱含空白的合法地點」當哨兵——只看前面那個地點的
// 輸出分不出「這條規則不觸發」與「整個串流當場結束」。

@Test func reportsAProfileNamedAuto() {
    let config = obj([("home", locationWith(profile: "auto", okProfile))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home 的 profile 不能叫 auto，那是 --switch 的保留字")])
}

@Test func reportsWhitespaceInAProfileName() {
    let config = obj([("home", locationWith(profile: "my p", okProfile))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home 的 profile 名稱「my p」不能含空白")])
}

/// 與地點名稱那條同一個 `test("\\s")`：全形空白也算。刻意寫跳脫序列而不是真字元
/// ——真的全形空白被誰改成半形不會有人發現，測試就靜默退化成上一條。
@Test func treatsAnIdeographicSpaceInAProfileNameAsWhitespace() {
    let name = "my\u{3000}p"
    let config = obj([("home", locationWith(profile: name, okProfile))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home 的 profile 名稱「\(name)」不能含空白")])
}

@Test func reportsAProfileMissingTrees() {
    let config = obj([("home", locationWith(profile: "P", .object([])))])
    #expect(LayoutValidator.validate(config) == [.structural("home.P：缺 trees")])
}

@Test func reportsDuplicateWindowLabels() {
    let config = obj([("home", locationWith(profile: "P", okProfile,
                                            windows: windowList([.string("A"), .string("A")])))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home.P：windows 的 label 重複（A）")])
}

/// 重複清單是 **jq 排序過**的，不是來源順序——`group_by` 會先排序。
/// 來源是 z、a、z、a、m，輸出是 a、z。實測：
///   $ jq -rn '["z","a","z","a","m"] | group_by(.) | map(select(length > 1) | .[0]) | join("、")'
///   a、z
/// 少了這條，「照來源順序吐」會全綠（它對單一重複值的 fixture 產生相同輸出）。
@Test func sortsTheDuplicateLabelList() {
    let labels: [JSONValue] = [.string("z"), .string("a"), .string("z"), .string("a"), .string("m")]
    let config = obj([("home", locationWith(profile: "P", okProfile,
                                            windows: windowList(labels)))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home.P：windows 的 label 重複（a、z）")])
}

/// jq 的字串排序是碼位序，不是 locale 序——大寫全部排在小寫前面。實測：
///   $ jq -cn '["b","A","a","B"] | sort'
///   ["A","B","a","b"]
@Test func sortsTheDuplicateLabelListByCodePoint() {
    let labels: [JSONValue] = [.string("b"), .string("A"), .string("b"), .string("A")]
    let config = obj([("home", locationWith(profile: "P", okProfile,
                                            windows: windowList(labels)))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home.P：windows 的 label 重複（A、b）")])
}

/// 同一個 profile 內依宣告順序：auto → 空白 → 缺 trees → label 重複。
/// （auto 與空白湊不到同一個名字上，所以這裡最多同時中 3 條。）
@Test func reportsProfileProblemsInDeclarationOrder() {
    let config = obj([("home", locationWith(profile: "a b", .object([]),
                                            windows: windowList([.string("A"), .string("A")])))])
    #expect(LayoutValidator.validate(config) == [
        .structural("home 的 profile 名稱「a b」不能含空白"),
        .structural("home.a b：缺 trees"),
        .structural("home.a b：windows 的 label 重複（A）"),
    ])
}

/// 地點層那五條全部排在 profile 那四條之前。實測 bash 的五行輸出就是這個順序。
@Test func checksProfilesAfterTheLocationLevelChecks() {
    let config = obj([
        ("a a", obj([("desc", .string("x")),
                     ("displays", obj([("main", .string("M"))])),
                     ("windows", .array([])),
                     ("trees", .object([])),
                     ("default", .string("Q")),
                     ("profiles", obj([("p q", .object([]))]))])),
    ])
    #expect(LayoutValidator.validate(config) == [
        .structural("a a：trees 不能放在地點層，要搬進 profiles.<名稱>.trees"),
        .structural("地點名稱「a a」不能含空白"),
        .structural("a a.default「Q」不是這個地點的 profile"),
        .structural("a a 的 profile 名稱「p q」不能含空白"),
        .structural("a a.p q：缺 trees"),
    ])
}

/// profile 之間依來源鍵序，不是字典序（zz z 排在 auto 前面）。
@Test func reportsProfilesInSourceOrder() {
    let config = obj([
        ("home", obj([("desc", .string("x")),
                      ("displays", obj([("main", .string("M"))])),
                      ("windows", .array([])),
                      ("profiles", obj([("zz z", okProfile), ("auto", okProfile)]))])),
    ])
    #expect(LayoutValidator.validate(config) == [
        .structural("home 的 profile 名稱「zz z」不能含空白"),
        .structural("home 的 profile 不能叫 auto，那是 --switch 的保留字"),
    ])
}

// MARK: - 生效的 windows 清單（$labels）

/// `$pv.windows // (($root.windows // []) + ($lv.windows // []))`：profile 自己有
/// windows 就**整塊取代**，地點層那份重複的 label 完全不看。
@Test func aProfileWithItsOwnWindowsIgnoresTheInheritedOnes() {
    let config = obj([("home", locationWith(
        profile: "P",
        obj([("trees", .object([])), ("windows", windowList([.string("B")]))]),
        windows: windowList([.string("A"), .string("A")])
    ))])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 沒有自己的 windows 時是**最外層接上地點層**，重複可以跨這兩份成立。
@Test func concatenatesRootAndLocationWindowsForTheLabelList() {
    let config = obj([
        ("windows", windowList([.string("A")])),
        ("home", locationWith(profile: "P", okProfile, windows: windowList([.string("A")]))),
    ])
    #expect(LayoutValidator.validate(config)
        == [.structural("home.P：windows 的 label 重複（A）")])
}

/// 空陣列在 jq 是 truthy（只有 null 與 false 才落到 `//` 的右邊），所以
/// `"windows": []` 是「這個 profile 沒有任何視窗」而不是「沿用繼承的」。
@Test func anEmptyProfileWindowsArrayReplacesTheInheritedOnes() {
    let config = withSentinel(locationWith(
        profile: "P",
        obj([("trees", .object([])), ("windows", .array([]))]),
        windows: windowList([.string("A"), .string("A")])
    ))
    #expect(LayoutValidator.validate(config) == [sentinelProblem])
}

/// null 才落到 `//` 的右邊——與上面那條是一組對照。
@Test func aNullProfileWindowsFallsBackToTheInheritedOnes() {
    let config = withSentinel(locationWith(
        profile: "P",
        obj([("trees", .object([])), ("windows", .null)]),
        windows: windowList([.string("A"), .string("A")])
    ))
    #expect(LayoutValidator.validate(config)
        == [.structural("aaa.P：windows 的 label 重複（A）"), sentinelProblem])
}

/// 最外層的 windows 對**每個**地點都生效，所以哨兵自己也會中同一條。
@Test func theRootWindowsAppliesToEveryLocation() {
    let config = obj([
        ("windows", windowList([.string("A"), .string("A")])),
        ("aaa", obj([("desc", .string("x")),
                     ("displays", obj([("main", .string("M"))])),
                     ("profiles", obj([("P", okProfile)]))])),
        ("z z", healthyLocation()),
    ])
    #expect(LayoutValidator.validate(config) == [
        .structural("aaa.P：windows 的 label 重複（A）"),
        sentinelProblem,
        .structural("z z.P：windows 的 label 重複（A）"),
    ])
}

/// `+` 對兩個**物件**是合併而不是報錯，而 `map` 對物件是走過它的值——所以
/// windows 寫成物件時這條檢查照樣成立。實測 bash 會吐出重複那條。
@Test func mergesObjectWindowsFromRootAndLocation() {
    let config = withSentinel(
        obj([("desc", .string("x")),
             ("displays", obj([("main", .string("M"))])),
             ("windows", obj([("b", obj([("label", .string("A"))]))])),
             ("profiles", obj([("P", okProfile)]))]),
        extraTop: [("windows", obj([("a", obj([("label", .string("A"))]))]))]
    )
    #expect(LayoutValidator.validate(config)
        == [.structural("aaa.P：windows 的 label 重複（A）"), sentinelProblem])
}

// MARK: - 這一段的中止點（每個都用哨兵驗過）

/// `($lv.profiles // {}) | to_entries` 對字串／數字／布林都 runtime error
/// （`... has no keys`），整個串流當場結束。上面的 aStringProfilesIsNotReportedAsEmpty
/// 分不出這件事——它只有一個地點，中止與不觸發的輸出相同。
@Test func aNonIterableProfilesStopsTheWholePass() {
    for bad in [JSONValue.string("abc"), .number("5"), .bool(true)] {
        let config = withSentinel(obj([("desc", .string("x")),
                                       ("displays", obj([("main", .string("M"))])),
                                       ("windows", .array([])),
                                       ("profiles", bad)]))
        #expect(LayoutValidator.validate(config).isEmpty, "profiles=\(bad) 應該中止整個串流")
    }
}

/// **陣列是例外**：`to_entries` 對陣列是合法的（key 變成索引數字），所以它走得進
/// 迴圈，然後死在 `$p | test("\\s")`——`number (0) cannot be matched`。
/// 中止點不同，結果一樣。
@Test func aNonEmptyArrayProfilesStopsThePassAtTheWhitespaceTest() {
    let config = withSentinel(obj([("desc", .string("x")),
                                   ("displays", obj([("main", .string("M"))])),
                                   ("windows", .array([])),
                                   ("profiles", .array([.number("1"), .number("2")]))]))
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 空陣列的 `to_entries` 是 `[]`，迴圈一次都不跑，串流照常往下——而且 `length == 0`
/// 成立，所以照報「profiles 不存在或是空的」。與上面那條是一組對照。
@Test func anEmptyArrayProfilesIsReportedAsEmptyWithoutStopping() {
    let config = withSentinel(obj([("desc", .string("x")),
                                   ("displays", obj([("main", .string("M"))])),
                                   ("windows", .array([])),
                                   ("profiles", .array([]))]))
    #expect(LayoutValidator.validate(config)
        == [.structural("aaa：profiles 不存在或是空的"), sentinelProblem])
}

/// profile 的值是 null 時 `has("trees")` 回 **false**（不是報錯），所以照報「缺 trees」
/// 且不中止。`null.windows` 也是 null，會落到繼承的那份。
@Test func aNullProfileValueReportsMissingTrees() {
    let config = withSentinel(locationWith(profile: "P", .null))
    #expect(LayoutValidator.validate(config)
        == [.structural("aaa.P：缺 trees"), sentinelProblem])
}

/// 其他非物件的 profile 值都死在 `has("trees")`
/// （`Cannot check whether string has a string key`）——與 null 那條是一組對照。
@Test func aNonObjectProfileValueStopsTheWholePass() {
    for bad in [JSONValue.string("s"), .number("5"), .array([]), .bool(true)] {
        let config = withSentinel(locationWith(profile: "P", bad))
        #expect(LayoutValidator.validate(config).isEmpty, "profile 值 \(bad) 應該中止整個串流")
    }
}

/// `map(.label)` 對非物件元素 runtime error（`Cannot index string with string`）。
@Test func aNonObjectWindowsElementStopsTheWholePass() {
    for bad in [JSONValue.string("oops"), .number("7"), .array([]), .bool(true)] {
        let config = withSentinel(locationWith(profile: "P", okProfile,
                                               windows: .array([obj([("label", .string("A"))]), bad])))
        #expect(LayoutValidator.validate(config).isEmpty, "windows 元素 \(bad) 應該中止整個串流")
    }
}

/// **null 元素是例外**：`null.label` 在 jq 是合法的，回 null。
@Test func aNullWindowsElementIsAllowed() {
    let config = withSentinel(locationWith(profile: "P", okProfile,
                                           windows: .array([obj([("label", .string("A"))]), .null])))
    #expect(LayoutValidator.validate(config) == [sentinelProblem])
}

/// windows 本身不是可迭代的東西時，`map` 就報錯。
@Test func aNonIterableWindowsStopsTheWholePass() {
    let config = withSentinel(locationWith(
        profile: "P",
        obj([("trees", .object([])), ("windows", .string("s"))])
    ))
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 兩個元素都沒有 label 時，`map(.label)` 得到 `[null, null]`——那是**重複**，
/// 而 `join` 對 null 產生空字串，所以訊息的括號裡什麼都沒有。實測 bash 就是這樣印的。
@Test func treatsMissingLabelsAsDuplicateNulls() {
    let config = withSentinel(locationWith(profile: "P", okProfile,
                                           windows: .array([.object([]), .object([])])))
    #expect(LayoutValidator.validate(config)
        == [.structural("aaa.P：windows 的 label 重複（）"), sentinelProblem])
}

/// label 是數字時 `unique` 與 `join` 都不報錯——`join` 印的是 jq 保留的**字面值**，
/// 所以 `1.50` 不會變成 `1.5`。這一條同時釘住「label 非字串不會中止」。
@Test func reportsDuplicateNumericLabelsWithTheirLiteral() {
    let config = withSentinel(locationWith(profile: "P", okProfile,
                                           windows: windowList([.number("1.50"), .number("1.50")])))
    #expect(LayoutValidator.validate(config)
        == [.structural("aaa.P：windows 的 label 重複（1.50）"), sentinelProblem])
}

/// label 是**相異**的物件時 `unique` 分得出來，重複不成立，`join` 根本沒被求值
/// ——所以不中止。與下面那條是一組對照。
@Test func distinctObjectLabelsAreNotReported() {
    let config = withSentinel(locationWith(
        profile: "P", okProfile,
        windows: windowList([.object([]), obj([("a", .number("1"))])])
    ))
    #expect(LayoutValidator.validate(config) == [sentinelProblem])
}

/// label 是**相同**的物件時重複成立，這時才輪到 `join` 求值，而它加不動物件
/// （`string ("") and object ({}) cannot be added`）——整個串流結束。
@Test func duplicateObjectLabelsStopTheWholePass() {
    let config = withSentinel(locationWith(profile: "P", okProfile,
                                           windows: windowList([.object([]), .object([])])))
    #expect(LayoutValidator.validate(config).isEmpty)
}
