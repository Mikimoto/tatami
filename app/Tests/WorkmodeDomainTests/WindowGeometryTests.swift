import Testing
@testable import WorkmodeDomain

private func placed(_ id: String, _ originX: Double, _ originY: Double,
                    _ width: Double, _ height: Double) -> WindowGeometry.Placed
{
    WindowGeometry.Placed(id: id, frame: Rect(originX: originX, originY: originY,
                                              width: width, height: height))
}

/// 「並排的優先」不是好看而已：少了它，一個又高又窄的正西鄰居會輸給西北那個
/// 中心點比較近的，而畫面上前者明明就在旁邊。
@Test func aNeighbourThatSharesRowsBeatsACloserDiagonalOne() {
    let current = placed("1", 1000, 500, 400, 400)
    let sameRow = placed("2", 100, 480, 200, 440) // 正西，遠
    let diagonal = placed("3", 700, 0, 200, 200) // 西北，中心點近
    let picked = WindowGeometry.neighbour(of: current.frame, among: [sameRow, diagonal],
                                          direction: .west)
    #expect(picked?.id == "2")
    // 沒有任何一個對齊時才退回中心點距離。
    let far = placed("4", 0, 0, 100, 100)
    #expect(WindowGeometry.neighbour(of: current.frame, among: [diagonal, far],
                                     direction: .west)?.id == "3")
}

@Test func thereIsNoNeighbourInAnEmptyDirection() {
    let current = placed("1", 0, 0, 400, 400)
    #expect(WindowGeometry.neighbour(of: current.frame, among: [placed("2", 500, 0, 400, 400)],
                                     direction: .west) == nil)
    #expect(WindowGeometry.neighbour(of: current.frame, among: [], direction: .east) == nil)
}

/// 距離相同時的決勝要是確定的，否則「按左鍵跳到哪」會隨查詢順序變。
@Test func equallyDistantNeighboursAreBrokenByIdNotByOrder() {
    let current = placed("9", 500, 0, 100, 600)
    let one = placed("2", 100, 0, 100, 200)
    let two = placed("7", 100, 400, 100, 200)
    #expect(WindowGeometry.neighbour(of: current.frame, among: [one, two],
                                     direction: .west)?.id == "2")
    #expect(WindowGeometry.neighbour(of: current.frame, among: [two, one],
                                     direction: .west)?.id == "2")
}

/// 最後一格的右下角要**精確**落在畫布邊緣，相鄰兩格精確共邊。
/// 代價是單格的寬不精確等於 `extent / n`（與 `GridSelection` 同一個取捨）。
@Test func theLastCellLandsExactlyOnTheCanvasEdge() {
    let canvas = Rect(originX: 10, originY: 20, width: 1504, height: 1000)
    let last = WindowGeometry.cell(.init(rows: 3, columns: 3, originX: 2, originY: 2,
                                         width: 1, height: 1), canvas: canvas)
    #expect(last.originX + last.width == canvas.originX + canvas.width)
    #expect(last.originY + last.height == canvas.originY + canvas.height)
    let first = WindowGeometry.cell(.init(rows: 3, columns: 3, originX: 0, originY: 0,
                                          width: 1, height: 1), canvas: canvas)
    let middle = WindowGeometry.cell(.init(rows: 3, columns: 3, originX: 1, originY: 0,
                                           width: 1, height: 1), canvas: canvas)
    #expect(first.originX + first.width == middle.originX)
}

@Test func outOfRangeCellIndicesAreClampedRatherThanProducingNegativeSizes() {
    let canvas = Rect(originX: 0, originY: 0, width: 1000, height: 800)
    let beyond = WindowGeometry.cell(.init(rows: 2, columns: 2, originX: 5, originY: 5,
                                           width: 3, height: 3), canvas: canvas)
    #expect(beyond == Rect(originX: 500, originY: 400, width: 500, height: 400))
    // width 0 會產生一個寬 0 的視窗；夾成 1 格。
    let zero = WindowGeometry.cell(.init(rows: 2, columns: 2, originX: 0, originY: 0,
                                         width: 0, height: 0), canvas: canvas)
    #expect(zero.width == 500 && zero.height == 400)
}

