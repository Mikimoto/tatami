import Testing
import WorkmodeCore
import WorkmodeDomain

// `resolve_rules`（workmode.sh:870-917）的每一條分支，以及它對 stderr 的壓制。
// 與 report_rules 那組分開：那邊驗的是「沒有規則可報時不去問 yabai」這類退化情境，
// 這邊驗的是比對本身走了哪一條路。
//
// 兩支在 bash 那側都完全測不到（都會呼叫 yabai），所以每條分支的行為到目前為止
// 只有實機能驗。fixture 在 RuleResolutionFixtures.swift。

// MARK: - resolve_rules 的每一條分支

/// keep 過濾用 `grep -qxF`＝整行、固定字串。label 含 `*` `?` `[` 時**不得**被當成
/// 萬用字元（workmode.sh:869 的註解就是這件事）：一旦當成 glob，`a*c` 會把 keep 裡的
/// `abc` 算成命中，於是一條這次沒被引用到的規則照樣去搬視窗。
@Test func filtersByKeepUsingWholeLineFixedStringComparison() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    // `^Beta$` 只配得上 dump 的第二筆，所以命中多個的警告不會混進來。
    let rules = """
    a*c\ttitle-regex\t^Beta$\t-\t-
    b?d\ttitle-regex\t^Beta$\t-\t-
    Beta\ttitle-regex\t^Beta$\t-\t-
    """
    // keep 裡放的是 `abc`／`bxd`／`Beta`：前兩個只有在 label 被當成 glob 時才會命中。
    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: rules, dump: dump, keep: "abc\nbxd\nBeta")

    #expect(map == "Beta\t8")
    // `a*c` 與 `b?d` 完全沒被處理，所以連「找不到」的警告都不該有。
    #expect(reporter.events.isEmpty)
}

/// `-x` 那一半：keep 的比對是**整行**，label 只是某一行的子字串時不算命中。
///
/// 這條與上一條防的是不同的東西，兩條都需要：上一條防「label 被當成 pattern」
/// （`F`），這一條防「label 只要出現在某行裡就算」（`x`）。少了 `-x`，`Beta` 會被
/// 一個叫 `Beta視窗` 的 keep 條目放行，於是一條這次沒被樹引用到的規則照樣去搬視窗。
@Test func requiresTheKeepEntryToMatchTheWholeLineNotJustAPrefix() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Beta\ttitle-regex\t^Beta$\t-\t-", dump: dump, keep: "Beta視窗\nxBeta")

    #expect(map.isEmpty)
    #expect(reporter.events.isEmpty)
}

/// `[` 那個字元單獨驗一次：`[abc]` 當成 glob 時會命中 keep 裡的 `a`。
@Test func doesNotTreatABracketLabelAsACharacterClass() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "[abc]\ttitle-regex\t^Alpha$\t-\t-", dump: dump, keep: "a")

    #expect(map.isEmpty)
    #expect(reporter.events.isEmpty)
}

/// `mt == "app"` 走 `yabai -m query --windows`，**不碰分頁 dump**。
@Test func resolvesTheAppMatchThroughAWindowsQuery() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.windows, windowList([("Safari", "7"), ("Code", "42"), ("Safari", "9")]))

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Editor\tapp\tCode\t-\t-", dump: "", keep: "Editor")

    #expect(map == "Editor\t42")
    #expect(yabai.allArgv == [["query", "--windows"]])
    #expect(reporter.events.isEmpty)
}

/// 其餘三個 match 類型走 `find_windows`，**一次 yabai 都不問**。
@Test func resolvesNonAppMatchesFromTheTabDumpWithoutQueryingYabai() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Site\turl-exact\thttps://b.example/\t-\t-", dump: dump, keep: "Site")

    #expect(map == "Site\t8")
    #expect(yabai.allArgv.isEmpty)
}

/// fallback 只在 `cands` 空**且** `ft != "-"` 時才試。
@Test func fallsBackWhenTheMatchFoundNothing() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.windows, windowList([("Code", "42")]))

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Editor\ttitle-regex\t^NoSuchTitle$\tapp\tCode",
                 dump: dump, keep: "Editor")

    #expect(map == "Editor\t42")
    #expect(reporter.events.isEmpty)
}

/// match 有命中時 fallback **不得**執行——否則它會用 app 名再撈一批候選，
/// 把一條精確的 title-regex 規則變成「這個 app 的隨便一個視窗」。
@Test func doesNotFallBackWhenTheMatchAlreadyFoundSomething() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    // fallback 若被執行，這個沒塞回應的 query 會丟錯而不是靜默回空。
    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Site\turl-exact\thttps://b.example/\tapp\tSafari",
                 dump: dump, keep: "Site")

    #expect(map == "Site\t8")
    #expect(yabai.allArgv.isEmpty)
}

