import Testing
@testable import WorkmodeDomain

// `merge_profile`：把 --save 產生的 trees 與 rules 併回設定。與 resolve_profile 分開，
// 因為它驗的是輸出設定的形狀（角色留了哪些、鍵序、label 清單），而不是挑選邏輯。
//
// 共用的設定在 ProfileResolutionFixtures.swift。

// MARK: - merge_profile：tests/test_workmode.sh:580-598 的九條

private let mergeTrees = obj([("main", obj([
    ("axis", .string("vertical")),
    ("children", .array([obj([("window", .string("A"))]),
                         obj([("window", .string("B"))])])),
]))])
private let mergeRules = JSONValue.array([rule("Z", "app", "ZZ")])

private func merged(_ profile: String, _ trees: JSONValue,
                    _ rules: JSONValue) throws -> JSONValue
{
    try ProfileMerge.merge(profileL2JSON, location: "home", profile: profile,
                           trees: trees, rules: rules)
}

private func labels(_ config: JSONValue, _ path: [String]) -> [String] {
    var cursor = config
    for key in path {
        cursor = cursor[key] ?? .null
    }
    guard case let .array(items) = cursor else { return ["<不是陣列>"] }
    return items.map { item in
        if case let .string(text)? = item["label"] {
            return text
        }
        return "<沒有 label>"
    }
}

private func keys(_ value: JSONValue) -> [String] {
    guard case let .object(members) = value else { return ["<不是物件>"] }
    return members.map(\.key)
}

@Test func unmatchedRoleKeepsItsOwnTree() throws {
    let out = try merged("開發", mergeTrees, mergeRules)
    #expect(keys(out["home"]?["profiles"]?["開發"]?["trees"] ?? .null) == ["main", "second"])
}

@Test func untouchedTreeIsLeftAlone() throws {
    let out = try merged("開發", mergeTrees, mergeRules)
    #expect(out["home"]?["profiles"]?["開發"]?["trees"]?["second"]
        == obj([("window", .string("C")), ("ratio", .number("0.75"))]))
}

@Test func matchedRoleGetsTheNewTree() throws {
    let out = try merged("開發", mergeTrees, mergeRules)
    #expect(out["home"]?["profiles"]?["開發"]?["trees"]?["main"] == mergeTrees["main"])
}

@Test func rulesAppendToTheLocationWindowsWhenTheProfileHasNone() throws {
    let out = try merged("開發", mergeTrees, mergeRules)
    #expect(labels(out, ["home", "windows"]) == ["A", "B", "C", "M", "Z"])
}

/// profile 自己有 windows 時規則要落在**那裡**：profile 層是整塊取代
/// （windows_for 的語意），寫到地點層就不會生效，樹引用的 label 於是不在生效
/// 清單裡而被 validate_layout 擋下。
@Test func rulesGoToTheProfileWindowsWhenItHasItsOwn() throws {
    let out = try merged("會議", obj([("main", obj([("window", .string("M"))]))]), mergeRules)
    #expect(labels(out, ["home", "profiles", "會議", "windows"]) == ["M", "Z"])
}

@Test func locationWindowsUntouchedWhenTheProfileHasItsOwn() throws {
    let out = try merged("會議", obj([("main", obj([("window", .string("M"))]))]), mergeRules)
    #expect(labels(out, ["home", "windows"]) == ["A", "B", "C", "M"])
}

@Test func missingProfileIsCreated() throws {
    let out = try merged("影音", obj([("main", obj([("window", .string("A"))]))]), .array([]))
    #expect(out["home"]?["profiles"]?["影音"]
        == obj([("trees", obj([("main", obj([("window", .string("A"))]))]))]))
}

@Test func mergedConfigStillValidates() throws {
    #expect(try LayoutValidator.validate(merged("開發", mergeTrees, mergeRules)).isEmpty)
}

