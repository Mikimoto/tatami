import Testing
@testable import WorkmodeDomain

// `resolve_profile`：從「指定的名字／記住的名字／預設」三個來源挑一個 profile。
// merge_profile 那組在 ProfileMergeTests.swift；共用的設定在 ProfileResolutionFixtures.swift。

/// 測試用的 jq `-r`。真正的那支住在 WorkmodeCLI（它借 JSONWriter 印縮排格式，而
/// Domain 不能 import Wire），所以這裡只覆蓋純量——容器只有一條斷言用得到，
/// 那條自己帶一個回傳 jq 實測文字的 closure。
private func rawLike(_ value: JSONValue) -> String {
    switch value {
    case let .string(text): text
    case let .number(literal): literal
    case let .bool(flag): flag ? "true" : "false"
    case .null: "null"
    case .array, .object: "<容器：這個 fixture 不該走到這裡>"
    }
}

private func resolve(_ location: String, _ want: String, _ state: String,
                     _ config: JSONValue,
                     render: @escaping (JSONValue) -> String = rawLike) throws -> ProfileChoice
{
    try ProfileResolution.resolve(location: location, want: want, state: state,
                                  in: config, renderRaw: render)
}

/// 印成 bash 那側的三欄 TSV，讓斷言長得跟 tests/test_workmode.sh 一樣好對照。
private func tsv(_ choice: ProfileChoice) -> String {
    "\(choice.name)\t\(choice.source.rawValue)\t\(choice.ignoredMemory)"
}

// tests/test_workmode.sh:104-131 的 L2_JSON。

private let noDefaultJSON: JSONValue = {
    guard case let .object(root) = profileL2JSON, case let .object(home) = root[0].value else {
        fatalError("L2_JSON 的形狀變了")
    }
    return .object([JSONMember(key: "home",
                               value: .object(home.filter { $0.key != "default" }))])
}()

private let stateMemory = "profile.home=會議"
private let stateStale = "profile.home=沒這個"

// MARK: - resolve_profile：tests/test_workmode.sh:202-216 的六條

//
// 四個來源的值刻意互不相同：若三者同值，「它真的按優先序退讓」與「它永遠回傳
// 同一個」這兩種實作分不出來，斷言等於沒驗。

@Test func argBeatsMemory() throws {
    #expect(try tsv(resolve("home", "會議", stateMemory, profileL2JSON)) == "會議\targ\t")
}

@Test func memoryUsedWhenNoArgument() throws {
    #expect(try tsv(resolve("home", "", stateMemory, profileL2JSON)) == "會議\tmemory\t")
}

@Test func defaultUsedWhenNoMemory() throws {
    #expect(try tsv(resolve("home", "", "", profileL2JSON)) == "開發\tdefault\t")
}

@Test func staleMemoryFallsBackToDefaultAndIsReported() throws {
    #expect(try tsv(resolve("home", "", stateStale, profileL2JSON)) == "開發\tdefault\t沒這個")
}

/// 命令列參數打錯字是硬失敗（bash rc=2），不是退讓——使用者明白打了名字，
/// 靜默套別的等於說謊。
@Test func unknownArgumentIsHardFailure() throws {
    #expect(throws: ProfileResolutionError.unknownProfile(
        want: "沒這個", location: "home", available: "開發 會議"
    )) {
        _ = try resolve("home", "沒這個", "", profileL2JSON)
    }
}

@Test func firstProfileWhenNoDefault() throws {
    #expect(try tsv(resolve("home", "", "", noDefaultJSON)) == "開發\tfirst\t")
}

// MARK: - resolve_profile：實測挖出來的邊界

//
// 每一條都拿 bash 跑過（`bash -c 'source scripts/workmode.sh; resolve_profile …'`），
// 不是照語意推的。

