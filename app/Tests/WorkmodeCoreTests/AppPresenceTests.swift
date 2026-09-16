import Testing
import WorkmodeCore

// 這一組守兩件事：那四句話各自的觸發條件，以及**輪詢的形狀**。
//
// `ensure_app` 是先睡再查，`restore_minimized` 是先查再睡。兩者統一成同一個樣子在
// 畫面上看不出來（訊息文字一樣），只有等待秒數與睡眠次數會變，所以那個形狀必須有
// 專門的斷言：這裡是 `sleepsBeforeItsFirstPollSoASuccessfulLaunchStillWaitsOneSecond`，
// 對應的另一條是 MinimizedWindowsTests 的
// `doesNotSleepAtAllWhenTheWindowComesBackImmediately`。

private func presence(_ apps: FakeAppQuery, _ launcher: FakeAppLauncher,
                      _ clock: FakeClock, _ reporter: FakeReporter) -> AppPresence
{
    AppPresence(apps: apps, launcher: launcher, clock: clock, reporter: reporter)
}

/// 已經在跑：**零輸出、零命令**（連「沒在跑」那句都不印）。
@Test func staysSilentWhenTheAppIsAlreadyRunning() {
    let apps = FakeAppQuery()
    apps.stub("Safari", [true])
    let launcher = FakeAppLauncher()
    let clock = FakeClock()
    let reporter = FakeReporter()

    #expect(presence(apps, launcher, clock, reporter).ensure(app: "Safari"))
    #expect(reporter.events.isEmpty)
    #expect(launcher.opened.isEmpty)
    #expect(clock.slept.isEmpty)
    #expect(apps.asked == ["Safari"])
}

/// 第三次輪詢才查到。訊息帶的數字是迴圈計數（3），睡眠恰好三次。
///
/// 這條同時釘住「先睡再查」：改成先查再睡的話，同一組回應會在睡兩次之後就查到
/// （`slept == [1, 1]`）並報 2。
@Test func sleepsBeforeItsFirstPollSoASuccessfulLaunchStillWaitsOneSecond() {
    let apps = FakeAppQuery()
    // 第一次是啟動前的判斷，之後每一次都是輪詢。
    apps.stub("Chat", [false, false, false, true])
    let launcher = FakeAppLauncher()
    let clock = FakeClock()
    let reporter = FakeReporter()

    #expect(presence(apps, launcher, clock, reporter).ensure(app: "Chat"))

    #expect(launcher.opened == ["Chat"])
    #expect(clock.slept == [1, 1, 1], "先睡再查的形狀壞了")
    #expect(reporter.events == [.appNotRunning(app: "Chat"),
                                .appLaunched(app: "Chat", waitedSeconds: 3)])
    #expect(apps.asked.count == 4)
}

/// workmode.sh:625。`open -a` 失敗 → 那句話 ＋ 回 false，而且**一次都不睡**。
@Test func reportsTheFailureAndStopsWhenTheAppCannotBeOpened() {
    let apps = FakeAppQuery()
    apps.stubFixed("Chat", false)
    let launcher = FakeAppLauncher()
    launcher.error = AppLauncherError.openFailed(app: "Chat", status: 1)
    let clock = FakeClock()
    let reporter = FakeReporter()

    #expect(!presence(apps, launcher, clock, reporter).ensure(app: "Chat"))

    #expect(reporter.events == [.appNotRunning(app: "Chat"),
                                .appLaunchFailed(app: "Chat")])
    #expect(clock.slept.isEmpty)
    // 啟動前問過一次，之後沒有輪詢。
    #expect(apps.asked == ["Chat"])
}

/// 逾時：睡滿 `APP_WAIT_SECONDS` 次，訊息帶的是**常數 10**。
///
/// `waitedSeconds` 與 `seconds` 在這裡剛好相等，所以這條只驗得到「數字是 10」；
/// 「來源是常數而不是迴圈計數」由上一條（第 3 次成功時報 3）一起夾住。
///
/// 實測過：把那句話的 `Self.waitSeconds` 換成 `waited` **不會有任何測試轉紅**，
/// 而那不是覆蓋缺口——這一行唯一的到達方式是迴圈跑滿，此時 `waited` 恆等於
/// `waitSeconds`，兩種寫法在行為上不可區分。真的會變的形狀（`waited + 1`）實測
/// 讓這一條轉紅，所以這裡的數字是被斷言著的，不是恆真。
@Test func reportsATimeoutAfterSleepingTheFullWaitBudget() {
    let apps = FakeAppQuery()
    apps.stubFixed("Chat", false)
    let launcher = FakeAppLauncher()
    let clock = FakeClock()
    let reporter = FakeReporter()

    #expect(!presence(apps, launcher, clock, reporter).ensure(app: "Chat"))

    #expect(clock.slept.count == AppPresence.waitSeconds)
    #expect(clock.elapsed == 10)
    #expect(reporter.events == [.appNotRunning(app: "Chat"),
                                .appLaunchTimedOut(app: "Chat", seconds: 10)])
    // 一次啟動前判斷 ＋ 十次輪詢。
    #expect(apps.asked.count == AppPresence.waitSeconds + 1)
}

/// 最後一次輪詢（第 10 次）查到仍算成功，不是逾時——邊界差一就會把它報成失敗。
@Test func stillCountsAsLaunchedWhenTheLastPollFindsIt() {
    let apps = FakeAppQuery()
    apps.stub("Chat", Array(repeating: false, count: 10) + [true])
    let launcher = FakeAppLauncher()
    let clock = FakeClock()
    let reporter = FakeReporter()

    #expect(presence(apps, launcher, clock, reporter).ensure(app: "Chat"))

    #expect(clock.slept.count == 10)
    #expect(reporter.events.last == .appLaunched(app: "Chat", waitedSeconds: 10))
}