@Test func configWithANewProfileStillValidates() throws {
    let out = try merged("影音", obj([("main", obj([("window", .string("A"))]))]), .array([]))
    #expect(LayoutValidator.validate(out).isEmpty)
}

// MARK: - merge_profile：實測挖出來的邊界

/// `trees` 用 `+` 疊上去而不是整個換掉——沒接到的螢幕角色要保留舊 profile 那棵樹，
/// 單螢幕存一次不該把另一台的設定洗掉。同名的角色由右邊（新的）蓋過。
@Test func treesAreMergedNotReplaced() throws {
    let out = try merged("開發", obj([("second", .string("新的"))]), .array([]))
    let trees = out["home"]?["profiles"]?["開發"]?["trees"] ?? .null
    #expect(keys(trees) == ["main", "second"])
    #expect(trees["second"] == .string("新的"))
}

/// `[] | type == "array"` 為真，所以**空**的 profile windows 照樣算「有自己的」。
@Test func anEmptyProfileWindowsArrayStillCountsAsItsOwn() throws {
    let config = obj([("h", obj([("windows", .array([])),
                                 ("profiles", obj([("P", obj([("windows", .array([]))]))]))]))])
    let out = try ProfileMerge.merge(config, location: "h", profile: "P",
                                     trees: .object([]), rules: .array([rule("Z", "a", "b")]))
    #expect(labels(out, ["h", "profiles", "P", "windows"]) == ["Z"])
    #expect(labels(out, ["h", "windows"]) == [])
}

/// 非陣列的 profile windows（物件、true）走的是**地點層**那條。
@Test func nonArrayProfileWindowsSendTheRulesToTheLocation() throws {
    for odd in [JSONValue.object([]), .bool(true), .string("x")] {
        let config = obj([("h", obj([("windows", .array([])),
                                     ("profiles", obj([("P", obj([("windows", odd)]))]))]))])
        let out = try ProfileMerge.merge(config, location: "h", profile: "P",
                                         trees: .object([]), rules: .array([rule("Z", "a", "b")]))
        #expect(labels(out, ["h", "windows"]) == ["Z"])
    }
}

/// 路徑不存在時 jq 的 setpath 一路建出物件來，連根是 null 都會變成物件。
/// 建立順序看得出兩段的先後：windows 先、profiles 後。
@Test func missingPathsAreCreatedInProgramOrder() throws {
    let out = try ProfileMerge.merge(.null, location: "h", profile: "P",
                                     trees: .object([]), rules: .array([]))
    #expect(keys(out) == ["h"])
    #expect(keys(out["h"] ?? .null) == ["windows", "profiles"])
}

/// 既有的鍵原地更新、新的鍵接在尾端——鍵序是 layout.json 寫回去時唯一的依據。
@Test func existingKeysKeepTheirPosition() throws {
    let config = obj([("h", obj([("desc", .string("x"))]))])
    let out = try ProfileMerge.merge(config, location: "h", profile: "P",
                                     trees: .object([]), rules: .array([]))
    #expect(keys(out["h"] ?? .null) == ["desc", "windows", "profiles"])
}

/// `//` 的假值只有 null 與 false，所以 `trees: false` 退到 `{}`，
/// 而 `trees: []` 是真值、拿去跟物件相加就報錯。
@Test func falseTreesFallBackToAnEmptyObject() throws {
    let config = obj([("h", obj([("profiles", obj([("P", obj([("trees", .bool(false))]))]))]))])
    let out = try ProfileMerge.merge(config, location: "h", profile: "P",
                                     trees: obj([("main", .object([]))]), rules: .array([]))
    #expect(keys(out["h"]?["profiles"]?["P"]?["trees"] ?? .null) == ["main"])
}

@Test func arrayTreesAreARuntimeError() throws {
    let config = obj([("h", obj([("profiles", obj([("P", obj([("trees", .array([]))]))]))]))])
    #expect(throws: ProfileMergeError.runtime) {
        _ = try ProfileMerge.merge(config, location: "h", profile: "P",
                                   trees: obj([("main", .object([]))]), rules: .array([]))
    }
}

