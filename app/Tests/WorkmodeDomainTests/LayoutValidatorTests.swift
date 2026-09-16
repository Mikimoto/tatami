import Testing
@testable import WorkmodeDomain

// `validate_layout` 的地點層：缺欄位那段，與 workmode.sh:74-84 的五條結構檢查。
// fixture 在 LayoutValidatorFixtures.swift（profile 層與樹節點那兩個檔共用同一組）。
//
// 每則訊息都是 bash 實跑取得的，不是照 jq 原文抄的。

@Test func acceptsAMinimalValidConfig() {
    let config = obj([
        ("home", obj([("desc", .string("x")),
                      ("displays", obj([("main", .string("M"))])),
                      ("windows", .array([])),
                      ("profiles", okProfiles)])),
    ])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// displays **是物件但缺 main** 才報 displays.main。這裡刻意給空物件——
/// 「完全不存在」是另一種行為（見 aMissingDisplaysProducesNoError），
/// 兩者不能混用同一份 fixture。實測 bash：
///   displays 不存在   → 只吐 desc 那條
///   displays 是空物件 → 吐 home.displays.main
@Test func reportsMissingDescAndDisplaysMain() {
    let config = obj([("home", obj([("displays", .object([])),
                                    ("windows", .array([])),
                                    ("profiles", okProfiles)]))])
    let problems = LayoutValidator.validate(config)
    #expect(problems.contains(.missingField("home.desc（要非空字串）")))
    #expect(problems.contains(.missingField("home.displays.main")))
}

/// displays 完全不存在時，jq 的 `null | objects` 產生 empty，`if` 整條不輸出——
/// 所以**不報** displays.main。與上面那條是一組對照，缺一個就分不出
/// 「不存在」與「存在但缺 main」。
@Test func aMissingDisplaysProducesNoError() {
    let config = obj([("home", obj([("desc", .string("x")),
                                    ("windows", .array([])),
                                    ("profiles", okProfiles)]))])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// desc 是空字串也算缺——has("desc") 過得了，但下游拿「desc 非空」當地點存在的判準。
@Test func treatsEmptyDescAsMissing() {
    let config = obj([("home", obj([("desc", .string("")),
                                    ("displays", obj([("main", .string("M"))])),
                                    ("windows", .array([])),
                                    ("profiles", okProfiles)]))])
    #expect(LayoutValidator.validate(config).contains(.missingField("home.desc（要非空字串）")))
}

/// desc 不是字串（例如數字）也算缺。
@Test func treatsANonStringDescAsMissing() {
    let config = obj([("home", obj([("desc", .number("42")),
                                    ("displays", obj([("main", .string("M"))])),
                                    ("windows", .array([])),
                                    ("profiles", okProfiles)]))])
    #expect(LayoutValidator.validate(config).contains(.missingField("home.desc（要非空字串）")))
}

/// 最外層的 windows 是共用總表，不是地點，不得被當成地點驗。
@Test func skipsTheReservedTopLevelWindowsKey() {
    let config = obj([
        ("windows", .array([])),
        ("home", obj([("desc", .string("x")),
                      ("displays", obj([("main", .string("M"))])),
                      ("profiles", okProfiles)])),
    ])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 實測 jq：`if (.displays | objects | has("main")) then empty else … end` 在
/// displays 不是物件時整條產生 empty——**不走 else**。所以 displays 是字串的設定
/// 在這條檢查上不報錯。這不是合理設計，是要保留的既有行為。
@Test func aNonObjectDisplaysProducesNoMissingMainError() {
    let config = obj([("home", obj([("desc", .string("x")),
                                    ("displays", .string("不是物件")),
                                    ("windows", .array([])),
                                    ("profiles", okProfiles)]))])
    #expect(!LayoutValidator.validate(config).contains(.missingField("home.displays.main")))
}

/// 順序就是輸出順序：最外層依來源鍵序，地點內依 desc → displays.main → windows。
@Test func reportsProblemsInSourceOrder() {
    let broken = obj([("profiles", okProfiles)])
    let config = obj([("zzz", broken), ("aaa", broken)])
    #expect(LayoutValidator.validate(config) == [
        .missingField("zzz.desc（要非空字串）"),
        .missingField("zzz.windows"),
        .missingField("aaa.desc（要非空字串）"),
        .missingField("aaa.windows"),
    ])
}

// MARK: - 地點層的結構檢查（workmode.sh:74-84）

//
// 這一段只有在缺欄位那段完全沒問題時才跑，所以每個 fixture 都用 healthyLocation
// 起手，只疊上要違反的那一條——同時違反兩條的話 mutation 分不出是哪條在擋。
// 底下每一則訊息都是 bash 實跑取得的，不是照 jq 原文抄的：
//   bash -c 'source scripts/workmode.sh; validate_layout "<json>"'

@Test func reportsTreesAtTheLocationLevel() {
    let config = obj([("home", healthyLocation(extra: [("trees", .object([]))]))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home：trees 不能放在地點層，要搬進 profiles.<名稱>.trees")])
}

@Test func reportsAMissingProfiles() {
    let config = obj([("home", healthyLocation(profiles: nil))])
    #expect(LayoutValidator.validate(config) == [.structural("home：profiles 不存在或是空的")])
}

/// `profiles` 存在但是空物件，與完全不存在是同一則訊息——jq 用 `// {}` 把兩者合流。
@Test func reportsAnEmptyProfiles() {
    let config = obj([("home", healthyLocation(profiles: .object([])))])
    #expect(LayoutValidator.validate(config) == [.structural("home：profiles 不存在或是空的")])
}

/// 這條訊息**沒有**地點前綴，其他四條都有。實測 bash 如此，不要順手補上。
@Test func reportsALocationNamedAuto() {
    let config = obj([("auto", healthyLocation())])
    #expect(LayoutValidator.validate(config)
        == [.structural("地點不能叫 auto，那是 --switch 的保留字")])
}

@Test func reportsWhitespaceInALocationName() {
    let config = obj([("my home", healthyLocation())])
    #expect(LayoutValidator.validate(config) == [.structural("地點名稱「my home」不能含空白")])
}

/// jq 的 `test("\\s")` 認的是 Unicode 空白，不只半形空格——實測它對全形空白
/// U+3000 與 NBSP U+00A0 都 match。這裡刻意寫跳脫序列而不是真字元：真的全形空白
/// 在編輯器裡與半形難分，被誰改成半形也不會有人發現，測試就靜默退化成上一條。
@Test func treatsAnIdeographicSpaceAsWhitespace() {
    let name = "my\u{3000}home"
    let config = obj([(name, healthyLocation())])
    #expect(LayoutValidator.validate(config) == [.structural("地點名稱「\(name)」不能含空白")])
}

@Test func reportsADefaultThatIsNotAProfile() {
    let config = obj([("home", healthyLocation(extra: [("default", .string("Q"))]))])
    #expect(LayoutValidator.validate(config)
        == [.structural("home.default「Q」不是這個地點的 profile")])
}

/// default 指到存在的 profile 就不報。少了這條，「只要有 default 就報」也會全綠。
@Test func acceptsADefaultThatNamesAProfile() {
    let config = obj([("home", healthyLocation(extra: [("default", .string("P"))]))])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// bash 版是兩個獨立的 jq 呼叫：缺欄位那段有輸出就印完 `return 1`，結構那段
/// 根本不會執行。所以兩類問題不會同時出現在同一次回傳裡。
/// 這個 fixture 缺 desc，同時又違反 profiles 與空白兩條結構規則——實測 bash
/// 只吐 `! layout.json 缺欄位：a a.desc（要非空字串）`。
@Test func skipsStructuralChecksWhileAFieldIsMissing() {
    let config = obj([
        ("windows", .array([])),
        ("a a", obj([("displays", obj([("main", .string("M"))]))])),
    ])
    #expect(LayoutValidator.validate(config) == [.missingField("a a.desc（要非空字串）")])
}

/// 邊界：`profiles` 是字串。jq 的 `length` 對字串是字元數，`"abc"` 是 3，
/// 所以 `length == 0` 不成立、**不報**「不存在或是空的」。實測 bash exit 0。
///   $ echo '{"home":{"profiles":"abc"}}' | jq -r '.home.profiles // {} | length'
///   3
@Test func aStringProfilesIsNotReportedAsEmpty() {
    let config = obj([("home", healthyLocation(profiles: .string("abc")))])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 邊界：`default` 是數字。`has($d)` 只吃字串鍵，實測 jq 直接 runtime error
/// （`Cannot check whether object has a number key`，exit 5），整個串流當場中止
/// ——後面的地點一條都不會檢查。所以這裡的 aaa 不報，連 `z z` 的空白也被吞掉。
@Test func aNonStringDefaultStopsTheWholeStructuralPass() {
    let config = obj([
        ("aaa", healthyLocation(extra: [("default", .number("3"))])),
        ("z z", healthyLocation()),
    ])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 對照組：把 aaa 的 default 拿掉，`z z` 那條就報得出來。少了這條，
/// 「結構檢查整段沒實作」與「被 default 中止」外觀相同。
@Test func laterLocationsAreCheckedWhenNothingStopsThePass() {
    let config = obj([("aaa", healthyLocation()), ("z z", healthyLocation())])
    #expect(LayoutValidator.validate(config) == [.structural("地點名稱「z z」不能含空白")])
}

/// `default` 是 null（或 false）時 `// null` 讓它落回 null，該條直接跳過，
/// 而且**不**中止串流——與上面數字那條是一組對照。
@Test func aNullDefaultIsSkippedWithoutStoppingThePass() {
    let config = obj([
        ("aaa", healthyLocation(extra: [("default", .null)])),
        ("z z", healthyLocation()),
    ])
    #expect(LayoutValidator.validate(config) == [.structural("地點名稱「z z」不能含空白")])
}

/// `profiles` 是 `true` 的話 jq 連 `length` 都算不出來（`boolean (true) has no
/// length`），一樣中止整個串流。實測 bash exit 0，`z z` 的空白被吞掉。
@Test func aBooleanProfilesStopsTheWholeStructuralPass() {
    let config = obj([
        ("aaa", healthyLocation(profiles: .bool(true))),
        ("z z", healthyLocation()),
    ])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 同一地點內依宣告順序：trees → profiles → auto → 空白 → default。
/// （auto 與空白湊不到同一個名字上，所以這裡最多同時中 4 條。）
@Test func reportsStructuralProblemsInDeclarationOrder() {
    let config = obj([
        ("windows", .array([])),
        ("a a", obj([("desc", .string("x")),
                     ("displays", obj([("main", .string("M"))])),
                     ("trees", .object([])),
                     ("default", .string("Q"))])),
    ])
    #expect(LayoutValidator.validate(config) == [
        .structural("a a：trees 不能放在地點層，要搬進 profiles.<名稱>.trees"),
        .structural("a a：profiles 不存在或是空的"),
        .structural("地點名稱「a a」不能含空白"),
        .structural("a a.default「Q」不是這個地點的 profile"),
    ])
}

/// 地點之間依來源鍵序，不是字典序。
@Test func reportsStructuralProblemsInSourceOrder() {
    let config = obj([
        ("zzz", healthyLocation(extra: [("trees", .object([]))])),
        ("a a", healthyLocation()),
    ])
    #expect(LayoutValidator.validate(config) == [
        .structural("zzz：trees 不能放在地點層，要搬進 profiles.<名稱>.trees"),
        .structural("地點名稱「a a」不能含空白"),
    ])
}

// MARK: - 地點的值不是物件（缺欄位那段也會中止串流）

/// jq 在 `$lv.desc` 對字串會 runtime error，中止的是**整個串流**——已經吐出來的
/// 留著，後面的地點一條都不檢查。實測：
///   {"aaa":合法, "home":"字串", "z z":名稱有空白} → rc=0，零輸出
/// 連 z z 的違規都被吞掉。這不是合理設計，是要複製的既有行為。
@Test func aNonObjectLocationStopsTheWholePass() {
    let config = obj([
        ("aaa", healthyLocation()),
        ("home", .string("不是物件")),
        ("z z", healthyLocation()),
    ])
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 陣列、數字、布林同樣中止——`.desc` 對它們都無法索引。
@Test func otherNonObjectLocationTypesAlsoStopThePass() {
    for bad in [JSONValue.array([]), .number("42"), .bool(true)] {
        let config = obj([("home", bad), ("z z", healthyLocation())])
        #expect(LayoutValidator.validate(config).isEmpty, "\(bad) 應該中止整個串流")
    }
}

/// **null 是例外**：`null.desc` 在 jq 是合法的（回 null），所以不中止，
/// 而且照常報 desc 與 windows 兩條。displays.main 不報——`null.displays | objects`
/// 產生 empty。實測 bash 輸出正是這兩條。
@Test func aNullLocationDoesNotStopThePass() {
    let config = obj([("home", .null), ("z z", healthyLocation())])
    #expect(LayoutValidator.validate(config) == [
        .missingField("home.desc（要非空字串）"),
        .missingField("home.windows"),
    ])
}