/// `ft == "-"` 是「沒有 fallback」的字面表示，即使 match 一無所獲也不試。
@Test func treatsADashFallbackTypeAsNoFallback() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Ghost\ttitle-regex\t^NoSuchTitle$\t-\t-", dump: dump, keep: "Ghost")

    #expect(map.isEmpty)
    #expect(yabai.allArgv.isEmpty)
    #expect(reporter.events == [
        .ruleWindowNotFound(label: "Ghost", matchType: "title-regex", matchValue: "^NoSuchTitle$"),
    ])
}

/// match 那側是 `|| continue`＝**整條規則放棄**，連「找不到視窗」的警告都不印。
/// 對照下一條：同一種失敗發生在 fallback 那側是 `|| true`。
@Test func abandonsTheWholeRuleWhenTheMatchTypeIsUnknown() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Ghost\tbogus-kind\tvalue\tapp\tSafari", dump: dump, keep: "Ghost")

    #expect(map.isEmpty)
    // fallback 沒被試（沒有 query），而且**一句警告都沒有**。
    #expect(yabai.allArgv.isEmpty)
    #expect(reporter.events.isEmpty)
}

/// fallback 那側是 `|| true`：它失敗不放棄這條規則，所以「找不到視窗」照樣印出來。
/// 這條與上一條的差別就是 bash 那兩行刻意不同的錯誤處理。
@Test func keepsGoingWhenOnlyTheFallbackTypeIsUnknown() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Ghost\ttitle-regex\t^NoSuchTitle$\tbogus-kind\tvalue",
                 dump: dump, keep: "Ghost")

    #expect(map.isEmpty)
    #expect(reporter.events == [
        .ruleWindowNotFound(label: "Ghost", matchType: "title-regex", matchValue: "^NoSuchTitle$"),
    ])
}

/// 命中多個 → 警告帶著**全部**候選（`tr '\n' ' '`），然後取第一個。
/// 候選清單是這句話的重點：誤中不會有別的訊號，腳本照樣 exit 0，只是排錯了那個。
@Test func warnsWithEveryCandidateWhenOneRuleMatchesSeveralWindows() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "Site\turl-exact\thttps://a.example/\t-\t-", dump: dump, keep: "Site")

    #expect(map == "Site\t7")
    #expect(reporter.events == [
        .ruleMatchedMultipleWindows(label: "Site", count: 2, candidates: ["7", "9"]),
    ])
}

/// 先到先得：同一個視窗被兩條規則命中時，後面那條讓位並拿下一個候選。
/// 錨點曾經用子字串比對而同時命中 Chat 視窗，兩條規則會把它往兩個螢幕拉。
@Test func givesEachWindowToTheFirstRuleThatClaimsIt() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let rules = """
    First\turl-exact\thttps://a.example/\t-\t-
    Second\turl-exact\thttps://a.example/\t-\t-
    """
    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: rules, dump: dump, keep: "First\nSecond")

    #expect(map == "First\t7\nSecond\t9")
}

/// 候選全被認領完 → 那條規則跳過，訊息與「完全找不到」是**不同的**兩句：
/// 一句是設定有兩條規則指向同一個視窗，另一句是那個視窗沒開，處置方式不同。
@Test func reportsClaimedCandidatesDistinctlyFromNotFound() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let rules = """
    First\turl-exact\thttps://b.example/\t-\t-
    Second\turl-exact\thttps://b.example/\t-\t-
    """
    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: rules, dump: dump, keep: "First\nSecond")

    #expect(map == "First\t8")
    #expect(reporter.events == [.ruleCandidatesAllClaimed(label: "Second")])
}

/// 認領的比對是 `case "$claimed" in *" $c "*)`＝整個 token。認領了 `1` 不得讓 `10`
/// 也算被認領——子字串比對會讓第二條規則誤以為沒有候選，於是它的視窗根本沒被排。
@Test func claimsWholeTokensSoThatIDPrefixesStayAvailable() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.windows, windowList([("Code", "1"), ("Chat", "10")]))

    let rules = """
    Editor\tapp\tCode\t-\t-
    Chat\tapp\tChat\t-\t-
    """
    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: rules, dump: "", keep: "Editor\nChat")

    #expect(map == "Editor\t1\nChat\t10")
    #expect(reporter.events.isEmpty)
}

