import Testing
import WorkmodeCore
import WorkmodeDomain

// `resolve_rules`（workmode.sh:870-917）與 `report_rules`（664-676）。
//
// 這兩支在 bash 那側完全測不到（都會呼叫 yabai），所以每一條分支的行為到目前為止
// 只有實機能驗。下面每條測試對應 bash 的一條分支或一種退化情境。

// MARK: - report_rules 的退化情境

/// `[ -z "$rules" ]` 走 `echo` 加 `return 0`——迴圈完全不跑，所以**一次 query 都不發**。
/// 「沒發生任何 query」是這條的一半：印一句話卻還是去問 yabai 等於那個 early return
/// 沒生效。
@Test func reportsAPlaceholderAndAsksNothingWhenNoRuleResolved() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    RulePositionReport(yabai: yabai, reporter: reporter).report(rules: "")

    #expect(reporter.events == [.noRulesResolved])
    #expect(yabai.allArgv.isEmpty)
}

/// `[ -z "$id" ] && continue`：id 那欄空的行連 query 都不發。
@Test func skipsLinesWithoutAnIDWithoutQueryingThem() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.window("8"), windowDetail(id: .number("8"), display: .number("1"),
                                               space: .number("2"),
                                               frame: Frame(width: "600", height: "400",
                                                            originX: "0", originY: "25")))

    RulePositionReport(yabai: yabai, reporter: reporter).report(rules: "Chat\t\nCode\t8")

    #expect(yabai.allArgv == [["query", "--windows", "--window", "8"]])
    #expect(reporter.events == [
        .ruleWindowPositionReported(label: "Code", id: "8", display: "1", space: "2",
                                    frame: ReportedFrame(width: "600", height: "400",

                                                         originX: "0", originY: "25")),
    ])
}

/// query 失敗 → stdin 全空 → jq 零輸出 → **那個視窗一行都不出現**，而且是靜默的。
/// 後面的視窗照樣印：bash 那側迴圈不會因為一次 query 失敗而中止。
@Test func omitsTheWholeLineWhenTheQueryFails() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFailure(.window("7"), YabaiError.commandFailed(
        argv: ["query", "--windows", "--window", "7"], status: 1
    ))
    yabai.stubFixed(.window("8"), windowDetail(id: .number("8"), display: .number("1"),
                                               space: .number("2"),
                                               frame: Frame(width: "600", height: "400",
                                                            originX: "0", originY: "25")))

    RulePositionReport(yabai: yabai, reporter: reporter).report(rules: "Chat\t7\nCode\t8")

    #expect(reporter.events == [
        .ruleWindowPositionReported(label: "Code", id: "8", display: "1", space: "2",
                                    frame: ReportedFrame(width: "600", height: "400",

                                                         originX: "0", originY: "25")),
    ])
}

/// `.frame` 缺席 → `.frame.w | floor` 是 runtime error → jq 中止 → 整行不出現，
/// **即使 `.id` 好好的**。用 0 或空字串代替那些欄位會讓這一行照樣印出來，而那一行
/// 會宣稱一個從來沒被量到的位置。
@Test func omitsTheWholeLineWhenTheFrameIsMissingEvenThoughTheIDIsFine() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.window("7"), .object([
        JSONMember(key: "id", value: .number("7")),
        JSONMember(key: "display", value: .number("1")),
        JSONMember(key: "space", value: .number("2")),
    ]))

    RulePositionReport(yabai: yabai, reporter: reporter).report(rules: "Chat\t7")

    #expect(reporter.events.isEmpty)
}

/// `.id` 是 null（或欄位缺席）時插值成**字面的 `null`**，不是空字串。
/// 空字串會讓那一行變成 `id= display=`，看起來像量到了一個空的 id。
@Test func interpolatesAbsentScalarFieldsAsTheLiteralNull() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.window("7"), .object([
        JSONMember(key: "display", value: .null),
        JSONMember(key: "space", value: .number("2")),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "w", value: .number("10")),
            JSONMember(key: "h", value: .number("20")),
            JSONMember(key: "x", value: .number("30")),
            JSONMember(key: "y", value: .number("40")),
        ])),
    ]))

    RulePositionReport(yabai: yabai, reporter: reporter).report(rules: "Chat\t7")

    #expect(reporter.events == [
        .ruleWindowPositionReported(label: "Chat", id: "null", display: "null", space: "2",
                                    frame: ReportedFrame(width: "10", height: "20",

                                                         originX: "30", originY: "40")),
    ])
}

/// 沒被運算過的數字逐字保留（`2.50` 不變 `2.5`），而 floor 過的走 dtoa 模型。
/// 兩種形狀在同一行裡，所以「全部轉成 Int」會同時破壞兩邊。
@Test func keepsNumberLiteralsVerbatimButFloorsThroughTheDTOAModel() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()
    yabai.stubFixed(.window("7"), windowDetail(id: .number("2.50"), display: .number("1"),
                                               space: .string("0007"),
                                               frame: Frame(width: "1878.50", height: "1000",
                                                            originX: "0", originY: "25.5")))

    RulePositionReport(yabai: yabai, reporter: reporter).report(rules: "Chat\t7")

    #expect(reporter.events == [
        .ruleWindowPositionReported(label: "Chat", id: "2.50", display: "1", space: "0007",
                                    frame: ReportedFrame(width: "1878", height: "1000",

                                                         originX: "0", originY: "25")),
    ])
}
