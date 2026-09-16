import Testing
import WorkmodeCore
import WorkmodeDomain

// `--space --all`：排這個 profile 底下每一棵有樹的 space，不只可見的那一個。
//
// 成因是拔插螢幕之後 macOS 重排哪個 space 在哪台、哪個可見（2026-09-08 用 IS/IS-NOT
// 追出來的）。fixture 沿用 `spcSpaces`：display 1 上 `U-0`（index 1，不可見）與
// `U-1`（index 2，可見）。兩棵樹各引用一個不同的視窗，所以「排了哪幾棵」從
// `commandArgv` 直接讀得出來。

private let chatWindow = JSONValue.object([
    JSONMember(key: "app", value: .string("Chat")),
    JSONMember(key: "id", value: .number("9")),
])

private func twoTrees() -> JSONValue {
    spcConfig(spaceTrees: [("main", [
        ("U-0", leaf("Code")),
        ("U-1", leaf("Chat")),
    ])])
}

/// `--all` 把不可見那棵也排了。
///
/// 鑑別值是 **兩筆** `--space` 命令，而且第一筆搬到 **space 1**（不可見的那個）。
/// 對照組在下一條：同一份 fixture 走 `.visible` 只有一筆。
@Test func allLaysOutTheInvisibleSpaceToo() {
    let scene = spaceHarness(config: twoTrees(), extraWindows: [chatWindow])
    #expect(scene.runAll("") == .completed(location: "home", profile: "開發"))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "1"],
                                        ["window", "9", "--space", "2"]],
            "不是兩棵都排：\(scene.yabai.commandArgv)")
    #expect(scene.server.calls.count == 2)
    #expect(scene.reporter.events.contains(.space(.spaceLaidOut(role: "main", uuid: "U-0"))))
    #expect(scene.reporter.events.contains(.space(.spaceLaidOut(role: "main", uuid: "U-1"))))
}

/// 對照組：同一份 fixture，`.visible` 只排可見那一棵。
///
/// 沒有這條，上一條在「`.visible` 也偷偷排全部」的實作上照樣綠——那個實作會讓
/// `__space-signal` 每切一格就把十個 space 全部重排。
@Test func visibleStillLaysOutOnlyTheVisibleSpace() {
    let scene = spaceHarness(config: twoTrees(), extraWindows: [chatWindow])
    _ = scene.run("")
    #expect(scene.yabai.commandArgv == [["window", "9", "--space", "2"]],
            "`.visible` 排了不該排的：\(scene.yabai.commandArgv)")
    #expect(scene.server.calls.count == 1)
}

/// 設定裡有樹、但那個 space **不在這台螢幕上**（在另一台）→ 跳過並說出來。
///
/// 用這台的畫布去排一棵其實在別台的樹會把視窗放到螢幕外。鑑別值：`U-9` 那棵
/// **沒有**進 `commandArgv`，而 `spaceNotOnItsDisplay` 有發。
@Test func allSkipsATreeWhoseSpaceIsOnAnotherDisplay() {
    let config = spcConfig(spaceTrees: [("main", [
        ("U-1", leaf("Code")),
        ("U-9", leaf("Chat")),
    ])])
    let spaces = JSONValue.array([
        spcSpace(1, display: 1, uuid: "U-0", visible: false),
        spcSpace(2, display: 1, uuid: "U-1", visible: true),
        // display 2 上的 space；`main` 的螢幕是 display 1。
        spcSpace(3, display: 2, uuid: "U-9", visible: true),
    ])
    let scene = spaceHarness(config: config, extraWindows: [chatWindow], spaces: spaces)
    _ = scene.runAll("")
    #expect(scene.reporter.events.contains(.space(.spaceNotOnItsDisplay(role: "main", uuid: "U-9"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]],
            "排到了別台的 space：\(scene.yabai.commandArgv)")
}

/// 設定裡有樹、但那個 uuid 現在**不存在**（被 macOS 刪了）→ 同一個事件、同一個處置。
@Test func allSkipsATreeWhoseSpaceNoLongerExists() {
    let config = spcConfig(spaceTrees: [("main", [
        ("U-1", leaf("Code")),
        ("U-GONE", leaf("Chat")),
    ])])
    let scene = spaceHarness(config: config, extraWindows: [chatWindow])
    _ = scene.runAll("")
    #expect(scene.reporter.events.contains(.space(.spaceNotOnItsDisplay(role: "main", uuid: "U-GONE"))))
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"]])
}

/// `.visible` **永遠不發** `spaceNotOnItsDisplay`，即使設定裡有一個消失的 uuid。
///
/// 這條守的是「那個事件只屬於 `--all`」：`.visible` 根本不看清單裡的其他 uuid，
/// 看了就等於在每次切 space 時對一份過期的設定抱怨一次。
@Test func visibleNeverReportsAMissingSpace() {
    let config = spcConfig(spaceTrees: [("main", [
        ("U-1", leaf("Code")),
        ("U-GONE", leaf("Chat")),
    ])])
    let scene = spaceHarness(config: config, extraWindows: [chatWindow])
    _ = scene.run("")
    #expect(!scene.reporter.events.contains {
        if case .space(.spaceNotOnItsDisplay) = $0 {
            return true
        }
        return false
    })
}
