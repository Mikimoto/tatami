/// Divvy 式滑鼠格線的幾何：把一台螢幕切成 `columns × rows` 格，兩格之間拉一個矩形。
///
/// 純的，所以判斷全部在這裡而 overlay 那層只負責畫與收滑鼠事件——那一層與
/// `WorkmodeEditorUI` 同一個處境（沒有測試跑得到它），所以能搬下來的就搬下來。
public struct GridSelection: Equatable, Sendable {
    /// 一格的座標，左上是 `(0, 0)`。
    public struct Cell: Equatable, Sendable {
        public let column: Int
        public let row: Int

        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }
    }

    public let canvas: Rect
    public let columns: Int
    public let rows: Int

    /// `columns`／`rows` 小於 1 一律夾成 1。回 nil 或 throw 都要呼叫端處理一個
    /// 不可能發生的情況（格數是程式碼裡的常數，不是使用者輸入）。
    public init(canvas: Rect, columns: Int, rows: Int) {
        self.canvas = canvas
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    /// **正規化座標**（0…1，畫布左上是 `(0, 0)`）落在哪一格。
    ///
    /// 收比例而不是螢幕座標，因為輸入端是一塊**縮圖**面板（Lasso 那樣），它自己的
    /// 尺寸與畫布無關——換算只有「除以自己的寬高」這一步，而那一步留在畫面那層
    /// （`DropZone.at(x:y:)` 與 `CanvasView` 是同一個分工）。副作用是全螢幕的
    /// overlay 也能用同一支：它的比例就是點除以螢幕尺寸。
    ///
    /// **超出 0…1 就夾到最近的一格**，不回 nil：拖曳時手指衝出面板邊緣是常態，
    /// 而那時使用者的意思顯然是最邊上那一格。而 `1.0` 這個值本身乘出來剛好等於
    /// 格數（`floor` 的結果就是 `columns`），所以夾這一步不是保險而是**正確性的
    /// 一部分**。
    public func cell(atFraction fractionX: Double, _ fractionY: Double) -> Cell {
        Cell(column: index(of: fractionX, count: columns),
             row: index(of: fractionY, count: rows))
    }

    /// 兩格之間（含頭含尾）的矩形。順序不重要——從右下拖到左上與反過來相同。
    ///
    /// 邊界一律由 `edge` 算出來，寬高則是**兩條邊相減**。這與 `TreeRects` 是同一條
    /// 紀律：`extent * count / count` 在 IEEE 下剛好是 `extent`（`n/n` 恰為 1.0），
    /// 所以最後一格的右緣**精確等於**畫布右緣，而 `寬 = 每格寬 × 格數` 那種寫法
    /// 會累積誤差，讓靠右那一格差幾個 ULP——量小到看不見，但「鋪滿螢幕」變成不成立，
    /// 而使用者按下去的那一格正是最右邊那一格時就差得出來。
    public func rect(from first: Cell, to second: Cell) -> Rect {
        let lowColumn = min(first.column, second.column)
        let highColumn = max(first.column, second.column)
        let lowRow = min(first.row, second.row)
        let highRow = max(first.row, second.row)
        let left = edge(lowColumn, origin: canvas.originX,
                        extent: canvas.width, count: columns)
        let right = edge(highColumn + 1, origin: canvas.originX,
                         extent: canvas.width, count: columns)
        let top = edge(lowRow, origin: canvas.originY,
                       extent: canvas.height, count: rows)
        let bottom = edge(highRow + 1, origin: canvas.originY,
                          extent: canvas.height, count: rows)
        return Rect(originX: left, originY: top, width: right - left, height: bottom - top)
    }

    /// 第 `step` 條格線的座標。`step == count` 時精確等於 `origin + extent`。
    private func edge(_ step: Int, origin: Double, extent: Double, count: Int) -> Double {
        origin + extent * Double(step) / Double(count)
    }

    private func index(of fraction: Double, count: Int) -> Int {
        // 非有限的比例（NaN／inf）在這裡收斂成第 0 格：比較全部為 false，
        // 而 `Int(...)` 對 NaN 是**當場 crash**，所以不能讓它走到那一步。
        guard fraction.isFinite else { return 0 }
        let raw = fraction * Double(count)
        guard raw > 0 else { return 0 }
        return min(count - 1, Int(raw))
    }
}
