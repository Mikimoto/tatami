import Testing
import WorkmodeCore
import WorkmodeDomain

// 頂端 inset 的自動校準（2026-09-03）。
//
// 背景：macOS 不讓任何視窗的 y 小於「螢幕 frame 頂端 ＋ 那台螢幕的選單列高」，
// 而那個高度沒有任何 API 吐得出來（實測 display 2 的 frame 頂端 -1026，設下去
// AX 讀回來 -996，差 30pt；`NSScreen.visibleFrame` 與 `safeAreaInsets` 對外接螢幕
// 全是 0）。所以只能設一次、量回來、記進狀態檔。
//
// 這幾條全部走 fake：`FakeWindowServer.actual` 扮演「app 把 frame 夾掉」，
// `FakeFileStore.writes` 是「有沒有寫狀態檔」唯一的觀測量——回傳值在寫與不寫
// 兩種情況下都是 `.completed`。

/// 畫布是 `spcCanvas`（0,0,3456.5,2234），所以單葉樹要求的就是它；把實際落點往下
/// 推 30pt 而寬高不動，就是真實世界那個形狀。
private let clampedBy30 = Rect(originX: 0, originY: 30, width: 3456.5, height: 2234)

/// 寫進狀態檔的內容（`writes` 只有一筆時取它）。
private func stateWritten(_ scene: SpaceScene) -> String? {
    scene.files.writes.first { $0.path == spcStatePath }?.contents
}

/// 1. 頂端那一列被往下推 → 學到 inset 並寫進狀態檔。
///
/// 鑑別值是 **30**：`topinset.A=30`。學成別的基準（例如拿畫布頂端而不是螢幕原始
/// frame 頂端）在這個 fixture 上同值（inset 本來是 0），所以第 5 條才是那半的守衛。
/// 這條守的是「有沒有學、有沒有寫」——不學的實作 `writes` 是空的。
@Test func aClampedTopRowTeachesTheInset() {
    let scene = spaceHarness()
    scene.server.actual["7"] = clampedBy30
    _ = scene.run("")
    #expect(stateWritten(scene)?.contains("topinset.A=30") == true,
            "沒有把學到的 inset 寫進狀態檔：\(scene.files.writes)")
}

/// 2. 學到之後**不**報 `frameRejected`——那個差異已經被解釋掉了。
///
/// 鑑別值：事件清單裡一個 `frameRejected` 都沒有。豁免那段拿掉的話，這個視窗每一輪
/// 都會印一句假的失敗（而且要等滿 `setFrame` 的輪詢預算）。
@Test func aLearnedClampIsNotReportedAsARejection() {
    let scene = spaceHarness()
    scene.server.actual["7"] = clampedBy30
    _ = scene.run("")
    #expect(!scene.reporter.events.contains { event in
        if case .space(.frameRejected) = event {
            return true
        }
        return false
    }, "學到的 inset 仍被報成拒絕：\(scene.reporter.events)")
}

/// 3. y 被夾**而且** x 也不對 → 仍然是真的拒絕。
///
/// 鑑別值：`originX` 的 **5**。豁免整個矩形（而不是只豁免 y）的實作在這裡不會出聲，
/// 於是「app 把視窗推到別的地方」永遠沒有人說。
@Test func aClampInXAsWellIsStillARejection() {
    let scene = spaceHarness()
    scene.server.actual["7"] = Rect(originX: 5, originY: 30, width: 3456.5, height: 2234)
    _ = scene.run("")
    #expect(scene.reporter.events.contains { event in
        if case .space(.frameRejected) = event {
            return true
        }
        return false
    }, "x 也對不上卻沒有報拒絕：\(scene.reporter.events)")
    // 而且**不准學**。這半是 2026-09-03 用一份壞掉的線上狀態檔換來的：見下一條。
    #expect(stateWritten(scene) == nil,
            "橫向沒到位的樣本被拿去校準了：\(scene.files.writes)")
}

