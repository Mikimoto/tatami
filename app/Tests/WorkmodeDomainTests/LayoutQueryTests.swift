import Testing
@testable import WorkmodeDomain

// 用 JSONValue 直接建設定，不經 parser——這一層是純規則，不該依賴解析。
// 一條視窗規則。`trees` 在這六支函式裡從頭到尾沒被讀過，所以 fixture 只帶
// 它們真的會走到的欄位，用空物件占位——把整棵樹抄進來只會讓語料變難讀，
// 不會多驗到任何東西。

// MARK: - location_desc（tests/test_workmode.sh:94、98）

/// 對照 `assert_eq "$(location_desc office "$GOOD_JSON")" "A+B"`。
@Test func locationDescriptionReadsTheHumanLabel() throws {
    #expect(try LayoutQuery.locationDescription("office", in: goodJSON) == .string("A+B"))
}

/// 對照 `assert_eq "$(location_desc nosuch "$GOOD_JSON")" ""`。
///
/// nil 是 jq 的 `empty`——**零位元組**，不是空行。與下面那條空字串的是兩種輸出，
/// 命令替換會把兩者都吃成空字串，只有逐位元組比對分得出來（實測：缺欄位是 0 個
/// 位元組，`"desc":""` 是 `0a`）。
@Test func anUnknownLocationHasNoDescription() throws {
    #expect(try LayoutQuery.locationDescription("nosuch", in: goodJSON) == nil)
}

/// 空字串是 jq 的真值，所以 `// empty` 不接手——它會被印成一個空行。
@Test func anEmptyStringDescriptionIsNotTheSameAsNoDescription() throws {
    let config = obj([("h", obj([("desc", .string(""))]))])
    #expect(try LayoutQuery.locationDescription("h", in: config) == .string(""))
}

/// `//` 對 **false** 也接手，不只 null 與不存在。
@Test func aFalseDescriptionIsTreatedAsAbsent() throws {
    let config = obj([("h", obj([("desc", .bool(false))]))])
    #expect(try LayoutQuery.locationDescription("h", in: config) == nil)
}

/// 但 `0` 是 jq 的真值——實測 bash 印出 `0`。照 C 的直覺當成假就錯了。
@Test func zeroIsTruthySoTheDescriptionSurvives() throws {
    let config = obj([("h", obj([("desc", .number("0"))]))])
    #expect(try LayoutQuery.locationDescription("h", in: config) == .number("0"))
}

/// 容器原樣回來，格式化是呼叫端的事（`jq -r` 對容器印的是縮排格式）。
@Test func aContainerDescriptionComesBackAsIs() throws {
    let inner = obj([("a", .number("1"))])
    let config = obj([("h", obj([("desc", inner)]))])
    #expect(try LayoutQuery.locationDescription("h", in: config) == inner)
}

/// `null | .desc` 在 jq 是 null 而不是錯，所以整份設定是 null 時不報錯。
@Test func aNullRootIndexesToNullRatherThanFailing() throws {
    #expect(try LayoutQuery.locationDescription("h", in: .null) == nil)
}

/// `5 | .desc` 是 "Cannot index number with string"——jq 的 runtime error，rc=5。
@Test func indexingIntoANonObjectLocationIsARuntimeError() {
    let config = obj([("h", .number("5"))])
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.locationDescription("h", in: config)
    }
}

/// 陣列也不能用字串索引（"Cannot index array with string"）。
@Test func indexingAnArrayRootWithALocationNameIsARuntimeError() {
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.locationDescription("h", in: .array([.number("1")]))
    }
}

// MARK: - location_display（tests/test_workmode.sh:95-97）

/// 對照 `assert_eq "$(location_display office main "$GOOD_JSON")" "AAAA-MAIN"`。
@Test func locationDisplayReadsTheMainScreenUUID() throws {
    #expect(try LayoutQuery.locationDisplay("office", role: "main", in: goodJSON)
        == .string("AAAA-MAIN"))
}

/// 對照 `assert_eq "$(location_display office second "$GOOD_JSON")" "AAAA-CHAT"`。
@Test func locationDisplayReadsTheSecondScreenUUID() throws {
    #expect(try LayoutQuery.locationDisplay("office", role: "second", in: goodJSON)
        == .string("AAAA-CHAT"))
}

/// 對照 `assert_eq "$(location_display office third "$GOOD_JSON")" ""`。
@Test func anUndefinedScreenRoleYieldsNothing() throws {
    #expect(try LayoutQuery.locationDisplay("office", role: "third", in: goodJSON) == nil)
}

/// displays 整個不存在也是 null 索引，不是錯。
@Test func aMissingDisplaysMapYieldsNothing() throws {
    let config = obj([("h", obj([("desc", .string("x"))]))])
    #expect(try LayoutQuery.locationDisplay("h", role: "main", in: config) == nil)
}

