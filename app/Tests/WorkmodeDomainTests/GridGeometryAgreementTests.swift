import Testing
import WorkmodeDomain

// `GridSelection.rect(from:to:)`（拖出來的那一塊）與 `WindowGeometry.cell(_:canvas:)`
// （套上去的那一塊）是**同一條公式的兩份副本**（`origin + extent * i / n` 再相減）。
// 今天以前它們沒有交會點，所以漂了也不會有東西紅。
//
// **2026-09-09 起格線面板整條路都走後者**：選取換算成 `GridSpec`，再由
// `GapInset.cell` 套間距——預覽與放開滑鼠共用那一支，所以「亮起來的」就是
// 「會被套上去的」。副作用是 `GridSelection.rect` 這一輪之後**沒有產品呼叫端**，
// 而那正是它會悄悄漂掉的條件：改壞了不會有任何東西紅，直到有人把某條路徑接回它
// （鍵盤版的格線就是同一支）。這組測試就是補上的那個交會點。
//
// 漂掉的症狀是「亮在這一格、視窗排到隔壁」，而畫面上兩邊都正常。
//
// 畫布用一台真的螢幕（display 2 的可視區，實測 `(1728, -996, 3008, 1662)`）：
// 負的 y 與不整除的尺寸是這台機器的常態，而規則的畫布會讓兩種實作給同一個答案。
private let canvas = Rect(originX: 1728, originY: -996, width: 3008, height: 1662)

@Test func theTwoGeometriesAgreeOnEveryCellOfASixByFour() {
    let grid = GridSelection(canvas: canvas, columns: 6, rows: 4)
    for column in 0 ..< 6 {
        for row in 0 ..< 4 {
            let dragged = grid.rect(from: .init(column: column, row: row),
                                    to: .init(column: column, row: row))
            let applied = WindowGeometry.cell(
                .init(rows: 4, columns: 6, originX: column, originY: row,
                      width: 1, height: 1), canvas: canvas
            )
            #expect(dragged == applied, "格 \(column),\(row)")
        }
    }
}

/// 跨多格也要一致——單格相同不代表 `width`／`height` 那兩個參數對得起來。
@Test func theTwoGeometriesAgreeOnAMultiCellSpan() {
    let grid = GridSelection(canvas: canvas, columns: 6, rows: 4)
    let dragged = grid.rect(from: .init(column: 1, row: 0), to: .init(column: 4, row: 2))
    let applied = WindowGeometry.cell(
        .init(rows: 4, columns: 6, originX: 1, originY: 0, width: 4, height: 3),
        canvas: canvas
    )
    #expect(dragged == applied)
}

/// **正控制組**：這個比對真的分得出對錯。少了它，兩支都回同一個常數也會過。
@Test func theComparisonCanActuallyFail() {
    let grid = GridSelection(canvas: canvas, columns: 6, rows: 4)
    let dragged = grid.rect(from: .init(column: 0, row: 0), to: .init(column: 0, row: 0))
    let wrong = WindowGeometry.cell(
        .init(rows: 4, columns: 6, originX: 1, originY: 0, width: 1, height: 1),
        canvas: canvas
    )
    #expect(dragged != wrong)
}
