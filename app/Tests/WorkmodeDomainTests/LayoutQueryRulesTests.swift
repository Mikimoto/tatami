import Testing
@testable import WorkmodeDomain

// `exile_for` 與 `windows_for`：從設定取出「這個 profile 要放逐哪些角色」與「生效的
// 規則清單」。與另外四支查詢分開，因為只有這兩支要處理**繼承**——地點層與 profile
// 層各有一份，合併規則是這兩支的全部內容，而前四支都是單層查一個值。
//
// 共用的設定在 LayoutQueryFixtures.swift。

// MARK: - exile_for（tests/test_workmode.sh:180-181）

/// 對照 `assert_eq "$(exile_for home 開發 "$L2_JSON")" "main"`——profile 沒寫就沿用地點層。
@Test func exileInheritsFromTheLocationLayer() throws {
    #expect(try LayoutQuery.exile(location: "home", profile: "開發", in: l2JSON) == "main")
}

/// 對照 `assert_eq "$(exile_for home 會議 "$L2_JSON")" "main second"`——profile 寫了就取代。
@Test func exileIsReplacedByTheProfile() throws {
    #expect(try LayoutQuery.exile(location: "home", profile: "會議", in: l2JSON)
        == "main second")
}

/// profile 不存在時退回地點層——與 windows_for 同一條規則。
@Test func anUnknownProfileFallsBackToTheLocationExile() throws {
    #expect(try LayoutQuery.exile(location: "home", profile: "nosuch", in: l2JSON) == "main")
}

/// 地點不存在時兩層都是 null，`// []` 收尾，不報錯。
@Test func anUnknownLocationHasNoExileAndNoError() throws {
    #expect(try LayoutQuery.exile(location: "nosuch", profile: "開發", in: l2JSON) == "")
}

/// **空陣列是真值**，所以它真的取代地點層而不是被 `//` 跳過——
/// 這是「profile 想清場什麼都不做」唯一寫得出來的方式。
@Test func anEmptyExileListAtTheProfileLayerReplacesTheLocationLayer() throws {
    let config = obj([("h", obj([("exile", .array([.string("main")])),
                                 ("profiles", obj([("P", obj([("exile", .array([]))]))]))]))])
    #expect(try LayoutQuery.exile(location: "h", profile: "P", in: config) == "")
}

/// 但 false 會被 `//` 跳過，於是退回地點層——與空陣列相反。
@Test func aFalseExileAtTheProfileLayerFallsThrough() throws {
    let config = obj([("h", obj([("exile", .array([.string("main")])),
                                 ("profiles", obj([("P", obj([("exile", .bool(false))]))]))]))])
    #expect(try LayoutQuery.exile(location: "h", profile: "P", in: config) == "main")
}

/// jq 的 `join` 把 null 變成空字串、數字與布林變成字面值——所以中間會出現兩個空白。
@Test func exileJoinsNullAsAnEmptyField() throws {
    let config = obj([("h", obj([("exile", .array([.number("1"), .bool(true),
                                                   .null, .string("x")]))]))])
    #expect(try LayoutQuery.exile(location: "h", profile: "P", in: config) == "1 true  x")
}

/// 數字是逐字保留的字面值，不是重新格式化的數值（`2.50` 不會變 `2.5`）。
@Test func exileKeepsNumberLiteralsVerbatim() throws {
    let config = obj([("h", obj([("exile", .array([.number("2.50"), .number("-0.0")]))]))])
    #expect(try LayoutQuery.exile(location: "h", profile: "P", in: config) == "2.50 -0.0")
}

/// exile 是物件時 `join` 走的是它的**值**，不是報錯（實測 rc=0）。
@Test func exileOverAnObjectJoinsItsValues() throws {
    let config = obj([("h", obj([("exile", obj([("a", .string("x")), ("b", .string("y"))]))]))])
    #expect(try LayoutQuery.exile(location: "h", profile: "P", in: config) == "x y")
}

/// 但元素是容器就報錯（jq: `string ("") and object ({}) cannot be added`）。
@Test func aNestedContainerInsideExileIsARuntimeError() {
    let config = obj([("h", obj([("exile", .array([.array([.string("a")])]))]))])
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.exile(location: "h", profile: "P", in: config)
    }
}