/// displays 是別的型別才報錯（實測 `false["m"]` → "Cannot index boolean"）。
@Test func aNonObjectDisplaysMapIsARuntimeError() {
    let config = obj([("h", obj([("displays", .bool(false))]))])
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.locationDisplay("h", role: "m", in: config)
    }
}

// MARK: - location_names_from（tests/test_workmode.sh:99、376）

/// 對照 `assert_eq "$(location_names_from "$GOOD_JSON")" "office home"`——
/// 維持來源鍵序，不排序（jq 是 `keys_unsorted`）。
@Test func locationNamesKeepTheFileOrder() throws {
    #expect(try LayoutQuery.locationNames(in: goodJSON) == "office home")
}

/// 對照 `assert_eq "$(location_names_from "$SHARED_JSON")" "home"`——
/// 最外層的 `windows` 是共用視窗總表，不是地點。
@Test func theReservedWindowsKeyIsNotALocation() throws {
    #expect(try LayoutQuery.locationNames(in: sharedJSON) == "home")
}

/// 保留字過濾打的是**字串** "windows"，不是位置——它出現在中間一樣要濾掉。
@Test func theReservedKeyIsFilteredWhereverItAppears() throws {
    let config = obj([("a", .object([])), ("windows", .array([])), ("b", .object([]))])
    #expect(try LayoutQuery.locationNames(in: config) == "a b")
}

/// 空物件 join 出空字串（印出來是一個空行，不是零位元組）。
@Test func anEmptyConfigHasNoLocationNames() throws {
    #expect(try LayoutQuery.locationNames(in: .object([])) == "")
}

/// jq 的 `keys_unsorted` 對陣列回的是**索引**，於是 join 出 "0 1 2"。
/// 這不是設計，是把陣列餵進來時 bash 真的會印的東西。
@Test func anArrayRootYieldsItsIndicesAsLocationNames() throws {
    #expect(try LayoutQuery.locationNames(in: .array([.number("1"), .number("2"),
                                                      .number("3")])) == "0 1 2")
}

/// 純量沒有 keys（jq: "null (null) has no keys"），rc=5。
@Test func aScalarRootHasNoKeys() {
    #expect(throws: LayoutQueryError.runtime) { try LayoutQuery.locationNames(in: .null) }
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.locationNames(in: .string("hi"))
    }
}

// MARK: - profile_names_in（tests/test_workmode.sh:183、191）

/// 對照 `assert_eq "$(profile_names_in home "$L2_JSON")" "開發 會議"`。
@Test func profileNamesKeepTheFileOrder() throws {
    #expect(try LayoutQuery.profileNames(inLocation: "home", in: l2JSON) == "開發 會議")
}

/// 對照 `PNI_OUT=$(profile_names_in nosuch "$L2_JSON"); PNI_RC=$?` → `[] rc=0`。
/// 空輸出**與不報錯**是兩件事，兩件都要驗：函式不存在時 `$(...)` 也是空字串。
@Test func anUnknownLocationHasNoProfilesAndNoError() throws {
    #expect(try LayoutQuery.profileNames(inLocation: "nosuch", in: l2JSON) == "")
}

/// `.profiles` 不存在 → `// {}` 接手。
@Test func aLocationWithoutProfilesYieldsAnEmptyList() throws {
    let config = obj([("h", obj([("desc", .string("x"))]))])
    #expect(try LayoutQuery.profileNames(inLocation: "h", in: config) == "")
}

/// `// {}` 對 **false** 也接手——這是 `//` 與「只擋 null」的差別。
@Test func profilesSetToFalseFallsBackToTheEmptyObject() throws {
    let config = obj([("h", obj([("profiles", .bool(false))]))])
    #expect(try LayoutQuery.profileNames(inLocation: "h", in: config) == "")
}

/// profiles 是陣列時 `keys_unsorted` 回索引，不是錯。
@Test func profilesAsAnArrayYieldsItsIndices() throws {
    let config = obj([("h", obj([("profiles", .array([.number("10"), .number("20")]))]))])
    #expect(try LayoutQuery.profileNames(inLocation: "h", in: config) == "0 1")
}

/// 但字串是真值又沒有 keys → rc=5。
@Test func profilesAsAStringIsARuntimeError() {
    let config = obj([("h", obj([("profiles", .string("x"))]))])
    #expect(throws: LayoutQueryError.runtime) {
        try LayoutQuery.profileNames(inLocation: "h", in: config)
    }
}

/// 整份設定是 null 時 `null.h.profiles` 一路是 null，`// {}` 接手，不報錯。
@Test func aNullRootHasNoProfilesAndNoError() throws {
    #expect(try LayoutQuery.profileNames(inLocation: "h", in: .null) == "")
}