/// jq 的 `+` 對 null 是單位元素（兩個方向都是），所以 `--argjson` 餵 null 不報錯。
@Test func nullIsTheIdentityForPlus() throws {
    let config = obj([("h", obj([("windows", .array([rule("A", "a", "b")]))]))])
    let out = try ProfileMerge.merge(config, location: "h", profile: "P",
                                     trees: .null, rules: .null)
    #expect(labels(out, ["h", "windows"]) == ["A"])
    #expect(out["h"]?["profiles"]?["P"]?["trees"] == .object([]))
}

/// 顯式的 `"windows": null` 與缺欄位走同一條路：`null + $r` 就是 `$r`。
@Test func explicitNullWindowsBecomesTheRules() throws {
    let config = obj([("h", obj([("windows", .null)]))])
    let out = try ProfileMerge.merge(config, location: "h", profile: "P",
                                     trees: .object([]), rules: .array([rule("Z", "a", "b")]))
    #expect(labels(out, ["h", "windows"]) == ["Z"])
}

/// jq 的 `+` 對兩個字串是接起來，不是錯——照做，因為這裡的結果會被印出去。
/// （LayoutQuery 那支的 `add` 對字串是 throw，理由是它後面接的 `.[]` 對純量
/// 必定報錯、兩條路的可觀測結果相同；這裡沒有那個 `.[]`。）
@Test func stringPlusStringConcatenates() throws {
    let config = obj([("h", obj([("windows", .string("a"))]))])
    let out = try ProfileMerge.merge(config, location: "h", profile: "P",
                                     trees: .object([]), rules: .string("b"))
    #expect(out["h"]?["windows"] == .string("ab"))
}

/// 型別對不上就是 runtime error（bash rc=5）。
@Test func mismatchedTypesAreRuntimeErrors() throws {
    let cases: [(JSONValue, JSONValue)] = [
        (obj([("h", obj([("windows", .array([]))]))]), .bool(true)),
        (obj([("h", obj([("windows", .object([]))]))]), .array([])),
        (obj([("h", obj([("windows", .array([]))]))]), .object([])),
    ]
    for (config, rules) in cases {
        #expect(throws: ProfileMergeError.runtime) {
            _ = try ProfileMerge.merge(config, location: "h", profile: "P",
                                       trees: .object([]), rules: rules)
        }
    }
}

/// 非物件的中繼節點一律報錯，而且 `if` 條件那條路徑先炸——`.[$l].profiles[$p]`
/// 在 profiles 是陣列時就已經是錯的，輪不到地點層那條。
@Test func nonObjectIntermediatesAreRuntimeErrors() throws {
    let cases: [JSONValue] = [
        obj([("h", .number("5"))]),
        obj([("h", obj([("profiles", .array([.number("1")]))]))]),
        obj([("h", obj([("profiles", .string("x"))]))]),
        .array([.number("1")]),
    ]
    for config in cases {
        #expect(throws: ProfileMergeError.runtime) {
            _ = try ProfileMerge.merge(config, location: "h", profile: "P",
                                       trees: .object([]), rules: .array([]))
        }
    }
}

// MARK: - mergeSpaceTrees：`--save` 走的那一支（沒有 bash 對應）

