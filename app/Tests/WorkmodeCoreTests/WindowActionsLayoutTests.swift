import Testing
import WorkmodeCore
import WorkmodeDomain

/// 兩台螢幕：display 1 有 space 1、2，display 2 有 space 3。焦點在 space 2。
private func twoDisplays(_ rig: HotkeyRig) {
    rig.yabai.stubFixed(.windows, .array([
        windowJSON("1", space: "2", display: "1", frame: frameJSON(1500, 800, 1500, 800)),
    ]))
    rig.yabai.stubFixed(.displays, .array([
        displayJSON("1", uuid: "D1", frame: frameJSON(0, 0, 3000, 1600)),
        displayJSON("2", uuid: "D2", frame: frameJSON(3000, 0, 1500, 800)),
    ]))
    rig.yabai.stubFixed(.spaces, .array([
        spaceJSON("1", display: "1", visible: false),
        spaceJSON("2", display: "1", visible: true),
        spaceJSON("3", display: "2", visible: true),
    ]))
}

@Test func movingToAnAbsoluteSpaceAlsoTakesTheFocusThere() {
    let rig = HotkeyRig()
    twoDisplays(rig)
    rig.actions.run(.moveToSpace(.index(1)))
    #expect(rig.yabai.calls.map(\.argv).contains(["window", "1", "--space", "1"]))
    // 第二半：skhdrc 那條是 `window --space N; space --focus N`，而這條路沒有
    // 「focus 一個 space」的命令——focus 那個視窗會讓 macOS 跟著切過去。
    #expect(rig.control.focusCalls == ["1"])
}

/// `next` 只在**同一台螢幕**的 space 之間繞。跳到別台的話，一個「下一個桌面」
/// 的按鍵會把視窗甩到另一個螢幕上，而畫面上那看起來就是視窗不見了。
@Test func theNextSpaceWrapsWithinTheSameDisplay() {
    let rig = HotkeyRig()
    twoDisplays(rig)
    rig.actions.run(.moveToSpace(.next))
    #expect(rig.yabai.calls.map(\.argv).contains(["window", "1", "--space", "1"]))
    #expect(!rig.yabai.calls.map(\.argv).contains(["window", "1", "--space", "3"]))
}

@Test func anAbsentSpaceIsReportedAndNothingMoves() {
    let rig = HotkeyRig()
    twoDisplays(rig)
    rig.actions.run(.moveToSpace(.index(9)))
    #expect(!rig.yabai.calls.map(\.argv).contains { $0.first == "window" })
    #expect(rig.control.focusCalls.isEmpty)
    #expect(rig.reporter.events.contains(.hotkeySpaceNotFound(target: "9")))
}

/// 跨螢幕保留的是**比例**不是座標。照抄座標會把視窗放到畫面外，
/// 而那與「沒搬過去」在使用者眼裡是同一件事。
@Test func movingToAnotherDisplayRescalesInsteadOfCopyingCoordinates() {
    let rig = HotkeyRig()
    twoDisplays(rig)
    rig.actions.run(.moveToDisplay(.index(2)))
    #expect(rig.yabai.calls.map(\.argv).contains(["window", "1", "--space", "3"]))
    // 來源是 3000×1600 的右下四分之一，目的地是 1500×800 → 同樣的右下四分之一。
    #expect(rig.server.calls == [.init(window: "1",
                                       frame: Rect(originX: 3750, originY: 400,
                                                   width: 750, height: 400))])
}

@Test func anAbsentDisplayIsReportedAndNothingMoves() {
    let rig = HotkeyRig()
    twoDisplays(rig)
    rig.actions.run(.moveToDisplay(.index(5)))
    #expect(rig.server.calls.isEmpty)
    #expect(rig.reporter.events.contains(.hotkeyDisplayNotFound(target: "5")))
}