/// `default` 不檢查存不存在——註解說「validate_layout 已保證它指向存在的 profile」，
/// 所以這裡真的會回一個不存在的名字。走不到的分支等於沒測過的分支，刻意不加檢查。
@Test func defaultIsNotCheckedAgainstTheProfileList() throws {
    let config = obj([("home", obj([("default", .string("NOPE")),
                                    ("profiles", obj([("A", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "NOPE\tdefault\t")
}

/// `default` 是空字串時 jq 的 `// empty` **不會**換掉它（`""` 在 jq 是真值），
/// 但 bash 的 `[ -n "$dflt" ]` 看到的是命令替換後的空字串，於是照樣退到 first。
/// 真值判斷發生在 jq 那層、非空判斷發生在 bash 那層，兩層的答案相反。
@Test func emptyDefaultFallsThroughToFirst() throws {
    let config = obj([("home", obj([("default", .string("")),
                                    ("profiles", obj([("A", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "A\tfirst\t")
}

/// 同上，但更隱蔽：`"\n"` 在 jq 也是真值，而命令替換把尾端換行**全部**吃掉，
/// bash 拿到的仍是空字串。
@Test func newlineOnlyDefaultFallsThroughToFirst() throws {
    let config = obj([("home", obj([("default", .string("\n")),
                                    ("profiles", obj([("A", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "A\tfirst\t")
}

/// 命令替換砍的是尾端**全部**的換行，不是一個。
@Test func trailingNewlinesInDefaultAreStripped() throws {
    let config = obj([("home", obj([("default", .string("a\n\n")),
                                    ("profiles", obj([("A", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "a\tdefault\t")
}

/// 砍的只有 `\n` 位元組。`\r\n` 在 Swift 是**一個** Character，用
/// `hasSuffix("\n")` + `dropLast()` 會連 `\r` 一起砍掉——那與 bash 不同。
@Test func carriageReturnSurvivesTheNewlineStrip() throws {
    let config = obj([("home", obj([("default", .string("a\r\n")),
                                    ("profiles", obj([("A", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "a\r\tdefault\t")
}

/// `default` 是 false／null 時 `// empty` 才真的擋下來，退到 first。
@Test func falseAndNullDefaultsFallThroughToFirst() throws {
    for value in [JSONValue.bool(false), .null] {
        let config = obj([("home", obj([("default", value),
                                        ("profiles", obj([("A", .object([]))]))]))])
        #expect(try tsv(resolve("home", "", "", config)) == "A\tfirst\t")
    }
}

/// `default` 是數字時 `jq -r` 印**字面值**（`2.50` 不會變 `2.5`），而且是真值。
@Test func numericDefaultKeepsItsLiteral() throws {
    let config = obj([("home", obj([("default", .number("2.50")),
                                    ("profiles", obj([("A", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "2.50\tdefault\t")
}

/// `default` 是容器時 `jq -r` 印的是**縮排**格式，於是那個多行文字整段變成第一欄。
/// 這條是唯一需要真渲染器的斷言，closure 回的就是 jq 1.8 的實測輸出。
@Test func containerDefaultUsesTheIndentedRendering() throws {
    let config = obj([("home", obj([("default", obj([("a", .number("1"))])),
                                    ("profiles", obj([("A", .object([]))]))]))])
    let choice = try resolve("home", "", "", config, render: { _ in "{\n  \"a\": 1\n}" })
    #expect(tsv(choice) == "{\n  \"a\": 1\n}\tdefault\t")
}

/// 欄位分隔用的是裸 tab，沒有任何轉義（bash 是 `printf`，不是 `@tsv`），
/// 所以名字裡的 tab 會讓欄位數變多。
@Test func tabsInsideValuesAreNotEscaped() throws {
    let config = obj([("home", obj([("default", .string("a\tb")),
                                    ("profiles", obj([("A", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "a\tb\tdefault\t")
}

/// `profiles` 不是物件時 jq 報 runtime error，但那個錯被命令替換吃掉——
/// `names` 變空，於是靜默退到 first 而不是失敗。
@Test func brokenProfilesCollapseToAnEmptyFirst() throws {
    for broken in [JSONValue.string("x"), .number("5")] {
        let config = obj([("home", obj([("profiles", broken)]))])
        #expect(try tsv(resolve("home", "", "", config)) == "\tfirst\t")
    }
}

/// `keys_unsorted` 對**陣列**回的是索引，不是報錯，所以第一個 key 是 `0`。
@Test func arrayProfilesYieldIndicesAsNames() throws {
    let config = obj([("home", obj([("profiles", .array([.number("1"), .number("2")]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "0\tfirst\t")
}

/// 整份設定壞掉（jq 解析失敗）與設定是 null，觀測上完全相同：兩個 jq 呼叫都吐
/// 零位元組，於是都收斂成 `\tfirst\t`。CLI 的 `__diff` 靠這個把解析失敗映成 `.null`。
@Test func nullConfigResolvesToAnEmptyFirst() throws {
    #expect(try tsv(resolve("home", "", "", .null)) == "\tfirst\t")
    #expect(try tsv(resolve("home", "", "", .number("5"))) == "\tfirst\t")
}

/// `case "$names" in *" $want "*` 的 `$want` 在雙引號裡，所以 glob 字元是**字面**的，
/// 不會匹配任何東西——實測 `*`／`?`／`[AB]` 三種都回 rc=2。
@Test func globCharactersInTheArgumentAreLiteral() throws {
    let config = obj([("home", obj([("profiles", obj([("A", .object([])),
                                                      ("B", .object([]))]))]))])
    for want in ["*", "?", "[AB]"] {
        #expect(throws: ProfileResolutionError.self) {
            _ = try resolve("home", want, "", config)
        }
    }
}

/// bash 的 `case` 比的是**位元組**。NFC 的 `café` 與 NFD 的 `café` 在 Swift 的
/// `String ==` 下相等，在 bash 下不相等——實測 want=NFC 對 profile=NFD 回 rc=2。
@Test func profileMembershipComparesBytesNotCanonicalEquivalence() throws {
    let nfd = "cafe\u{301}"
    let nfc = "caf\u{e9}"
    #expect(nfd == nfc, "Swift 認為兩者相等，這正是不能直接用 String 比對的理由")
    let config = obj([("home", obj([("profiles", obj([(nfd, .object([]))]))]))])
    #expect(try tsv(resolve("home", nfd, "", config)) == "\(nfd)\targ\t")
    #expect(throws: ProfileResolutionError.self) {
        _ = try resolve("home", nfc, "", config)
    }
}

/// first 那條走 `awk '{print $1}'`：**每一行**都印它的第一個欄位，所以名字裡有
/// 換行時輸出也是多行的。
@Test func firstFieldIsTakenPerLine() throws {
    let config = obj([("home", obj([("profiles", obj([("a\nb", .object([])),
                                                      ("C", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "a\nb\tfirst\t")
}

/// awk 的預設欄位分隔含 tab，所以名字裡的 tab 也會被切開。
@Test func tabInsideAProfileNameSplitsTheFirstField() throws {
    let config = obj([("home", obj([("profiles", obj([("a\tb", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", "", config)) == "a\tfirst\t")
}

/// 記憶失效而且沒有 default 時，被忽略的名字要跟著退到 first 那一層。
@Test func staleMemoryIsReportedOnTheFirstBranchToo() throws {
    let config = obj([("home", obj([("profiles", obj([("A", .object([])),
                                                      ("B", .object([]))]))]))])
    #expect(try tsv(resolve("home", "", stateStale, config)) == "A\tfirst\t沒這個")
}

// state_get 的斷言搬到 StateFileTests.swift，與 state_set 放一起。