@Test func resizingStaysInsideTheCanvasAndAboveTheMinimumSide() {
    let canvas = Rect(originX: 0, originY: 0, width: 1000, height: 800)
    let frame = Rect(originX: 900, originY: 0, width: 100, height: 400)
    // 變寬之後右緣會超出畫布，所以左上角要往回推。
    let wider = WindowGeometry.resized(frame, deltaWidth: 200, deltaHeight: 0, canvas: canvas)
    #expect(wider == Rect(originX: 700, originY: 0, width: 300, height: 400))
    // 一路縮下去不能縮成 0——那會讓視窗整個消失。
    var shrinking = frame
    for _ in 0 ..< 20 {
        shrinking = WindowGeometry.resized(shrinking, deltaWidth: -20, deltaHeight: -20,
                                           canvas: canvas)
    }
    #expect(shrinking.width == 120 && shrinking.height == 120)
    // 比畫布還大的要求夾成畫布。
    let huge = WindowGeometry.resized(frame, deltaWidth: 9000, deltaHeight: 9000, canvas: canvas)
    #expect(huge == canvas)
}

/// 容差必須大於 0：`setFrame` 是請求，app 可以夾，逐位元組相等在實機上幾乎不存在。
@Test func theStackIsEverythingWithinTheTolerance() {
    let frame = Rect(originX: 0, originY: 0, width: 800, height: 600)
    let windows = [
        placed("1", 0, 0, 800, 600),
        placed("2", 5, -5, 790, 610), // 被 app 夾過，仍算同一疊
        placed("3", 0, 0, 800, 900), // 高度差 300，不算
    ]
    #expect(WindowGeometry.stack(around: frame, among: windows).map(\.id) == ["1", "2"])
    #expect(WindowGeometry.stack(around: frame, among: windows, tolerance: 0).map(\.id) == ["1"])
}

@Test func ratiosAreStrippedAndAxesFlippedAllTheWayDown() {
    let tree = JSONValue.object([
        JSONMember(key: "axis", value: .string("vertical")),
        JSONMember(key: "children", value: .array([
            .object([JSONMember(key: "window", value: .string("1")),
                     JSONMember(key: "ratio", value: .number("0.75"))]),
            .object([JSONMember(key: "axis", value: .string("horizontal")),
                     JSONMember(key: "children", value: .array([
                         .object([JSONMember(key: "window", value: .string("2")),
                                  JSONMember(key: "ratio", value: .number("0.3"))]),
                     ]))]),
        ])),
    ])
    let bare = WindowGeometry.withoutRatios(tree)
    #expect(!"\(bare)".contains("ratio"))
    #expect("\(bare)".contains("0.75") == false)
    let flipped = WindowGeometry.withFlippedAxes(tree)
    guard case let .object(top) = flipped else { Issue.record("形狀不對"); return }
    #expect(top[0].value == .string("horizontal"))
    // 巢狀那一層也要翻，不是只翻根。
    guard case let .array(children) = top[1].value,
          case let .object(nested) = children[1] else { Issue.record("形狀不對"); return }
    #expect(nested[0].value == .string("vertical"))
}

/// balance 走的整條路：矩形 → 樹 → 去掉 ratio → 排回去。
/// 這條同時證明 `rects(of:)` 吐的形狀真的餵得進 `RectTree.fromRects`——
/// 兩者各寫各的，錯開的話症狀是「按了沒反應」。
///
/// **均分的是樹不是寬度**（yabai 的 `space --balance` 也是）：這三個切成
/// `(1 | (2 | 3))`，所以答案是 600／300／300 而不是各 400。斷言寫成「三個相等」
/// 的第一版是錯的——它描述的是一個沒有人實作也不該實作的東西。
@Test func balancingEqualisesTheTreeNotTheWidths() throws {
    let windows = [placed("1", 0, 0, 900, 600), placed("2", 910, 0, 90, 600),
                   placed("3", 1010, 0, 190, 600)]
    let tree = try RectTree.fromRects(WindowGeometry.rects(of: windows))
    let canvas = Rect(originX: 0, originY: 0, width: 1200, height: 600)
    let leaves = try TreeRects.leaves(of: WindowGeometry.withoutRatios(tree), in: canvas)
    let widths = Dictionary(uniqueKeysWithValues: leaves.map { leaf -> (String, Double) in
        guard case let .string(id) = leaf.window else { return ("?", leaf.rect.width) }
        return (id, leaf.rect.width)
    })
    #expect(widths == ["1": 600, "2": 300, "3": 300])
    // 反向對照：留著 ratio 就維持原樣，證明上面那組數字是 withoutRatios 造成的。
    let kept = try TreeRects.leaves(of: tree, in: canvas)
    #expect(kept.map(\.rect.width) != leaves.map(\.rect.width))
}
