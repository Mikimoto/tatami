import Testing
import WorkmodeCore
import WorkmodeDomain

// `restore_minimized`（workmode.sh:643-661）。這一支在 bash 那側沒有任何自動化
// 保護——它會呼叫 yabai，而 bash 沒有接縫可以塞假的 yabai。所以下面這四條是
// 「移植買到的東西」的第一批：那條「`--deminimize` 之後不能立刻查 `is-minimized`」
// 的不變式第一次被釘住，而且**輪詢的形狀**（先查、再遞增、再睡）也釘住了。

private func minimizedFlag(_ value: JSONValue) -> JSONValue {
    .object([JSONMember(key: "is-minimized", value: value)])
}

private let minimized = minimizedFlag(.bool(true))
private let restored = minimizedFlag(.bool(false))

/// 實測這台機器上 `is-minimized` 固定要 ~600ms 才翻成 false（三次量測都是第 6 次
/// 輪詢）。所以這條驗的是它**真的等**：睡 5 次之後第 6 次查詢才拿到 false。
///
/// 若把迴圈寫成「先睡再查」，總睡眠次數會變成 6——這條的 `slept` 斷言會紅。
@Test func waitsThroughTheRestoreAnimationBeforeCallingItRestored() {
    let yabai = FakeYabai()
    let clock = FakeClock()
    let reporter = FakeReporter()
    // 第一筆是進場的那道 `= "true"` 閘門，後面六筆是輪詢。
    yabai.stub(.window("7"), [minimized, minimized, minimized, minimized,
                              minimized, minimized, restored])

    MinimizedWindows(yabai: yabai, clock: clock, reporter: reporter).restore(map: "Chat\t7")

    #expect(clock.slept == [0.1, 0.1, 0.1, 0.1, 0.1])
    #expect(reporter.events == [.minimizedWindowRestored(label: "Chat")])
    #expect(yabai.commandArgv == [["window", "--deminimize", "7"]])
}

/// 迴圈是先查、再遞增、再睡，所以 `i == 0` 那次查詢是**立刻**發生的。
/// 若它已經還原了就一次都不睡——這條是「先睡再查」那個改寫唯一擋不掉的形狀。
@Test func doesNotSleepAtAllWhenTheWindowComesBackImmediately() {
    let yabai = FakeYabai()
    let clock = FakeClock()
    let reporter = FakeReporter()
    yabai.stub(.window("7"), [minimized, restored])

    MinimizedWindows(yabai: yabai, clock: clock, reporter: reporter).restore(map: "Chat\t7")

    #expect(clock.slept.isEmpty, "先查再睡的形狀壞了：它在第一次查詢之前就睡了")
    #expect(reporter.events == [.minimizedWindowRestored(label: "Chat")])
}

/// 20 次查詢都仍是最小化：`i` 變成 20 並**再睡一次**才離開迴圈，所以是 20 次睡眠
/// 對 20 次查詢（不是 19）。收尾走失敗事件。
@Test func reportsFailureAfterTwentyPollsAndSleepsTwentyTimes() {
    let yabai = FakeYabai()
    let clock = FakeClock()
    let reporter = FakeReporter()
    yabai.stub(.window("7"), Array(repeating: minimized, count: 21))

    MinimizedWindows(yabai: yabai, clock: clock, reporter: reporter).restore(map: "Chat\t7")

    #expect(clock.slept.count == MinimizedWindows.restorePolls)
    #expect(reporter.events == [.minimizedWindowRestoreFailed(label: "Chat")])
    // 21 次 = 1 道閘門 + 20 次輪詢。多一次就代表有人多問了一輪。
    // 只數 query：`allArgv` 含那次 `--deminimize` 命令（實測，第一版斷言就是為此紅的）。
    #expect(yabai.allArgv.filter { $0.first == "query" }.count == 21)
    #expect(yabai.commandArgv == [["window", "--deminimize", "7"]])
}

/// `[ … = "true" ] || continue`：只有字串 `"true"` 才動它。false、欄位缺席
/// （jq -r 印 `null`）、query 失敗（空字串）三種都跳過，而且**完全不下命令**。
@Test func neverDeminimizesWindowsThatAreNotMinimized() {
    let yabai = FakeYabai()
    let clock = FakeClock()
    let reporter = FakeReporter()
    yabai.stubFixed(.window("7"), restored)
    yabai.stubFixed(.window("8"), .object([])) // 欄位缺席 → "null"
    yabai.stubFixed(.window("9"), .array([])) // 不是物件 → 空字串
    yabai.stubFailure(.window("10"), YabaiError.malformedOutput(argv: []))

    MinimizedWindows(yabai: yabai, clock: clock, reporter: reporter)
        .restore(map: "A\t7\nB\t8\nC\t9\nD\t10")

    #expect(yabai.commandArgv.isEmpty)
    #expect(clock.slept.isEmpty)
    // 跳過的視窗一句話都不說：bash 那兩個 printf 都在閘門之後。
    #expect(reporter.events.isEmpty)
}

/// `[ -z "${id}" ] && continue`：沒有 id 的行跳過，而空的 map 也是一輪
/// （here-string 會補換行），照樣什麼都不做。
@Test func skipsLinesWithoutAWindowID() {
    let yabai = FakeYabai()
    let clock = FakeClock()
    let reporter = FakeReporter()
    yabai.stub(.window("7"), [minimized, restored])

    MinimizedWindows(yabai: yabai, clock: clock, reporter: reporter)
        .restore(map: "NoID\nAlso no id\t\n\nChat\t7")

    #expect(yabai.commandArgv == [["window", "--deminimize", "7"]])
    #expect(reporter.events == [.minimizedWindowRestored(label: "Chat")])
}

/// `IFS=$'\t' read -r label id` 的四個實測行為（見 `BashRead`）。label 進的是
/// 使用者看到的那句話，錯一個字就是報錯視窗的名字。
@Test func splitsLinesTheWayBashReadDoes() {
    let yabai = FakeYabai()
    let clock = FakeClock()
    let reporter = FakeReporter()
    yabai.stubFixed(.window("5"), restored)
    yabai.stubFixed(.window("7\t9"), restored)

    MinimizedWindows(yabai: yabai, clock: clock, reporter: reporter)
        // "A\t\t5" → id=5（連續 tab 算一個）；"\tC\t3\t\t" 的尾端 tab 被剝掉；
        // "B\t7\t9" 的 id 是剩下的整段。
        .restore(map: "A\t\t5\nB\t7\t9\n\tC\t5\t\t")

    #expect(yabai.allArgv == [
        ["query", "--windows", "--window", "5"],
        ["query", "--windows", "--window", "7\t9"],
        ["query", "--windows", "--window", "5"],
    ])
    #expect(reporter.events.isEmpty, "三筆都不是最小化的，不該有任何訊息")
}
