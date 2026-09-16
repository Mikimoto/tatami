import Testing
import WorkmodeDomain

// Divvy 式格線的幾何。用一台真的螢幕當畫布（display 2 的可視區，實測
// `(1728, -996, 3008, 1662)`）而不是 `0,0,100,100`：負的 y 與不整除的尺寸
// 是這台機器的常態，而規則的畫布會讓「乘法」與「相減」兩種實作給同一個答案。
private let canvas = Rect(originX: 1728, originY: -996, width: 3008, height: 1662)
private let grid = GridSelection(canvas: canvas, columns: 6, rows: 4)

/// 一格。
///
/// **寬高只比到 1e-9，不比精確相等**，而那不是偷懶：邊界是 `origin + extent*i/n`
/// 而寬是兩條邊相減，那個減法會掉掉低位元——實測這片畫布的一格寬是
/// `501.3333333333335` 而 `3008/6` 是 `501.3333333333333`，差 1.7e-13。
/// 兩件事只能挑一件：**每格的寬精確等於 `extent/n`**，或**格線精確對齊、
/// 最後一格精確落在畫布邊緣**。這裡挑後者（下面三條在守它），因為前者的代價是
/// 相鄰兩格之間出現看不見但確實存在的縫。
@Test func oneCellIsAFractionOfTheCanvas() {
    let one = grid.rect(from: .init(column: 0, row: 0), to: .init(column: 0, row: 0))
    #expect(one.originX == 1728)
    #expect(one.originY == -996)
    #expect(abs(one.width - 3008.0 / 6) < 1e-9)
    #expect(abs(one.height - 1662.0 / 4) < 1e-9)
}

/// **最後一格的右下角要精確落在畫布的右下角。**
///
/// 鑑別值就是這兩個等號：`寬 = 每格寬 × 格數` 的實作在這裡差幾個 ULP
/// （`3008/6*6 != 3008`），而那讓「鋪滿螢幕」不成立。
@Test func theLastCellEndsExactlyAtTheCanvasEdge() {
    let last = grid.rect(from: .init(column: 5, row: 3), to: .init(column: 5, row: 3))
    #expect(last.originX + last.width == canvas.originX + canvas.width)
    #expect(last.originY + last.height == canvas.originY + canvas.height)
}

/// 整片格線拉起來就是整個畫布，四個欄位都相等。
@Test func spanningEveryCellIsTheWholeCanvas() {
    #expect(grid.rect(from: .init(column: 0, row: 0),
                      to: .init(column: 5, row: 3)) == canvas)
}

/// 相鄰兩格拼起來沒有縫：左邊那格的右緣**精確等於**右邊那格的左緣。
///
/// 問的是「相等」而不是「差得夠小」：後者對乘法實作照樣通過（誤差是 1e-13），
/// 那就沒有牙齒——與 `TreeRects` 那條「第二塊等於父減第一塊」同一個判準。
@Test func neighbouringCellsShareAnEdgeExactly() {
    for column in 0 ..< 5 {
        let left = grid.rect(from: .init(column: column, row: 0),
                             to: .init(column: column, row: 0))
        let right = grid.rect(from: .init(column: column + 1, row: 0),
                              to: .init(column: column + 1, row: 0))
        #expect(left.originX + left.width == right.originX, "第 \(column) 條格線有縫")
    }
}

/// 從右下拖到左上與反過來相同。
@Test func theDragDirectionDoesNotMatter() {
    let forward = grid.rect(from: .init(column: 1, row: 1), to: .init(column: 3, row: 2))
    let backward = grid.rect(from: .init(column: 3, row: 2), to: .init(column: 1, row: 1))
    #expect(forward == backward)
    // 三格寬，同樣只比到 1e-9（實測 1503.9999999999995 對 1504.0）。
    #expect(abs(forward.width - 3008.0 / 6 * 3) < 1e-9)
}

// MARK: - 比例落在哪一格

// 輸入是 0…1 的比例而不是螢幕座標：拖曳發生在一塊**縮圖**面板上，它自己的尺寸與
// 畫布無關（見 `GridSelection.cell(atFraction:)`）。