/// 全螢幕要記得回得去，而且那份記憶要**寫進狀態檔**——快捷鍵每次都可能是新的
/// 行程，記在記憶體的話按第二次就還原不回來。
@Test func fullscreenRemembersThePreviousFrameAcrossProcesses() {
    let first = HotkeyRig()
    first.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(100, 200, 800, 600)),
    ])
    first.actions.run(.toggleFullscreen)
    #expect(first.server.calls == [.init(window: "1",
                                         frame: Rect(originX: 0, originY: 0,
                                                     width: 3000, height: 1600))])
    let saved = first.files.files["/tmp/tatami-test-state"] ?? ""
    #expect(saved.contains("fullscreen.1=100.0,200.0,800.0,600.0"))

    // 換一個 rig ＝換一個行程，只有狀態檔傳過去。
    let second = HotkeyRig(state: saved)
    second.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 3000, 1600)),
    ])
    second.actions.run(.toggleFullscreen)
    #expect(second.server.calls == [.init(window: "1",
                                          frame: Rect(originX: 100, originY: 200,
                                                      width: 800, height: 600))])
}

/// balance 均分的是**樹**：`(1 | (2 | 3))` 變成 1500／750／750，不是各 1000。
/// 這與 yabai 的 `space --balance` 一致。
@Test func balancingEqualisesTheReconstructedTree() {
    let rig = HotkeyRig()
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 2400, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(2410, 0, 90, 1600)),
        windowJSON("3", space: "1", display: "1", frame: frameJSON(2510, 0, 490, 1600)),
    ])
    rig.actions.run(.balanceSpace)
    let widths = Dictionary(uniqueKeysWithValues:
        rig.server.calls.map { ($0.window, $0.frame.width) })
    #expect(widths == ["1": 1500, "2": 750, "3": 750])
}

/// rotate 把每個切割軸橫縱對調：本來左右並排，轉完是上下疊。
@Test func rotatingFlipsTheSplitAxis() {
    let rig = HotkeyRig()
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 1500, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(1510, 0, 1490, 1600)),
    ])
    rig.actions.run(.rotateSpace(clockwise: true))
    #expect(rig.server.calls.count == 2)
    // 轉完兩個都是整片寬、各半高。沒翻的話是各半寬、整片高。
    #expect(rig.server.calls.allSatisfy { $0.frame.width == 3000 })
    #expect(Set(rig.server.calls.map(\.frame.height)) == [800])
}

/// 間隙開了要縮進去，關了要還原。連按兩次不能愈縮愈小——重排前用的是
/// **未加間隙**的畫布。
///
/// 外緣的留白與兩個視窗之間的縫都要恰好等於 `gap`：畫布縮一半、每個葉再縮一半。
/// 只縮其中一邊的話兩者會差一倍，而畫面上那看起來只是「邊緣怪怪的」。
@Test func togglingGapsInsetsAndThenRestores() {
    // 間距的來源是**那台螢幕的設定**，不再是狀態檔的全域 `gap`（2026-09-09 退役）。
    var rig = HotkeyRig()
    rig.grids = ["D1": GridConfig(columns: 6, rows: 4, gap: 10)]
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 1500, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(1500, 0, 1500, 1600)),
    ])
    rig.actions.run(.toggleGaps)
    let left = rig.server.calls[0].frame, right = rig.server.calls[1].frame
    #expect(left == Rect(originX: 10, originY: 10, width: 1485, height: 1580))
    #expect(left.originX == 10) // 外緣
    #expect(right.originX - (left.originX + left.width) == 10) // 中縫，與外緣同寬
    let gapped = rig.files.files["/tmp/tatami-test-state"] ?? ""
    #expect(gapped.contains("gaps=on"))

    let off = HotkeyRig(state: gapped)
    off.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(10, 10, 1485, 1580)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(1505, 10, 1485, 1580)),
    ])
    off.actions.run(.toggleGaps)
    #expect(off.server.calls[0].frame == Rect(originX: 0, originY: 0,
                                              width: 1500, height: 1600))
}