/// 3b. **沒有搬到目標螢幕的視窗不准教任何東西。**
///
/// 真實事故（2026-09-03）：`space_changed` signal 跑 `--space` 時，有個視窗沒有被搬到
/// 目標螢幕、還留在內建螢幕的 `y=34`，而它要求的 y 是另一台螢幕的畫布頂端 `-1026`。
/// 當時的守衛只問「要求的 y 是不是畫布頂端」與「實際有沒有被往下推」，兩個都成立，
/// 於是它教出 `34 − (−1026) = 1060` 並寫進狀態檔——1060pt 的 inset 會把那台螢幕的
/// 畫布砍掉四分之三，而下一輪讀到它時沒有任何訊號說它是垃圾。
///
/// 鑑別值是 **originX 的 -1728**（左邊那台螢幕）配上一個**大得離譜卻仍在螢幕高度內**
/// 的 originY：拿「算出來的值合不合理」當關卡的實作在這裡會放行，因為 1060 對一台
/// 1440 高的螢幕來說並不出格。只有問「橫向到位了嗎」才擋得住。
@Test func aWindowLeftOnAnotherDisplayTeachesNothing() {
    let scene = spaceHarness()
    scene.server.actual["7"] = Rect(originX: -1728, originY: 1060, width: 3456.5, height: 2234)
    _ = scene.run("")
    #expect(stateWritten(scene) == nil,
            "留在別台螢幕的視窗教出了 inset：\(scene.files.writes)")
}

/// 4. **不是頂端那一列**的視窗被夾 → 不學，而且照常報拒絕。
///
/// `horizontal` 是上下切（`TreeRects`），所以下半那塊的 y 是 1117 而不是畫布頂端。
/// 鑑別值：**1117 ≠ 0**。條件放寬成「只要 actual.y > wanted.y」的實作會在這裡學到
/// 一個 1147 的 inset，把畫布整個弄壞，而症狀是「版面每次都不一樣」。
@Test func aClampBelowTheTopRowTeachesNothing() {
    let stacked = JSONValue.object([
        JSONMember(key: "axis", value: .string("horizontal")),
        JSONMember(key: "children", value: .array([leaf("Code"), leaf("Chat")])),
    ])
    let scene = spaceHarness(
        config: spcConfig(spaceTrees: [("main", [("U-1", stacked)])]),
        extraWindows: [.object([
            JSONMember(key: "app", value: .string("Chat")),
            JSONMember(key: "id", value: .number("9")),
        ])]
    )
    // 下半那塊（y=1117，高 1117）被往下推 30。
    scene.server.actual["9"] = Rect(originX: 0, originY: 1147, width: 3456.5, height: 1117)
    _ = scene.run("")
    // 問的是「有沒有寫進一個 inset」而不是「有沒有寫檔」：後者會與第 6 條的突變
    // 撞在一起（「無條件寫回」會讓兩條同時紅），而這條要守的是**學**不是**寫**。
    #expect(stateWritten(scene)?.contains("topinset") != true,
            "拿非頂端那一列的樣本去校準了：\(scene.files.writes)")
    #expect(scene.reporter.events.contains { event in
        if case .space(.frameRejected) = event {
            return true
        }
        return false
    }, "非頂端那一列被夾卻沒有報拒絕：\(scene.reporter.events)")
}

/// 5. 狀態檔裡已經有 inset → 畫布頂端跟著往下、高度跟著少。
///
/// 鑑別值：第一個矩形是 `(0, 30, 3456.5, 2204)`。只加 originY 不減 height 的實作
/// 會把畫布撐出螢幕下緣（2234），而那在畫面上看起來只是「最下面那個視窗被切掉」。
@Test func aKnownTopInsetShrinksTheCanvas() {
    let scene = spaceHarness(state: "topinset.A=30\n")
    _ = scene.run("")
    #expect(scene.server.calls == [.init(window: "7", frame: Rect(
        originX: 0, originY: 30, width: 3456.5, height: 2204
    ))], "畫布沒有套上已學到的 inset：\(scene.server.calls)")
}

/// 6. 值沒變就不寫檔。
///
/// inset 校準對之後，頂端那一列會**精確命中**（fake 預設就回要求的矩形），於是這一輪
/// 一個樣本都沒有——狀態檔一個位元組都不該動。鑑別值：`writes` 是空的。
/// 這條擋的是「每跑一次就把狀態檔重寫一遍」，那會讓 `--space` 每次都動一次 mtime，
/// 而它掛在切 space 的 signal 上。
@Test func anUnchangedTopInsetIsNotWrittenAgain() {
    let scene = spaceHarness(state: "topinset.A=30\n")
    _ = scene.run("")
    #expect(scene.files.writes.isEmpty, "值沒變卻寫了狀態檔：\(scene.files.writes)")
}
