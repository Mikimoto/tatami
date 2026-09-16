import Testing
import WorkmodeCore
import WorkmodeDomain

// 只驗 fake 自己：回放、順序、沒塞回應會炸。use case 的測試是後面的事。
// 這三條存在的理由是 fake 本身也是未經驗證的程式碼——它靜默回空值的話，
// 後面每一條測試都會為了錯的理由通過。

/// 依序回放 ＋ 跨 query/command 的順序都記得。
///
/// 用的是 apply_ratio 的真實序列（workmode.sh:832-839）：設 ratio → 量自己 →
/// 量 sibling → 發現比較窄 → 設 1-ratio。順序記錄壞掉的話，「量測搬到 ratio 之前」
/// 這個錯誤在斷言上看不出來。
@Test func replaysQueriesInOrderAndKeepsTheWholeCallLog() throws {
    let yabai = FakeYabai()
    yabai.stub(.window("7"), [
        .object([JSONMember(key: "frame", value: .object([JSONMember(key: "w", value: .number("626"))]))]),
        .object([JSONMember(key: "frame", value: .object([JSONMember(key: "w", value: .number("1878"))]))]),
    ])

    try yabai.run(.setRatio(window: "7", ratio: "0.75"))
    let first = try yabai.query(.window("7"))
    try yabai.run(.setRatio(window: "7", ratio: "0.2500"))
    let second = try yabai.query(.window("7"))

    #expect(first != second, "第二次問同一個 query 必須拿到第二個回應，不是重複第一個")
    #expect(yabai.allArgv == [
        ["window", "7", "--ratio", "abs:0.75"],
        ["query", "--windows", "--window", "7"],
        ["window", "7", "--ratio", "abs:0.2500"],
        ["query", "--windows", "--window", "7"],
    ])
}

/// 沒塞回應時丟錯，而且鍵是 argv——`--window 7` 與 `--space 7` 不能互相頂替。
@Test func throwsInsteadOfReturningEmptyForAnUnstubbedCall() throws {
    let yabai = FakeYabai()
    yabai.stubFixed(.windowsOnSpace("7"), .array([]))

    #expect(throws: (any Error).self) { try yabai.query(.window("7")) }
    // 回應用完了與根本沒塞是兩種不同的錯，兩者都不得靜默。
    yabai.stub(.spaces, [.array([])])
    _ = try yabai.query(.spaces)
    #expect(throws: (any Error).self) { try yabai.query(.spaces) }
}

/// FakeClock 不真的睡：restore_minimized 的 20 × 0.1s 加 ensure_app 的 10 × 1s
/// 全部走完，虛擬時間是 12 秒，牆上時間必須是瞬間。
@Test func clockAdvancesInstantly() {
    let clock = FakeClock()
    let wall = ContinuousClock().measure {
        for _ in 0 ..< 20 {
            clock.sleep(seconds: 0.1)
        }
        for _ in 0 ..< 10 {
            clock.sleep(seconds: 1)
        }
    }

    #expect(clock.slept.count == 30)
    #expect(clock.elapsed > 11.9 && clock.elapsed < 12.1)
    #expect(wall < .milliseconds(200), "FakeClock 真的睡了——後面每條輪詢測試都會慢好幾秒")
}