/// exile 是純量（字串／數字／true）也報錯——`join` 只吃得下可迭代的東西。
@Test func aScalarExileIsARuntimeError() {
    for scalar: JSONValue in [.string("ab"), .number("5"), .bool(true)] {
        let config = obj([("h", obj([("exile", scalar)]))])
        #expect(throws: LayoutQueryError.runtime) {
            try LayoutQuery.exile(location: "h", profile: "P", in: config)
        }
    }
}

/// profiles 是陣列時用字串索引就報錯，地點層那份 exile 救不了它——
/// jq 不會因為右邊有 fallback 就吞掉左邊的例外。
@Test func theAlternativeOperatorDoesNotSwallowErrorsFromItsLeftSide() {
    let config = obj([("h", obj([("exile", .array([.string("main")])),
                                 ("profiles", .array([.number("1")]))]))])
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.exile(location: "h", profile: "P", in: config)
    }
}

// MARK: - windows_for（tests/test_workmode.sh:133-143、171-177）

/// 對照 `windows_for home 開發 "$L2_JSON" | cut -f1` → `A,B,C,M,`。
@Test func aProfileWithoutWindowsInheritsTheWholeLocationDictionary() throws {
    #expect(try labels("home", "開發", l2JSON)
        == [.string("A"), .string("B"), .string("C"), .string("M")])
}

/// 對照 `windows_for home 會議 "$L2_JSON" | cut -f1` → `M,`——整塊取代，不是合併。
@Test func aProfileWithWindowsReplacesTheWholeDictionary() throws {
    #expect(try labels("home", "會議", l2JSON) == [.string("M")])
}

/// 對照 `… | awk '$1=="C"' | cut -f4,5` → `title-regex\t甲|乙`。
@Test func theFallbackFieldsComeThrough() throws {
    let row = try #require(try collectRules("home", "開發", l2JSON)
        .first { $0.label == .string("C") })
    #expect(row.fallbackKind == .string("title-regex"))
    #expect(row.fallbackValue == .string("甲|乙"))
}

/// 對照 `… | head -1 | cut -f2,3` → `app\tAA`。
@Test func theMatchKindAndValueComeThrough() throws {
    let first = try #require(try collectRules("home", "開發", l2JSON).first)
    #expect(first.matchKind == .string("app"))
    #expect(first.matchValue == .string("AA"))
}

/// 對照 `windows_for home nosuch "$L2_JSON" | cut -f1` → `A,B,C,M,`。
@Test func anUnknownProfileFallsBackToTheLocationLayer() throws {
    #expect(try labels("home", "nosuch", l2JSON)
        == [.string("A"), .string("B"), .string("C"), .string("M")])
}

/// 對照 `assert_eq "$(windows_for nosuch 開發 "$L2_JSON"; echo "rc=$?")" "rc=0"`——
/// 零行輸出**而且**不報錯。這條比的是 exit code，所以「不 throw」才是重點。
@Test func anUnknownLocationYieldsNoRowsAndNoError() throws {
    #expect(try labels("nosuch", "開發", l2JSON).isEmpty)
}

/// 對照 `windows_for home 開發 "$SHARED_JSON" | cut -f1` → `S1,S2,L1,`——
/// 共用總表在前，地點層接在後面（不是取代）。
@Test func theSharedTableComesFirstThenTheLocationLayer() throws {
    #expect(try labels("home", "開發", sharedJSON)
        == [.string("S1"), .string("S2"), .string("L1")])
}

/// 對照 `windows_for home 會議 "$SHARED_JSON" | cut -f1` → `M,`——
/// profile 層的取代連最外層的共用總表一起蓋掉。
@Test func aProfileWindowsListAlsoShadowsTheSharedTable() throws {
    #expect(try labels("home", "會議", sharedJSON) == [.string("M")])
}

/// 對照 `… | awk '$1=="S2"' | cut -f4,5` → `title-regex\t丙|丁`。
@Test func theSharedLayerFallbackAlsoComesThrough() throws {
    let row = try #require(try collectRules("home", "開發", sharedJSON)
        .first { $0.label == .string("S2") })
    #expect(row.fallbackKind == .string("title-regex"))
    #expect(row.fallbackValue == .string("丙|丁"))
}

/// 對照 `windows_for home 開發 "$NO_LOCAL_JSON" | cut -f1` → `S1,S2,`。
@Test func withoutALocationLayerOnlyTheSharedTableRemains() throws {
    #expect(try labels("home", "開發", noLocalJSON) == [.string("S1"), .string("S2")])
}