/// 正中央落在第 3 欄第 2 列（0 起算）。
@Test func theCentreIsTheMiddleCell() {
    #expect(grid.cell(atFraction: 0.5, 0.5) == GridSelection.Cell(column: 3, row: 2))
}

/// 左上角是第 0 格。
@Test func theTopLeftCornerIsTheFirstCell() {
    #expect(grid.cell(atFraction: 0, 0) == GridSelection.Cell(column: 0, row: 0))
}

/// **`1.0` 也是最後一格，不是「第 6 格」。**
///
/// 這是夾這一步的理由而不是它的保險：`1.0 * count` 剛好是 `count`，`Int(...)` 給 6，
/// 而只有 0…5 存在。
@Test func theFarCornerIsStillTheLastCell() {
    #expect(grid.cell(atFraction: 1, 1) == GridSelection.Cell(column: 5, row: 3))
}

/// 拖出面板外要夾回最邊上那一格。
///
/// 鑑別值是**兩個方向**：只夾上界的實作對 `-2` 回一個負的欄位，而那會讓
/// `rect(from:to:)` 算出一個 origin 在畫布左邊的矩形——視窗飛到螢幕外。
@Test func aFractionOutsideTheRangeClampsToTheNearestCell() {
    #expect(grid.cell(atFraction: -2, -2) == GridSelection.Cell(column: 0, row: 0))
    #expect(grid.cell(atFraction: 9, 9) == GridSelection.Cell(column: 5, row: 3))
}

/// 每一欄的中點都落在自己那一欄——不是只有頭尾對。
///
/// 這條在守「比例乘出來的索引沒有差一」：把 `Int(raw)` 換成 `Int(raw.rounded())`
/// 的實作在這裡有一半的欄位錯。
@Test func theMidpointOfEveryColumnLandsInThatColumn() {
    for column in 0 ..< 6 {
        let middle = (Double(column) + 0.5) / 6
        #expect(grid.cell(atFraction: middle, 0.5).column == column,
                "比例 \(middle) 落在第 \(grid.cell(atFraction: middle, 0.5).column) 欄")
    }
}

/// NaN 與 inf 收斂成第 0 格而不是 crash。
///
/// `Int(Double.nan)` 在 Swift 是**當場 crash**（不是回 0），而滑鼠座標來自
/// AppKit——`DropZone.at` 對非有限座標回 nil 是同一個顧慮的另一種處置。
@Test func aNonFiniteFractionDoesNotCrash() {
    #expect(grid.cell(atFraction: .nan, .nan) == GridSelection.Cell(column: 0, row: 0))
    #expect(grid.cell(atFraction: .infinity, -.infinity)
        == GridSelection.Cell(column: 0, row: 0))
}

// MARK: - 邊界的格數

/// 格數小於 1 夾成 1，而那一格就是整個畫布。
@Test func aDegenerateGridIsOneCellCoveringEverything() {
    let single = GridSelection(canvas: canvas, columns: 0, rows: -3)
    #expect(single.columns == 1)
    #expect(single.rows == 1)
    #expect(single.rect(from: .init(column: 0, row: 0),
                        to: .init(column: 0, row: 0)) == canvas)
    #expect(single.cell(atFraction: 9, 9) == GridSelection.Cell(column: 0, row: 0))
}

/// 零寬的畫布：格子還是算得出來（比例不碰畫布尺寸），只是每一格都是零寬。
///
/// 面板那層才是會除以零的地方，所以那個守衛在 `GridOverlayView.cell(at:)`。
@Test func aZeroWidthCanvasStillHasCells() {
    let flat = GridSelection(canvas: Rect(originX: 5, originY: 5, width: 0, height: 0),
                             columns: 6, rows: 4)
    #expect(flat.cell(atFraction: 0.9, 0.9) == GridSelection.Cell(column: 5, row: 3))
    #expect(flat.rect(from: .init(column: 5, row: 3), to: .init(column: 5, row: 3))
        == Rect(originX: 5, originY: 5, width: 0, height: 0))
}
