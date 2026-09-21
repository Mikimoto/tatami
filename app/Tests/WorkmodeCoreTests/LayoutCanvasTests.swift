import Testing
import WorkmodeCore
import WorkmodeDomain

// `LayoutCanvas.displayFrame`：把 NSScreen 的兩個 frame 合成我們對外報的那一個。
//
// 這幾條在守 2026-09-21 的缺陷——「排滿的視窗上下各空一條」。根因是畫布同時用了
// 兩個扣選單列的來源：`NSScreen.visibleFrame`（只在選單列當下所在那台扣）與
// `TopInset` 學到的值（只在那台**沒有**選單列時取得到樣本，套用時卻不看）。主螢幕
// 一換，同一段選單列就被扣兩次。
//
// fixture 是那天的實測值：BenQ 原始 `(1728, -1026, 3008, 1692)`、學到 inset 30。

/// BenQ 的原始 frame（CG 座標，那天 `CGDisplayBounds` 與 `NSScreen.frame` 都是這個）。
private let benqRaw = Rect(originX: 1728, originY: -1026, width: 3008, height: 1692)

/// 狀態檔：BenQ 學到 30pt 的選單列。
private let learnedThirty = "topinset.BENQ=30\n"

/// 1. 它**當主螢幕**時——可視區已經扣掉選單列 30 與 Dock 36——畫布仍然只扣一次選單列。
///
/// 鑑別值是頂端 **-996**。舊實作（頂端用可視區的）在這裡得到 `-966`，底端 630，
/// 也就是那天量到的 Ghostty frame；差的正好是第二次扣掉的那 30pt。
@Test func theMenuBarIsSubtractedOnceEvenWhenTheScreenIsPrimary() {
    let visible = Rect(originX: 1728, originY: -996, width: 3008, height: 1626)
    let reported = LayoutCanvas.displayFrame(raw: benqRaw, visible: visible)
    let canvas = LayoutCanvas.of(frame: reported, display: "BENQ", state: learnedThirty).frame

    let bottom = canvas.originY + canvas.height
    #expect(canvas.originY == -996, "選單列被扣了兩次：頂端 \(canvas.originY)，該是 -996")
    #expect(bottom == 630, "底端 \(bottom)，該是 630（Dock 只扣一次）")
}

/// 2. 它**不是**主螢幕時（可視區 ＝ 原始，AppKit 什麼都沒扣）畫布一樣正確。
///
/// 與第 1 條的差別只有輸入的 `visible`，輸出的頂端相同（-996）而底端多了 Dock 那 36
/// ——沒有這一條的話，一個「永遠回原始 frame」的實作也會讓第 1 條過。
@Test func aSecondaryScreenStillGetsItsMenuBarFromTheLearnedInset() {
    let canvas = LayoutCanvas.of(frame: LayoutCanvas.displayFrame(raw: benqRaw, visible: benqRaw),
                                 display: "BENQ", state: learnedThirty).frame

    let bottom = canvas.originY + canvas.height
    #expect(canvas.originY == -996, "頂端 \(canvas.originY)，該是 -996")
    #expect(bottom == 666, "底端 \(bottom)，該是 666（這台沒有 Dock）")
}

/// 3. `rawTop` 是**原始**頂端，不是可視區頂端。
///
/// `FrameLayout` 拿它當校準基準（`observed = actual.originY - rawTop`）。用可視區的
/// 頂端當基準，主螢幕上量到的 inset 會是 0，於是它永遠學不到自己的選單列——而那正是
/// 「只有非主螢幕學得到」這個不對稱的來源。
@Test func theCalibrationBaselineIsTheRawTopNotTheVisibleTop() {
    let visible = Rect(originX: 1728, originY: -996, width: 3008, height: 1626)
    let reported = LayoutCanvas.displayFrame(raw: benqRaw, visible: visible)

    #expect(LayoutCanvas.of(frame: reported, display: "BENQ", state: "").rawTop == -1026,
            "校準基準不是原始頂端，學到的 inset 會少一整段選單列")
}

/// 4. Dock 靠左時左右也照可視區收窄。
///
/// 橫向沒有「學」的機制，所以那半**只能**信 AppKit。把它改成照抄原始 frame 的話，
/// 最左邊那一欄會被壓在 Dock 底下，而畫面上看起來只是「那個視窗怪怪的」。
@Test func aSideDockNarrowsTheCanvasHorizontally() {
    let raw = Rect(originX: 0, originY: 0, width: 1728, height: 1117)
    let visible = Rect(originX: 80, originY: 33, width: 1648, height: 1084)
    let reported = LayoutCanvas.displayFrame(raw: raw, visible: visible)

    #expect(reported.originX == 80, "左緣 \(reported.originX)，該讓開 Dock 的 80")
    #expect(reported.width == 1648, "寬 \(reported.width)，該是可視區的 1648")
    #expect(reported.originY == 0, "頂端 \(reported.originY)，該是原始的 0")
    #expect(reported.height == 1117, "高 \(reported.height)，該是從原始頂端到可視區底端")
}