/// 缺 fallback 的欄位填 `-`，讓 read 的欄位數固定。
@Test func aMissingFallbackBecomesTheDashPlaceholder() throws {
    let first = try #require(try collectRules("home", "開發", l2JSON).first)
    #expect(first.fallbackKind == .string("-"))
    #expect(first.fallbackValue == .string("-"))
}

/// fallback 只有一個元素時，第二欄才補 `-`。
@Test func aOneElementFallbackOnlyPadsTheSecondField() throws {
    let entry = obj([("label", .string("L")),
                     ("match", .array([.string("a"), .string("b")])),
                     ("fallback", .array([.string("t")]))])
    let config = obj([("h", obj([("windows", .array([entry]))]))])
    let row = try #require(try collectRules("h", "P", config).first)
    #expect(row.fallbackKind == .string("t"))
    #expect(row.fallbackValue == .string("-"))
}

/// **空字串是真值**，所以它不會被 `// "-"` 換掉——輸出是兩個空欄位。
@Test func anEmptyStringFallbackSurvivesThePlaceholder() throws {
    let entry = obj([("label", .string("L")),
                     ("match", .array([.string("a"), .string("b")])),
                     ("fallback", .array([.string(""), .string("")]))])
    let config = obj([("h", obj([("windows", .array([entry]))]))])
    let row = try #require(try collectRules("h", "P", config).first)
    #expect(row.fallbackKind == .string(""))
    #expect(row.fallbackValue == .string(""))
}

/// false 會被換掉、`0` 不會——同一個 `//` 的兩種下場。
@Test func falseFallsBackToTheDashButZeroDoesNot() throws {
    let entry = obj([("label", .string("L")),
                     ("match", .array([.string("a"), .string("b")])),
                     ("fallback", .array([.bool(false), .number("0")]))])
    let config = obj([("h", obj([("windows", .array([entry]))]))])
    let row = try #require(try collectRules("h", "P", config).first)
    #expect(row.fallbackKind == .string("-"))
    #expect(row.fallbackValue == .number("0"))
}

/// label 不存在就是 null（@tsv 印成空欄位），不是錯。
@Test func aMissingLabelBecomesNull() throws {
    let entry = obj([("match", .array([.string("a"), .string("b")]))])
    let config = obj([("h", obj([("windows", .array([entry]))]))])
    let row = try #require(try collectRules("h", "P", config).first)
    #expect(row.label == .null)
}

/// match 不存在時 `null[0]` 還是 null——兩個欄位都空，仍然出一行。
@Test func aMissingMatchYieldsTwoNullFields() throws {
    let config = obj([("h", obj([("windows", .array([obj([("label", .string("L"))])]))]))])
    let row = try #require(try collectRules("h", "P", config).first)
    #expect(row.matchKind == .null)
    #expect(row.matchValue == .null)
}

/// 元素本身是 null 時整行都是 null（fallback 兩欄補 `-`），照樣出一行。
@Test func aNullEntryStillProducesARow() throws {
    let config = obj([("h", obj([("windows", .array([.null]))]))])
    let row = try #require(try collectRules("h", "P", config).first)
    #expect(row.label == .null)
    #expect(row.matchKind == .null)
    #expect(row.fallbackKind == .string("-"))
}

/// 空清單就是零行——與 exile 的空清單不同，那邊會印一個空行。
@Test func anEmptyWindowsListAtTheProfileLayerEmitsNothing() throws {
    let config = obj([("windows", .array([rule("S", "app", "SA")])),
                      ("h", obj([("profiles", obj([("P", obj([("windows", .array([]))]))]))]))])
    #expect(try labels("h", "P", config).isEmpty)
}

/// false 則被 `//` 跳過，退回「共用層 + 地點層」。
@Test func windowsSetToFalseAtTheProfileLayerFallsThrough() throws {
    let config = obj([("windows", .array([rule("S", "app", "SA")])),
                      ("h", obj([("profiles",
                                  obj([("P", obj([("windows", .bool(false))]))]))]))])
    #expect(try labels("h", "P", config) == [.string("S")])
}

/// 共用層是 false 時只剩地點層——兩層各自套用 `// []`。
@Test func aFalseSharedTableLeavesOnlyTheLocationLayer() throws {
    let config = obj([("windows", .bool(false)),
                      ("h", obj([("windows", .array([rule("L", "app", "LA")]))]))])
    #expect(try labels("h", "P", config) == [.string("L")])
}

