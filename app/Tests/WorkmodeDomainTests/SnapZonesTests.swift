import Testing
@testable import WorkmodeDomain

private let canvas = Rect(originX: 0, originY: 0, width: 1200, height: 900)
private func point(_ posX: Double, _ posY: Double) -> MouseDrag.Point {
    MouseDrag.Point(posX: posX, posY: posY)
}

private func target(_ zones: [SnapZone], at posX: Double, _ posY: Double) -> Rect? {
    SnapZones.zone(at: point(posX, posY), in: zones)?.target
}

// 畫布 1200×900 → 邊緣帶 = min(1200,900) × 0.15 = 135pt。
// 中央塊 = 240×180，置中在 (480,360)…(720,540)。

/// 外圈：角是田字、邊是半邊。
@Test func theOuterRingGivesQuartersAndHalves() {
    let zones = SnapZones.grid(canvas: canvas)
    #expect(target(zones, at: 50, 50) == Rect(originX: 0, originY: 0,
                                              width: 600, height: 450))
    #expect(target(zones, at: 1150, 850) == Rect(originX: 600, originY: 450,
                                                 width: 600, height: 450))
    #expect(target(zones, at: 50, 450) == Rect(originX: 0, originY: 0,
                                               width: 600, height: 900))
    #expect(target(zones, at: 600, 50) == Rect(originX: 0, originY: 0,
                                               width: 1200, height: 450))
}

/// **這是這次改動的重點**：正中央給整片，而且**有樹的時候也給得到**。
/// 第一版的「樹優先」讓整片在畫過樹的 space 上完全拿不到。
@Test func theCentreGivesTheWholeCanvasEvenWithATree() {
    let left = Rect(originX: 0, originY: 0, width: 800, height: 900)
    let right = Rect(originX: 800, originY: 0, width: 400, height: 900)
    let zones = SnapZones.of(canvas: canvas, leaves: [left, right])
    #expect(target(zones, at: 600, 450) == canvas)
    // 對照組：同一個點在樹優先的舊行為下會給 left（那個葉含這一點）。
    #expect(target(zones, at: 600, 450) != left)
}

/// 中間圈（不在邊緣帶、也不在中央塊）給樹的葉。
@Test func theMiddleBandGivesTheLeafUnderTheCursor() {
    let left = Rect(originX: 0, originY: 0, width: 800, height: 900)
    let right = Rect(originX: 800, originY: 0, width: 400, height: 900)
    let zones = SnapZones.of(canvas: canvas, leaves: [left, right])
    // x=300 在左邊緣帶（0…135）之外、中央塊（480…720）之外 → 左邊那個葉。
    #expect(target(zones, at: 300, 450) == left)
    // x=900 同理 → 右邊那個葉。九宮格的話那裡是右半（600…1200），分得出兩者。
    #expect(target(zones, at: 900, 450) == right)
}

/// **優先序是明講的契約**，不是靠 trigger 不重疊。葉覆蓋整個畫布，
/// 所以外圈那一塊底下一定有一個葉——外圈必須贏。
@Test func theOuterRingWinsOverALeafUnderneath() {
    let whole = Rect(originX: 0, originY: 0, width: 1200, height: 900)
    let zones = SnapZones.of(canvas: canvas, leaves: [whole])
    // (50,450) 落在左邊緣帶，同時也落在那個覆蓋全畫布的葉裡。
    #expect(SnapZones.zone(at: point(50, 450), in: zones)?.name == "左半")
    #expect(target(zones, at: 50, 450) == Rect(originX: 0, originY: 0,
                                               width: 600, height: 900))
}

/// 沒有樹：中間圈也是整片，等於退回九宮格。這是「中間圈給葉」那條的對照組
/// ——少了它，「用了葉」與「這個 fixture 兩種模式剛好同解」分不出來。
@Test func withoutATreeTheMiddleBandIsAlsoTheWholeCanvas() {
    let zones = SnapZones.grid(canvas: canvas)
    #expect(target(zones, at: 300, 450) == canvas)
    #expect(target(zones, at: 600, 450) == canvas)
}

@Test func aPointOutsideTheCanvasPicksNothing() {
    let zones = SnapZones.grid(canvas: canvas)
    #expect(SnapZones.zone(at: point(-10, 100), in: zones) == nil)
    #expect(SnapZones.zone(at: point(100, 5000), in: zones) == nil)
}

/// 外圈的八塊**彼此**不重疊，而且蓋滿邊緣。它們之間若有縫，那個點會掉到
/// 下一層（葉或整片），而畫面上看起來只是「這裡吸不到半邊」。
@Test func theRingCellsTileTheEdgeWithoutGaps() {
    let zones = Array(SnapZones.grid(canvas: canvas).prefix(8))
    #expect(zones.count == 8)
    for (index, one) in zones.enumerated() {
        for other in zones[(index + 1)...] {
            let apart = one.trigger.originX + one.trigger.width <= other.trigger.originX
                || other.trigger.originX + other.trigger.width <= one.trigger.originX
                || one.trigger.originY + one.trigger.height <= other.trigger.originY
                || other.trigger.originY + other.trigger.height <= one.trigger.originY
            #expect(apart, "\(one.name) 與 \(other.name) 重疊")
        }
    }
    // 四個邊的正中間都要命中外圈，不是掉到下一層。
    for spot in [(600.0, 5.0), (600.0, 895.0), (5.0, 450.0), (1195.0, 450.0)] {
        let name = SnapZones.zone(at: point(spot.0, spot.1), in: zones)?.name
        #expect(name?.hasSuffix("半") == true, "\(spot) → \(name ?? "nil")")
    }
}

/// 畫布比兩條帶還窄時，中間那段夾成 0——外圈的兩條帶接起來，仍然是合法的分割。
/// 不夾的話那個負寬度會讓 `contains` 永遠回 false，而症狀是「這台螢幕吸不到東西」。
@Test func averyNarrowCanvasStillPartitions() {
    let narrow = Rect(originX: 0, originY: 0, width: 100, height: 900)
    let zones = SnapZones.grid(canvas: narrow)
    #expect(SnapZones.zone(at: point(10, 450), in: zones) != nil)
    #expect(SnapZones.zone(at: point(90, 450), in: zones) != nil)
}

/// 半邊的邊界要精確接合：左半的右緣 ＝ 右半的左緣 ＝ 畫布中線。
@Test func theHalvesMeetExactlyInTheMiddle() {
    let zones = SnapZones.grid(canvas: canvas)
    guard let left = zones.first(where: { $0.name == "左半" })?.target,
          let right = zones.first(where: { $0.name == "右半" })?.target,
          let top = zones.first(where: { $0.name == "上半" })?.target
    else { Issue.record("找不到那幾區"); return }
    #expect(left.originX + left.width == right.originX)
    #expect(right.originX + right.width == canvas.originX + canvas.width)
    #expect(top.height * 2 == canvas.height)
}
