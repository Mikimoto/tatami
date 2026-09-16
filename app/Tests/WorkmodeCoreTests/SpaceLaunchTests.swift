import Testing
import WorkmodeCore
import WorkmodeDomain

// `--space --launch`：把這一輪的樹引用到、而目前沒在跑的 app 開起來。
//
// 接線在 `SpaceLayoutFixtures.swift` 的 `spaceHarness(launch:running:)`。
// `spcConfig` 的 `windows` 有兩條 app 規則（`Code` → `Ghostty`、`Chat` → `Chat`）
// 而預設的樹只引用 `Code`——那是這三條共同的鑑別值：正確的實作只碰 `Ghostty`，
// 「整份設定的 app 都開起來」的實作會多一個 `Chat`。

/// 傳了 `presence` 而那個 app 沒在跑 → 真的叫 `open`。
///
/// 鑑別值：`["Ghostty"]`。`["Ghostty", "Chat"]` ＝ 沒有用 label 過濾；
/// `[]` ＝ 根本沒接上（而回傳值仍然是 `.completed`，所以斷言不能打在它身上）。
@Test func launchOpensAnApplicationThatTheTreeNeeds() {
    let scene = spaceHarness(launch: true, running: ["Ghostty": false])
    #expect(scene.run("") == .completed(location: "home", profile: "開發"))
    #expect(scene.launcher.opened == ["Ghostty"], "開錯了：\(scene.launcher.opened)")
}

/// **沒傳 `presence` → 兩個 port 一次都沒被碰過。**
///
/// 斷言的是呼叫紀錄而不是回傳值：`.completed` 在「什麼都沒開」與「開了一堆」
/// 兩種情況下都一樣。`asked` 是關鍵的那一半——`ensure` 的第一個動作是
/// `isRunning`，所以把 nil 判斷拿掉、讓它無條件跑一遍的實作會在這裡留下痕跡，
/// 即使那個 app 剛好在跑而一個 `open` 都沒下。
///
/// 這是預設的行為：`__space-signal`（每次切 space）與編輯器的 ⌘R 走的都是這條。
@Test func withoutPresenceNoApplicationPortIsTouched() {
    let scene = spaceHarness(running: ["Ghostty": false])
    #expect(scene.run("") == .completed(location: "home", profile: "開發"))
    #expect(scene.apps.asked.isEmpty, "不該問的卻問了：\(scene.apps.asked)")
    #expect(scene.launcher.opened.isEmpty, "不該開的卻開了：\(scene.launcher.opened)")
}

/// 已經在跑的 app 不再開一次。
///
/// 鑑別值：`opened` 是空的而 `asked` 是 `["Ghostty"]`——兩個一起斷言才分得出
/// 「問過了、答案是在跑」與「根本沒接上」（後者兩個都是空的）。
@Test func anApplicationAlreadyRunningIsNotOpenedAgain() {
    let scene = spaceHarness(launch: true, running: ["Ghostty": true])
    _ = scene.run("")
    #expect(scene.apps.asked == ["Ghostty"], "問的對象不對：\(scene.apps.asked)")
    #expect(scene.launcher.opened.isEmpty, "已經在跑還開了一次：\(scene.launcher.opened)")
}

// MARK: - probe 模式

// `--probe` 2026-09-07 從 `ApplyLayout` 搬到這一支的一個模式。它唯一的保證是
// **一個會改變狀態的命令都不下**，而那要拿同一個 harness 兩邊各跑一次才驗得出來。

/// probe 不下任何 command，也不設任何 frame。
///
/// 鑑別值是**兩個紀錄本都空**：`yabai.commands` 空而 `server.frames` 空。
/// 只驗前者的話「改用 `setFrame` 排版」的實作照樣通過，而那正是這條路現在的引擎。
/// 對照組是同一份 fixture 跑 `.apply`——它必須**不**是空的，不然這條測試在守一個
/// 恆真句（fixture 本來就什麼都不排）。
@Test func probeIssuesNoCommandsAndSetsNoFrames() {
    let probed = spaceHarness()
    #expect(probed.probe("") == .completed(location: "home", profile: "開發"))
    #expect(probed.yabai.commandArgv.isEmpty, "probe 下了 command：\(probed.yabai.commandArgv)")
    #expect(probed.server.calls.isEmpty, "probe 設了 frame：\(probed.server.calls)")

    let applied = spaceHarness()
    _ = applied.run("")
    #expect(!applied.server.calls.isEmpty, "對照組沒排任何東西，這個 fixture 沒有鑑別力")
}

/// probe **不開 app**，即使呼叫端傳了 `presence`。
///
/// 鑑別值：`launcher.opened` 空。`open -a` 是會改變狀態的，而「probe 不改狀態」
/// 這個保證不能靠呼叫端記得傳 nil——`--probe --launch` 打得出來。
@Test func probeDoesNotOpenApplicationsEvenWithPresence() {
    let scene = spaceHarness(launch: true, running: ["Ghostty": false])
    _ = scene.probe("")
    #expect(scene.apps.asked.isEmpty, "probe 問了 app 在不在跑：\(scene.apps.asked)")
    #expect(scene.launcher.opened.isEmpty, "probe 開了 app：\(scene.launcher.opened)")
}

/// probe 印 probe 的抬頭，套用不印。
@Test func onlyProbePrintsTheProbeBanner() {
    let probed = spaceHarness()
    _ = probed.probe("")
    #expect(probed.reporter.events.contains(.probeBannerShown))

    let applied = spaceHarness()
    _ = applied.run("")
    #expect(!applied.reporter.events.contains(.probeBannerShown))
}