/// 合併必須是**兩層深**的。淺層的 `+` 會讓 `main` 整個被新的取代，於是 `U-舊`
/// 那棵無聲消失。這條的鑑別力就在 `U-舊`——**只有一個 space 的 fixture 對這個突變
/// 完全沒有分辨力**（兩種實作都會給出 `{main: {U-新: …}}`）。
@Test func mergingSpaceTreesKeepsTheOtherSpacesInTheSameRole() throws {
    let config = obj([("home", obj([("profiles", obj([("開發", obj([
        ("spaceTrees", obj([("main", obj([("U-舊", leaf(.string("Old"))),
                                          ("U-其他", leaf(.string("Other")))]))])),
    ]))]))]))])
    let incoming = obj([("main", obj([("U-新", leaf(.string("New")))]))])
    let merged = try ProfileMerge.mergeSpaceTrees(config, location: "home", profile: "開發",
                                                  spaceTrees: incoming, rules: .array([]))
    let trees = merged["home"]?["profiles"]?["開發"]?["spaceTrees"]?["main"]
    #expect(trees?["U-舊"] == leaf(.string("Old")), "別的 space 的樹被洗掉了")
    #expect(trees?["U-其他"] == leaf(.string("Other")), "別的 space 的樹被洗掉了")
    #expect(trees?["U-新"] == leaf(.string("New")))
}

/// 同一個 uuid 再存一次＝覆蓋（那正是「我重排了這個 space，存起來」）。
@Test func mergingTheSameSpaceTwiceOverwritesIt() throws {
    let config = obj([("home", obj([("profiles", obj([("開發", obj([
        ("spaceTrees", obj([("main", obj([("U-1", leaf(.string("Old")))]))])),
    ]))]))]))])
    let incoming = obj([("main", obj([("U-1", leaf(.string("New")))]))])
    let merged = try ProfileMerge.mergeSpaceTrees(config, location: "home", profile: "開發",
                                                  spaceTrees: incoming, rules: .array([]))
    #expect(merged["home"]?["profiles"]?["開發"]?["spaceTrees"]?["main"]?["U-1"]
        == leaf(.string("New")))
}

/// 沒接到的**角色**照樣要保留，與 `merge` 對 `trees` 的行為一致
/// （單螢幕存一次不該把另一台的設定洗掉）。
@Test func mergingSpaceTreesKeepsUntouchedRoles() throws {
    let config = obj([("home", obj([("profiles", obj([("開發", obj([
        ("spaceTrees", obj([("DELL", obj([("U-9", leaf(.string("Tube")))]))])),
    ]))]))]))])
    let incoming = obj([("main", obj([("U-1", leaf(.string("Code")))]))])
    let merged = try ProfileMerge.mergeSpaceTrees(config, location: "home", profile: "開發",
                                                  spaceTrees: incoming, rules: .array([]))
    let trees = merged["home"]?["profiles"]?["開發"]?["spaceTrees"]
    #expect(trees?["DELL"]?["U-9"] == leaf(.string("Tube")), "沒碰到的角色被洗掉了")
    #expect(trees?["main"]?["U-1"] == leaf(.string("Code")))
}

/// **`trees` 這個鍵一定要在。** `LayoutValidator` 對缺 `trees` 的 profile 報「缺
/// trees」，而 `SaveLayout.build` 拿 merge 的結果去跑 validate——不補的話，對一個
/// 還沒有 `trees` 的 profile 存檔會被自己的閘門打回票。
/// 鍵序也釘著：`trees` 在 `spaceTrees` 前面，與既有檔案一致。
@Test func mergingSpaceTreesAlwaysLeavesATreesKey() throws {
    let out = try ProfileMerge.mergeSpaceTrees(.null, location: "h", profile: "P",
                                               spaceTrees: obj([("main",
                                                                 obj([("U-1", leaf(.string("A")))]))]),
                                               rules: .array([]))
    #expect(out["h"]?["profiles"]?["P"]?["trees"] == .object([]))
    #expect(keys(out["h"]?["profiles"]?["P"] ?? .null) == ["trees", "spaceTrees"])
}

