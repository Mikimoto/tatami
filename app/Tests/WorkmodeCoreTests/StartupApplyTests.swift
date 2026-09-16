import Testing
import WorkmodeCore

@Test func itStopsAtTheFirstSuccess() {
    var apply = StartupApply()
    #expect(apply.shouldTry)
    apply.record(.locationUnrecognized)
    #expect(apply.shouldTry) // 螢幕還沒接齊，再試
    apply.record(.completed(location: "office", profile: "開發"))
    #expect(apply.succeeded)
    #expect(!apply.shouldTry)
    // 成功之後就算再餵一次失敗也不重開重試——那段 shell 的 `&& break`。
    apply.record(.locationUnrecognized)
    #expect(!apply.shouldTry)
}

/// 窗口是 10 次，不是無限。無限重試會讓一台永遠接不到外接螢幕的機器
/// 每 3 秒重排一次視窗。
@Test func itGivesUpAfterTenAttempts() {
    var apply = StartupApply()
    for _ in 0 ..< StartupApply.attempts {
        #expect(apply.shouldTry)
        apply.record(.locationUnrecognized)
    }
    #expect(!apply.shouldTry)
    #expect(!apply.succeeded)
    #expect(apply.tried == 10)
}

/// **只有 `.completed` 算成功。** 其餘三種都要繼續試——`profileUnresolved` 與
/// `layoutUnavailable` 在登入當下也可能是暫時的（設定檔還在同步、home 還沒掛上）。
/// 這條與 CLI 的 exit code 對齊：`guard case .completed = outcome else { exit(1) }`。
@Test func onlyCompletedCountsAsSuccess() {
    for outcome in [SpaceLayout.Outcome.locationUnrecognized, .profileUnresolved,
                    .layoutUnavailable(.missing(path: "/nope"))]
    {
        var apply = StartupApply()
        apply.record(outcome)
        #expect(!apply.succeeded, "\(outcome)")
        #expect(apply.shouldTry)
    }
}