/// windows 是物件時 `.[]` 走的是它的值——不是錯，實測會出一行。
@Test func aWindowsObjectIteratesItsValues() throws {
    let config = obj([("h", obj([("profiles", obj([("P", obj([("windows",
                                                               obj([("k", rule("L", "app", "LA"))]))]))]))]))])
    #expect(try labels("h", "P", config) == [.string("L")])
}

/// 兩層都是物件時 jq 的 `+` 是**合併**：左邊的鍵序保留，右邊同名的值蓋過去。
/// 這條看起來很偏，但它是 `+` 與「只接受陣列」的分水嶺——實測 rc=0 出兩行。
@Test func twoObjectLayersMergeWithTheRightHandValueWinning() throws {
    let config = obj([("windows", obj([("k", rule("S", "app", "SA"))])),
                      ("h", obj([("windows", obj([("j", rule("L", "app", "LA"))]))]))])
    #expect(try labels("h", "P", config) == [.string("S"), .string("L")])

    let clashing = obj([("windows", obj([("k", rule("S", "app", "SA"))])),
                        ("h", obj([("windows", obj([("k", rule("L", "app", "LA"))]))]))])
    #expect(try labels("h", "P", clashing) == [.string("L")])
}

/// 型別不一致的兩層加不起來（jq: `array ([]) and object ({}) cannot be added`）。
@Test func mixingAnArrayLayerWithAnObjectLayerIsARuntimeError() {
    let config = obj([("windows", .array([])),
                      ("h", obj([("windows", obj([("k", .number("1"))]))]))])
    #expect(throws: LayoutQueryError.runtime) { try labels("h", "P", config) }
}

/// match 是字串時 `"ab"[0]` 報錯——rc=5，而且**這一行之前印出去的不會收回**。
@Test func rowsEmittedBeforeARuntimeErrorAreKept() throws {
    let broken = obj([("label", .string("X")), ("match", .string("ab"))])
    let config = obj([("h", obj([("windows", .array([rule("A", "app", "AA"), broken]))]))])
    var seen: [JSONValue] = []
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.windowRules(location: "h", profile: "P", in: config) {
            seen.append($0.label)
        }
    }
    #expect(seen == [.string("A")])
}

/// 元素是純量（數字／布林／字串）就報錯——`.label` 索引不進去。
@Test func aScalarEntryIsARuntimeError() {
    for scalar: JSONValue in [.number("5"), .bool(true), .string("s")] {
        let config = obj([("h", obj([("windows", .array([scalar]))]))])
        #expect(throws: LayoutQueryError.runtime) { try labels("h", "P", config) }
    }
}

/// fallback 是字串／物件／數字都報錯——`[0]` 只索引得進陣列與 null。
@Test func aNonArrayFallbackIsARuntimeError() {
    for bad: JSONValue in [.string("xy"), obj([("a", .number("1"))]), .number("5")] {
        let entry = obj([("label", .string("L")),
                         ("match", .array([.string("a"), .string("b")])),
                         ("fallback", bad)])
        let config = obj([("h", obj([("windows", .array([entry]))]))])
        #expect(throws: LayoutQueryError.runtime) { try labels("h", "P", config) }
    }
}

/// profile 層的 windows 是純量時直接拿它去 `.[]`，報錯。
@Test func aScalarProfileWindowsIsARuntimeError() {
    let config = obj([("h", obj([("profiles",
                                  obj([("P", obj([("windows", .string("ab"))]))]))]))])
    #expect(throws: LayoutQueryError.runtime) { try labels("h", "P", config) }
}

/// 整份設定是 null 時兩層都收斂成空陣列，零行且不報錯。
@Test func aNullRootYieldsNoWindowRowsAndNoError() throws {
    #expect(try labels("h", "P", .null).isEmpty)
}

/// label 帶著 @tsv 要轉義的字元時，`windows_for` 這一層原樣帶過去——
/// 轉義發生在印出來的時候（`JQPrint.tsvEscape`），不在這條規則裡。
/// 「不在規則裡」只對這一支成立：`match_location` 回傳與比對的都是轉義後的文字，
/// 那裡的轉義**是**規則的一部分（見 `JQPrint` 的型別註解）。
@Test func labelsAreCarriedThroughWithoutEscaping() throws {
    let messy = "a\tb\nc"
    let entry = obj([("label", .string(messy)),
                     ("match", .array([.string("a"), .string("b")]))])
    let config = obj([("h", obj([("windows", .array([entry]))]))])
    #expect(try labels("h", "P", config) == [.string(messy)])
}
