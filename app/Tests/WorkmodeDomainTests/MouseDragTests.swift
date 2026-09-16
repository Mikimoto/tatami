import Testing
@testable import WorkmodeDomain

private let box = Rect(originX: 100, originY: 200, width: 800, height: 600)
private func point(_ posX: Double, _ posY: Double) -> MouseDrag.Point {
    MouseDrag.Point(posX: posX, posY: posY)
}

private func drag(_ grab: MouseDrag.Point, _ action: MouseDrag.Action) -> MouseDrag {
    MouseDrag(window: "1", origin: grab, frame: box, action: action)
}

@Test func movingKeepsTheSizeAndFollowsTheDelta() {
    let moved = drag(point(500, 500), .move).frame(at: point(520, 470))
    #expect(moved == Rect(originX: 120, originY: 170, width: 800, height: 600))
}

/// 抓在哪一象限就動哪一角，對面那一角**釘住**。
@Test func resizingDragsTheCornerYouGrabbedAndPinsTheOpposite() {
    // 右下角：左上釘住。
    let bottomRight = drag(point(880, 780), .resize).frame(at: point(900, 800))
    #expect(bottomRight == Rect(originX: 100, originY: 200, width: 820, height: 620))
    // 左上角：右下釘住（右緣 900、下緣 800 不動）。
    let topLeft = drag(point(120, 220), .resize).frame(at: point(140, 250))
    #expect(topLeft == Rect(originX: 120, originY: 230, width: 780, height: 570))
    // 右上角：左緣與下緣釘住。
    let topRight = drag(point(880, 220), .resize).frame(at: point(860, 240))
    #expect(topRight == Rect(originX: 100, originY: 220, width: 780, height: 580))
    // 左下角：右緣與上緣釘住。
    let bottomLeft = drag(point(120, 780), .resize).frame(at: point(150, 760))
    #expect(bottomLeft == Rect(originX: 130, originY: 200, width: 770, height: 580))
}

/// 恰好在中線上要有一個**確定的**答案，不然抓在正中央時每次拖的角都不一樣。
@Test func theMidlinesResolveToASingleCorner() {
    let middle = point(box.originX + box.width / 2, box.originY + box.height / 2)
    #expect(MouseDrag.nearestCorner(to: middle, of: box) == .bottomRight)
    #expect(drag(middle, .resize).corner == drag(middle, .resize).corner)
}

/// 拖過頭時**被拖的那一角**被夾住，對面那一角不准動——夾寬高的話釘住的那一角
/// 會開始移動，而畫面上那看起來像整個視窗突然跳走。
@Test func resizingPastTheMinimumPinsTheOppositeCornerAnyway() {
    let shrunk = drag(point(880, 780), .resize).frame(at: point(-9000, -9000))
    #expect(shrunk.originX == 100 && shrunk.originY == 200)
    #expect(shrunk.width == 120 && shrunk.height == 120)
    // 反方向：拖左上角過頭，右下緣仍然是 900／800。
    let other = drag(point(120, 220), .resize).frame(at: point(9000, 9000))
    #expect(other.originX + other.width == 900)
    #expect(other.originY + other.height == 800)
    #expect(other.width == 120 && other.height == 120)
}

/// **位移一律從按下當時的 frame 算。** 這條在守那件事：連續兩次查詢同一個
/// `MouseDrag`，答案只取決於現在的滑鼠位置，不受中間問過幾次影響。
/// 在上一個結果上疊加的實作會讓視窗愈拖愈偏，而每一步只差一點。
@Test func theResultDependsOnlyOnTheCurrentPoint() {
    let gesture = drag(point(500, 500), .move)
    _ = gesture.frame(at: point(600, 600))
    _ = gesture.frame(at: point(700, 700))
    #expect(gesture.frame(at: point(520, 470))
        == Rect(originX: 120, originY: 170, width: 800, height: 600))
}
