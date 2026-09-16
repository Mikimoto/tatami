import Testing
@testable import WorkmodeDomain

// 螢幕與 space 的四支純函式。斷言分兩類：
//   1. tests/test_workmode.sh 既有的 18 條（每條都標了它翻譯自哪一行）
//   2. 2026-08-14 拿 jq 1.8.2 對 scripts/workmode.sh 實跑挖出來的邊界
// 第 2 類不是湊數——`first` 會短路、`// empty` 吃掉 null 與 false、`@tsv` 會把
// 分隔字元轉義掉、空的 main 會因為左右補空白而命中空的 connected，這些從程式碼
// 一條都讀不出來。

// MARK: - visible_space_on / other_space_on 的語料

/// 與 tests/test_workmode.sh 的 SPACES 相同。每個螢幕的可見 space 刻意都不是它的
/// 第一個：否則「取可見的那個」與「取第一個」這兩種實作分不出來。
/// display 3 全部不可見，display 4 只有一個 space。
private func space(index: Int, display: Int, visible: Bool) -> JSONValue {
    obj([("index", num(String(index))),
         ("display", num(String(display))),
         ("is-visible", .bool(visible))])
}

private let spaces = JSONValue.array([
    space(index: 1, display: 1, visible: false),
    space(index: 2, display: 1, visible: true),
    space(index: 3, display: 2, visible: false),
    space(index: 4, display: 2, visible: true),
    space(index: 5, display: 3, visible: false),
    space(index: 6, display: 4, visible: true),
])

// MARK: - visible_space_on（test_workmode.sh:38-40）

@Test func takesTheVisibleSpaceNotTheFirstOneOnThatDisplay() throws {
    #expect(try Displays.visibleSpace(on: num("1"), in: spaces) == num("2"))
}

@Test func theVisibleSpaceIsPerDisplayNotGlobalOrder() throws {
    #expect(try Displays.visibleSpace(on: num("2"), in: spaces) == num("4"))
}

@Test func noVisibleSpaceOnThatDisplayGivesNothing() throws {
    #expect(try Displays.visibleSpace(on: num("3"), in: spaces) == nil)
}

// MARK: - visible_space_on 的邊界（實測）

@Test func takesTheFirstOfSeveralVisibleSpaces() throws {
    let many = JSONValue.array([space(index: 8, display: 1, visible: true),
                                space(index: 9, display: 1, visible: true)])
    #expect(try Displays.visibleSpace(on: num("1"), in: many) == num("8"))
}

/// jq 的 `==` 比的是數值不是字面值，所以 `1.0` 認得出 display 1。
@Test func theDisplayNumberIsComparedNumericallyNotLiterally() throws {
    #expect(try Displays.visibleSpace(on: num("1.0"), in: spaces) == num("2"))
}

/// 反過來，型別不同就不相等——`"1"` 是字串，永遠配不上數字的 display。
@Test func aStringDisplayNeverEqualsANumericOne() throws {
    #expect(try Displays.visibleSpace(on: .string("1"), in: spaces) == nil)
}

/// `."is-visible" == true` 要的是布林 true，字串 "true" 與缺欄位都不算。
@Test func isVisibleMustBeTheBooleanTrue() throws {
    let stringy = JSONValue.array([obj([("index", num("9")), ("display", num("1")),
                                        ("is-visible", .string("true"))])])
    #expect(try Displays.visibleSpace(on: num("1"), in: stringy) == nil)

    let missing = JSONValue.array([obj([("index", num("9")), ("display", num("1"))])])
    #expect(try Displays.visibleSpace(on: num("1"), in: missing) == nil)
}

/// `first(...) // empty` 的假值只有 null 與 false，所以 index 是這兩者就沒有輸出；
/// 而 `0` 是真值，會照樣印出來。
@Test func aNullOrFalseIndexCollapsesToNothingButZeroSurvives() throws {
    for dead in [JSONValue.null, .bool(false)] {
        let one = JSONValue.array([obj([("index", dead), ("display", num("1")),
                                        ("is-visible", .bool(true))])])
        #expect(try Displays.visibleSpace(on: num("1"), in: one) == nil)
    }
    let zero = JSONValue.array([obj([("index", num("0")), ("display", num("1")),
                                     ("is-visible", .bool(true))])])
    #expect(try Displays.visibleSpace(on: num("1"), in: zero) == num("0"))
}

@Test func aNonObjectElementIsARuntimeError() throws {
    #expect(throws: DisplaysError.runtime) {
        try Displays.visibleSpace(on: num("1"), in: .array([num("5")]))
    }
    // 根是物件時 `.[]` 走的是它的值，於是同樣撞上「數字不能用字串索引」。
    #expect(throws: DisplaysError.runtime) {
        try Displays.visibleSpace(on: num("1"), in: obj([("index", num("2"))]))
    }
}

/// jq 的 `first(f)` 命中就 break，後面那顆壞掉的元素根本沒被求值。
/// 反過來，壞元素排在命中之前就會炸——兩個方向都要釘。
@Test func firstShortCircuitsBeforeALaterBadElement() throws {
    let good = space(index: 1, display: 1, visible: true)
    #expect(try Displays.visibleSpace(on: num("1"),
                                      in: .array([good, num("5")])) == num("1"))
    #expect(throws: DisplaysError.runtime) {
        try Displays.visibleSpace(on: num("1"), in: .array([num("5"), good]))
    }
}

// MARK: - other_space_on（test_workmode.sh:41-43）

@Test func theExileIsAnotherSpaceOnTheSameDisplay() throws {
    #expect(try Displays.otherSpace(on: num("1"), in: spaces, skipping: num("2")) == num("1"))
}

@Test func theExileIsOnlyLookedForOnTheSameDisplay() throws {
    #expect(try Displays.otherSpace(on: num("2"), in: spaces, skipping: num("4")) == num("3"))
}

@Test func thereIsNoExileWhenTheDisplayHasASingleSpace() throws {
    #expect(try Displays.otherSpace(on: num("4"), in: spaces, skipping: num("6")) == nil)
}

// MARK: - other_space_on 的邊界（實測）

/// `.index != $s` 一樣是數值比較：`1.0` 真的會跳過 index 1。
@Test func theSkippedIndexIsComparedNumerically() throws {
    #expect(try Displays.otherSpace(on: num("1"), in: spaces, skipping: num("1.0")) == num("2"))
}

/// 型別不同就「不相等」，於是字串 `"1"` 什麼都跳不掉。
@Test func aStringSkipNeverEqualsANumericIndex() throws {
    #expect(try Displays.otherSpace(on: num("1"), in: spaces, skipping: .string("1")) == num("1"))
}

@Test func aNullIndexCollapsesToNothingInTheExileLookupToo() throws {
    let dead = JSONValue.array([obj([("index", .null), ("display", num("1"))])])
    #expect(try Displays.otherSpace(on: num("1"), in: dead, skipping: num("9")) == nil)
}

@Test func firstShortCircuitsInTheExileLookupToo() throws {
    let good = obj([("index", num("1")), ("display", num("1"))])
    #expect(try Displays.otherSpace(on: num("1"), in: .array([good, .string("bad")]),
                                    skipping: num("9")) == num("1"))
    #expect(throws: DisplaysError.runtime) {
        try Displays.otherSpace(on: num("1"), in: .array([.string("bad"), good]),
                                skipping: num("9"))
    }
}