/// balance 與 rotate 也要吃間隙設定。這條是突變抓出來的：`relayout` 裡那個
/// `gapsAreOn(state) ? config(scene).gap : 0` 改成常數 0 時**沒有任何測試轉紅**，
/// 因為當時只有 `toggleGaps` 那條路徑被驗過。
@Test func balancingKeepsTheGapsThatAreAlreadyOn() {
    var rig = HotkeyRig(state: "gaps=on\n")
    rig.grids = ["D1": GridConfig(columns: 6, rows: 4, gap: 10)]
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 2400, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(2410, 0, 590, 1600)),
    ])
    rig.actions.run(.balanceSpace)
    #expect(rig.server.calls[0].frame == Rect(originX: 10, originY: 10,
                                              width: 1485, height: 1580))
}

/// float 清單上的 app 不被 balance 動到——它連**樹都不進**，所以剩下的兩個
/// 照樣均分，而它的 frame 一次 setFrame 都沒收到。
@Test func balancingSkipsTheFloatListedApp() {
    var rig = HotkeyRig()
    rig.floatApps = ["App3"]
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 2400, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(2410, 0, 590, 1600)),
        windowJSON("3", space: "1", display: "1", frame: frameJSON(500, 500, 400, 300)),
    ])
    rig.actions.run(.balanceSpace)
    #expect(!rig.server.calls.map(\.window).contains("3"))
    // 剩下兩個均分整片畫布——排除是在建樹之前，不是排完再跳過。
    let widths = Dictionary(uniqueKeysWithValues:
        rig.server.calls.map { ($0.window, $0.frame.width) })
    #expect(widths == ["1": 1500, "2": 1500])
}

/// 最小化的視窗也不進版面。`.windows` 不回報 `is-minimized`，所以要對候選
/// 逐一問 `.window(id)`；**查不到 deep 資訊的當沒有最小化**（多排是看得見的錯，
/// 踢掉是靜默的）——視窗 1 沒有 stub `.window`，它必須照樣被排。
@Test func balancingSkipsMinimizedWindowsAndKeepsUnknownOnes() {
    let rig = HotkeyRig()
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 1500, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(1510, 0, 1490, 1600)),
    ])
    rig.yabai.stubFixed(.window("2"), .object([
        JSONMember(key: "id", value: .number("2")),
        JSONMember(key: "is-minimized", value: .bool(true)),
    ]))
    rig.actions.run(.balanceSpace)
    #expect(rig.server.calls.map(\.window) == ["1"])
    #expect(rig.server.calls[0].frame == Rect(originX: 0, originY: 0,
                                              width: 3000, height: 1600))
}

/// **查得到 deep 資訊而 `is-minimized` 是 false 的視窗照樣要排。**
///
/// 這條是突變補的：上一條只有「沒有 stub」與「stub 成 true」兩種，於是
/// 把整個判斷換成「`.window(id)` 問得到就當最小化」**照樣全綠**——兩個 fixture
/// 在那個錯誤實作下答案剛好都對。少了這一條，那道守衛沒有鑑別力。
@Test func aWindowThatReportsNotMinimizedStaysInTheLayout() {
    let rig = HotkeyRig()
    rig.stubOneDisplay([
        windowJSON("1", space: "1", display: "1", frame: frameJSON(0, 0, 1500, 1600)),
        windowJSON("2", space: "1", display: "1", frame: frameJSON(1510, 0, 1490, 1600)),
    ])
    for id in ["1", "2"] {
        rig.yabai.stubFixed(.window(id), .object([
            JSONMember(key: "id", value: .number(id)),
            JSONMember(key: "is-minimized", value: .bool(false)),
        ]))
    }
    rig.actions.run(.balanceSpace)
    #expect(rig.server.calls.map(\.window) == ["1", "2"])
}
