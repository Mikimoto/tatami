import Testing
@testable import WorkmodeDomain

// `match_location`：從「接了哪些螢幕」反推地點。與 SpacesTests 分開，因為它讀的是
// layout.json 的 displays 對照表，而 space 那兩支讀的是 yabai 的 space 清單——
// 兩邊的語料沒有一個欄位是共用的。
//
// 邊界那組是 2026-08-14 拿 jq 1.8.2 對 scripts/workmode.sh 實跑挖出來的。

// MARK: - match_location 的語料

private func location(_ main: JSONValue, second: String? = nil) -> JSONValue {
    var roles: [(String, JSONValue)] = [("main", main)]
    if let second {
        roles.append(("second", .string(second)))
    }
    return obj([("displays", obj(roles))])
}

/// 與 tests/test_workmode.sh 的 GOOD_JSON 同形（只留 match_location 讀得到的欄位）。
///
/// `second` 不能省。省了的話「只接到 Chat 螢幕不算命中」那條會變成恆真——它命不中
/// 是因為那個 uuid 根本不在設定裡，而不是因為只比對主螢幕。2026-08-14 實際踩過：
/// 拿掉這兩行之後，把 match_location 改成連第二螢幕一起比的突變全綠。
private let goodConfig = obj([
    ("office", location(.string("AAAA-MAIN"), second: "AAAA-CHAT")),
    ("home", location(.string("BBBB-MAIN"), second: "BBBB-CHAT")),
])

private let builtIn = "CCCC-BUILTIN"

// MARK: - match_location（test_workmode.sh:87-92、:374）

@Test func theOfficeMainDisplayPicksTheOfficeLocation() {
    #expect(Displays.matchLocation(connected: "\(builtIn) AAAA-MAIN AAAA-CHAT",
                                   in: goodConfig) == "office")
}

@Test func theHomeMainDisplayPicksTheHomeLocation() {
    #expect(Displays.matchLocation(connected: "\(builtIn) BBBB-MAIN BBBB-CHAT",
                                   in: goodConfig) == "home")
}

@Test func theBuiltInDisplayAloneMatchesNoLocation() {
    #expect(Displays.matchLocation(connected: builtIn, in: goodConfig) == nil)
}

@Test func noConnectedDisplayMatchesNothing() {
    #expect(Displays.matchLocation(connected: "", in: goodConfig) == nil)
}

/// 識別只看主螢幕：Chat 那台單獨接著不算命中。
@Test func theChatDisplayAloneIsNotEnough() {
    #expect(Displays.matchLocation(connected: "\(builtIn) AAAA-CHAT", in: goodConfig) == nil)
}

/// 另一半：Chat 沒接時仍要認得出地點，那條規則才走得到自己的降級路徑。
@Test func theMainDisplayAloneStillIdentifiesTheLocation() {
    #expect(Displays.matchLocation(connected: "\(builtIn) BBBB-MAIN", in: goodConfig) == "home")
}

/// 最外層的 `windows` 是共用視窗總表，不是地點。漏掉這道 select 的話它會被當成
/// 一個地點，而對陣列取 `.displays` 會讓整個 jq 串流當場中止。
@Test func theReservedWindowsKeyIsNotALocationToMatchAgainst() {
    let shared = obj([
        ("windows", .array([obj([("label", .string("S1"))])])),
        ("home", location(.string("BBBB-MAIN"))),
    ])
    #expect(Displays.matchLocation(connected: "\(builtIn) BBBB-MAIN", in: shared) == "home")
}

// MARK: - match_location 的邊界（實測）

/// `case " $connected " in *" $main "*)` 這個手法在 resolve_profile 造成過偽陽性
/// （profile 叫「開 發」時指名「開」會命中）。這裡**不會**，因為方向相反：那邊拿
/// 使用者給的字當針、空白分隔的清單當草堆；這邊的針是設定裡的 main 且左右都補了
/// 空白，所以連接清單裡的某個 uuid 只有整個相符才算。2026-08-14 實測確認。
@Test func aPartialUUIDDoesNotMatch() {
    let config = obj([("loc", location(.string("AB")))])
    #expect(Displays.matchLocation(connected: "ABC", in: config) == nil)
    #expect(Displays.matchLocation(connected: "XABC", in: config) == nil)
    #expect(Displays.matchLocation(connected: "AB", in: config) == "loc")
}

/// `" $main "` 在 case 的 pattern 裡是**加了雙引號**的，所以 main 裡的 glob 字元
/// 是字面值而不是萬用字元。少了那對引號 `main: "*"` 會命中任何連接清單。
@Test func globCharactersInTheMainUUIDAreLiteral() {
    for pattern in ["*", "A*", "A?C", "A[BX]C"] {
        let config = obj([("loc", location(.string(pattern)))])
        #expect(Displays.matchLocation(connected: "ABC", in: config) == nil)
        #expect(Displays.matchLocation(connected: pattern, in: config) == "loc")
    }
}

