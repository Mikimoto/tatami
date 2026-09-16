import Testing
import WorkmodeCore
import WorkmodeDomain

/// 三個並排的視窗，焦點在中間那個。
private func threeInARow(_ rig: HotkeyRig) {
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 1000, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(1000, 0, 1000, 1600)),
        windowJSON("3", space: "1", display: "1", frame: frameJSON(2000, 0, 1000, 1600)),
    ])
    rig.control.focused = "2"
}

@Test func focusingWestHandsTheFocusOverWithoutMovingAnything() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.actions.run(.focusWindow(.west))
    #expect(rig.control.focusCalls == ["1"])
    // 「focus 不搬視窗」是這個動作的全部意義——設一次 frame 就是實作走錯了。
    #expect(rig.server.calls.isEmpty)
}

/// 沒有鄰居時**一件事都不做**，而且說出來。
/// 斷言在 `calls.isEmpty` 而不只是那個事件：先動手再檢查的實作照樣會發事件。
@Test func focusingIntoAnEmptyDirectionTouchesNothing() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.control.focused = "1"
    rig.actions.run(.focusWindow(.west))
    #expect(rig.control.focusCalls.isEmpty)
    #expect(rig.server.calls.isEmpty)
    #expect(rig.reporter.events.contains(.hotkeyNoNeighbour(direction: "west")))
}

@Test func swappingExchangesBothFramesAndNothingElse() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.actions.run(.swapWindow(.east))
    #expect(rig.server.calls.count == 2)
    // 焦點視窗拿到鄰居的位置，鄰居拿到焦點視窗的位置。單向的實作只會有一次呼叫。
    #expect(rig.server.calls[0] == .init(window: "2",
                                         frame: Rect(originX: 2000, originY: 0,
                                                     width: 1000, height: 1600)))
    #expect(rig.server.calls[1] == .init(window: "3",
                                         frame: Rect(originX: 1000, originY: 0,
                                                     width: 1000, height: 1600)))
}

/// stack 是單向的：鄰居不動，只有焦點視窗疊上去。
@Test func stackingMovesOnlyTheFocusedWindow() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.actions.run(.stackWindow(.west))
    #expect(rig.server.calls.map(\.window) == ["2"])
    #expect(rig.server.calls[0].frame == Rect(originX: 0, originY: 0, width: 1000, height: 1600))
    #expect(rig.control.focusCalls == ["2"])
}

@Test func cyclingAStackWrapsAroundAndDoesNothingWhenAlone() {
    let rig = HotkeyRig()
    // 三個疊在同一個位置。
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 800, 600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(0, 0, 800, 600)),
        windowJSON("3", space: "1", display: "1", frame: frameJSON(0, 0, 800, 600)),
    ])
    rig.control.focused = "3"
    rig.actions.run(.focusStack(next: true))
    #expect(rig.control.focusCalls == ["1"]) // 繞回第一個

    let alone = HotkeyRig()
    threeInARow(alone)
    alone.actions.run(.focusStack(next: true))
    #expect(alone.control.focusCalls.isEmpty)
    #expect(alone.reporter.events.contains(.hotkeyNoNeighbour(direction: "stack.next")))
}

/// 右下那一格，**扣掉間距之後**的樣子。
///
/// 這條原本斷言 `(1500, 800, 1500, 800)`，也就是不含間距的那一格；2026-09-09
/// 起格線放置會套那台螢幕的間距（預設 8），所以每邊各縮 4——落點位移是使用者
/// 選過的，不是回歸。畫布是 `stubOneDisplay` 的 `(0,0,3000,1600)`。
@Test func aGridCellCoversItsQuarterMinusTheGap() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.actions.run(.placeGrid(rows: 2, columns: 2, originX: 1, originY: 1,
                               width: 1, height: 1))
    #expect(rig.server.calls == [.init(window: "2",
                                       frame: Rect(originX: 1504, originY: 804,
                                                   width: 1488, height: 788))])
}

/// 格線放置會套那台螢幕的間距（2026-09-09 使用者裁決）。
///
/// 鑑別力在**與不套間距的落點不同**：只斷言「有下一個 setFrame」的話，
/// 套 0 與套 20 都會過。
@Test func placingOnTheGridUsesThatDisplaysGap() {
    var rig = HotkeyRig()
    rig.grids = ["D1": GridConfig(columns: 2, rows: 1, gap: 20)]
    threeInARow(rig)
    rig.actions.run(.placeGrid(rows: 1, columns: 2, originX: 0, originY: 0,
                               width: 1, height: 1))
    guard let placed = rig.server.calls.last else {
        Issue.record("沒有設過 frame")
        return
    }
    // 畫布是 (0,0,3000,1600)（見 `stubOneDisplay`）。左半加上兩處各縮 10：
    // x = 0 + 10 + 10 = 20、w = (3000 - 20) / 2 - 20 = 1470。
    #expect(abs(placed.frame.originX - 20) < 1e-9)
    #expect(abs(placed.frame.width - 1470) < 1e-9)
}

/// 對照組：那台螢幕沒設過就用預設的 8。少了它，「一律套 20」與正確的
/// 查表分不出來。
@Test func anUnlistedDisplayFallsBackToTheDefaultGap() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.actions.run(.placeGrid(rows: 1, columns: 2, originX: 0, originY: 0,
                               width: 1, height: 1))
    guard let placed = rig.server.calls.last else {
        Issue.record("沒有設過 frame")
        return
    }
    #expect(abs(placed.frame.originX - 8) < 1e-9)
    #expect(abs(placed.frame.width - 1488) < 1e-9)
}

@Test func closingPressesTheCloseButtonAndMovesNothing() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.actions.run(.closeWindow)
    #expect(rig.control.closeCalls == ["2"])
    #expect(rig.server.calls.isEmpty)
}

@Test func withoutAFocusedWindowNothingHappensAndItSaysSo() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.control.focused = nil
    rig.actions.run(.swapWindow(.east))
    #expect(rig.server.calls.isEmpty)
    #expect(rig.reporter.events.contains(.hotkeyNoFocusedWindow))
}

/// `shell:` 在讀畫面**之前**就分岔。為了一條開桌面的命令去掃 219 個視窗是白付的，
/// 而那件事只有「一次 query 都沒發生」證明得了。
@Test func aShellBindingNeverLooksAtTheWindowList() {
    let rig = HotkeyRig()
    threeInARow(rig)
    rig.actions.run(.runShell("echo hi"))
    #expect(rig.shell.commands == ["echo hi"])
    #expect(rig.yabai.calls.isEmpty)

    let failing = HotkeyRig()
    failing.shell.failWith = 3
    failing.actions.run(.runShell("nope"))
    #expect(failing.reporter.events.contains(.hotkeyShellFailed(command: "nope", status: 3)))
}