/// 既有的 `trees` 不准被動到——它是另一條路徑（`workmode` 走的那條）的設定。
@Test func mergingSpaceTreesLeavesAnExistingTreesAlone() throws {
    let config = obj([("h", obj([("profiles", obj([("P", obj([
        ("trees", obj([("main", leaf(.string("Keep")))])),
    ]))]))]))])
    let out = try ProfileMerge.mergeSpaceTrees(config, location: "h", profile: "P",
                                               spaceTrees: obj([("main",
                                                                 obj([("U-1", leaf(.string("A")))]))]),
                                               rules: .array([]))
    #expect(out["h"]?["profiles"]?["P"]?["trees"]?["main"] == leaf(.string("Keep")))
}

/// 規則的落點與 `merge` 共用同一段（`mergeRules`），所以這裡只釘一條：profile 自己
/// 有 `windows` 時規則要落在**那裡**。兩份會漂的話症狀離改動點很遠。
@Test func mergingSpaceTreesRoutesRulesLikeTheBashOne() throws {
    let out = try ProfileMerge.mergeSpaceTrees(profileL2JSON, location: "home",
                                               profile: "會議",
                                               spaceTrees: .object([]), rules: mergeRules)
    #expect(labels(out, ["home", "profiles", "會議", "windows"]) == ["M", "Z"])
    #expect(labels(out, ["home", "windows"]) == ["A", "B", "C", "M"])
}

/// `//` 的假值只有 null 與 false，與 `merge` 一致。
@Test func falseSpaceTreesFallBackToAnEmptyObject() throws {
    let config = obj([("h", obj([("profiles",
                                  obj([("P", obj([("spaceTrees", .bool(false))]))]))]))])
    let out = try ProfileMerge.mergeSpaceTrees(config, location: "h", profile: "P",
                                               spaceTrees: obj([("main", .object([]))]),
                                               rules: .array([]))
    #expect(keys(out["h"]?["profiles"]?["P"]?["spaceTrees"] ?? .null) == ["main"])
}

/// 非物件的 `spaceTrees` 一律 runtime error——**incoming 是空物件時也一樣**。
/// 那個「也一樣」是這條的鑑別力：兩層合併的迴圈在 incoming 為空時根本不跑，
/// 少了那道 `guard` 這個錯就消失了，而它消失的方式是「安靜地把設定寫成空物件」。
@Test func nonObjectSpaceTreesAreRuntimeErrors() throws {
    for incoming in [JSONValue.object([]), obj([("main", .object([]))])] {
        let config = obj([("h", obj([("profiles",
                                      obj([("P", obj([("spaceTrees", .array([]))]))]))]))])
        #expect(throws: ProfileMergeError.runtime) {
            _ = try ProfileMerge.mergeSpaceTrees(config, location: "h", profile: "P",
                                                 spaceTrees: incoming, rules: .array([]))
        }
    }
}

/// 餵進來的 spaceTrees 本身不是物件也不是 null＝ runtime error（jq 的 `{} + "x"`）。
/// null 則是單位元素，與 `merge` 一致。
@Test func aNullSpaceTreesIsTheIdentityButAStringIsNot() throws {
    let out = try ProfileMerge.mergeSpaceTrees(.null, location: "h", profile: "P",
                                               spaceTrees: .null, rules: .array([]))
    #expect(out["h"]?["profiles"]?["P"]?["spaceTrees"] == .object([]))
    #expect(throws: ProfileMergeError.runtime) {
        _ = try ProfileMerge.mergeSpaceTrees(.null, location: "h", profile: "P",
                                             spaceTrees: .string("x"), rules: .array([]))
    }
}

/// merge 出來的東西要通得過 validate——那是 `SaveLayout` 緊接著要跑的閘門。
@Test func mergedSpaceTreesStillValidate() throws {
    let out = try ProfileMerge.mergeSpaceTrees(
        profileL2JSON, location: "home", profile: "開發",
        spaceTrees: obj([("main", obj([("U-1", obj([("window", .string("A"))]))]))]),
        rules: .array([])
    )
    #expect(LayoutValidator.validate(out).isEmpty)
}