/// main 缺欄位（或是 null）時 @tsv 給的是空字串，pattern 於是收斂成兩個相連的
/// 空白——而 connected 為空時 `" $connected "` 剛好就是兩個空白，於是命中。
/// 這不是設計，是左右補空白的副作用，但它是 bash 現行的行為。
@Test func anEmptyMainMatchesWhenNothingIsConnected() {
    for empty in [JSONValue.null, .string("")] {
        let config = obj([("loc", location(empty))])
        #expect(Displays.matchLocation(connected: "", in: config) == "loc")
        #expect(Displays.matchLocation(connected: " ", in: config) == "loc")
        // 連接清單裡有兩個相連的空白同樣命中。
        #expect(Displays.matchLocation(connected: "A  B", in: config) == "loc")
        // 一般的連接清單則不會。
        #expect(Displays.matchLocation(connected: "XX", in: config) == nil)
    }
    // displays 整個缺也是同一條路：null 索引出 null。
    let bare = obj([("loc", obj([]))])
    #expect(Displays.matchLocation(connected: "", in: bare) == "loc")
}

/// 這條守的不只是排序：兩個地點的 `main` 寫成同一顆時，後面那個永遠拿不到。
/// 2026-08-29 實際踩過，兩地的 `main` 都是內建螢幕，於是在家也認成 office。
/// 修法在設定裡（每個地點的 `main` 要是它獨有的一顆），不在這支函式裡。
@Test func theFirstMatchingLocationInSourceOrderWins() {
    let dup = obj([("z", location(.string("SAME"))), ("a", location(.string("SAME")))])
    #expect(Displays.matchLocation(connected: "SAME", in: dup) == "z")
}

/// jq 的 runtime error 會中止整個串流，而 bash 是先把 jq 的輸出整包收進命令替換
/// 再跑迴圈——所以中止之前印出來的地點還在，之後的整批不見了。
@Test func aRuntimeErrorStopsTheScanSoLaterLocationsAreLost() {
    let broken = obj([
        ("a", location(.string("AAA"))),
        ("b", num("5")),
        ("c", location(.string("CCC"))),
    ])
    #expect(Displays.matchLocation(connected: "AAA", in: broken) == "a")
    #expect(Displays.matchLocation(connected: "CCC", in: broken) == nil)
}

/// main 是容器時 @tsv 直接報錯（`object ({"k":1}) is not valid in a csv row`），
/// 同樣中止串流。純量則各自轉成它的字面文字。
@Test func aContainerMainAbortsWhileAScalarOneIsComparedAsText() {
    let container = obj([("loc", location(obj([("k", num("1"))])))])
    #expect(Displays.matchLocation(connected: "5", in: container) == nil)

    let numeric = obj([("loc", location(num("5")))])
    #expect(Displays.matchLocation(connected: "5", in: numeric) == "loc")

    let flag = obj([("loc", location(.bool(true)))])
    #expect(Displays.matchLocation(connected: "true", in: flag) == "loc")
    #expect(Displays.matchLocation(connected: "5", in: flag) == nil)
}

/// @tsv 會把 TAB 轉義成字面的兩個字元，所以回來的地點名是**轉義後**的文字，
/// 而比對 main 時看的也是轉義後的形式（真的 TAB 反而配不上）。
@Test func tabsComeBackEscapedOnBothSides() {
    let tabbed = obj([("a\tb", location(.string("X\tY")))])
    #expect(Displays.matchLocation(connected: "X\\tY", in: tabbed) == "a\\tb")
    #expect(Displays.matchLocation(connected: "X\tY", in: tabbed) == nil)
}

/// bash 的 `[ -z "$name" ] && continue`：名字是空字串的那筆直接跳過，
/// 即使它的 main 對得上。
@Test func aLocationWithAnEmptyNameIsSkipped() {
    let unnamed = obj([("", location(.string("MMM"))), ("real", location(.string("MMM")))])
    #expect(Displays.matchLocation(connected: "MMM", in: unnamed) == "real")
}

/// `to_entries` 對陣列給的是索引當 key，對純量則報錯（串流中止 → 沒有命中）。
@Test func anArrayRootUsesIndicesAsNamesAndAScalarRootMatchesNothing() {
    #expect(Displays.matchLocation(connected: "AAA",
                                   in: .array([location(.string("AAA"))])) == "0")
    #expect(Displays.matchLocation(connected: "AAA", in: num("5")) == nil)
}