/// 同一條性質的**另一個方向**，兩條都需要：上一條先認領短的 id（`1`）再問長的
/// （`10`），這一條先認領長的再問短的。子字串比對只在後者被抓到——`" 10 "` 含
/// `"1"`，於是第二條規則被誤判成「候選都被認領了」，它的視窗根本沒被排，
/// 而畫面上不會有任何訊號說少排了一個。
@Test func claimingALongIDDoesNotConsumeItsShorterPrefix() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.windows, windowList([("Chat", "10"), ("Code", "1")]))

    let rules = """
    Chat\tapp\tChat\t-\t-
    Editor\tapp\tCode\t-\t-
    """
    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: rules, dump: "", keep: "Chat\nEditor")

    #expect(map == "Chat\t10\nEditor\t1")
    #expect(reporter.events.isEmpty)
}

/// 空 label 的行在 keep 過濾**之前**就跳掉（`[ -z "$label" ] && continue`）。
@Test func skipsLinesWithoutALabel() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let map = RuleResolution(yabai: yabai, reporter: reporter)
        .resolve(rules: "\t\t\t\t", dump: dump, keep: "")

    #expect(map.isEmpty)
    #expect(reporter.events.isEmpty)
}

// MARK: - stderr 的壓制

/// `save_layout` 呼叫 `resolve_rules` 時帶 `2>/dev/null`（workmode.sh:1106）：總表
/// 本來就含這次沒開的視窗，「找不到」在那裡是正常的。`main`（1306）不壓。
///
/// 所以壓制必須是**呼叫端包一層**而不是給 resolve 加參數，而且它只能碰輸出——
/// 這條同時驗兩件事：三則 stderr 事件消失、stdout 那側的結果與 stdout 事件一字不變。
@Test func silencingStderrHidesTheWarningsWithoutChangingWhatWasResolved() {
    let rules = """
    Site\turl-exact\thttps://a.example/\t-\t-
    Dup\turl-exact\thttps://a.example/\t-\t-
    Third\turl-exact\thttps://a.example/\t-\t-
    Ghost\ttitle-regex\t^NoSuchTitle$\t-\t-
    """
    let keep = "Site\nDup\nThird\nGhost"

    let loud = FakeReporter()
    let loudMap = RuleResolution(yabai: FakeYabai(), reporter: loud)
        .resolve(rules: rules, dump: dump, keep: keep)

    let quiet = FakeReporter()
    let quietMap = RuleResolution(
        yabai: FakeYabai(),
        reporter: SilencedChannelReporter(dropping: .stderr, into: quiet)
    ).resolve(rules: rules, dump: dump, keep: keep)

    // 這一組輸入把三則 stderr 訊息全湊出來：命中多個、候選被認領完、完全找不到。
    #expect(loud.events == [
        .ruleMatchedMultipleWindows(label: "Site", count: 2, candidates: ["7", "9"]),
        .ruleMatchedMultipleWindows(label: "Dup", count: 2, candidates: ["7", "9"]),
        .ruleMatchedMultipleWindows(label: "Third", count: 2, candidates: ["7", "9"]),
        .ruleCandidatesAllClaimed(label: "Third"),
        .ruleWindowNotFound(label: "Ghost", matchType: "title-regex", matchValue: "^NoSuchTitle$"),
    ])
    #expect(loud.events(on: .stderr).count == 5)
    #expect(quiet.events.isEmpty)
    // 壓制只碰輸出：解出來的 map 一字不變。
    #expect(quietMap == loudMap)
    #expect(loudMap == "Site\t7\nDup\t9")
}

/// 壓制的是**流**而不是某幾個 case：同一個 reporter 上 stdout 那側照樣通過。
/// 若寫成「丟掉 resolve_rules 的那三個 case」，`report_rules` 的輸出也會被連坐——
/// 而 `save_layout` 的 `2>/dev/null` 只在那一行上，report 那些話不受影響。
@Test func silencingOneChannelLeavesTheOtherUntouched() {
    let yabai = FakeYabai()
    let inner = FakeReporter()
    yabai.stubFixed(.window("8"), windowDetail(id: .number("8"), display: .number("1"),
                                               space: .number("2"),
                                               frame: Frame(width: "600", height: "400",
                                                            originX: "0", originY: "25")))

    let reporter = SilencedChannelReporter(dropping: .stderr, into: inner)
    RulePositionReport(yabai: yabai, reporter: reporter).report(rules: "Code\t8")
    reporter.report(.ruleCandidatesAllClaimed(label: "Code"))

    #expect(inner.events == [
        .ruleWindowPositionReported(label: "Code", id: "8", display: "1", space: "2",
                                    frame: ReportedFrame(width: "600", height: "400",

                                                         originX: "0", originY: "25")),
    ])
}
