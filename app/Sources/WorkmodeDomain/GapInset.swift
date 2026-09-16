/// 間距：把一塊矩形往內縮，以及「一格加上間距」。
///
/// **只有一份**，兩個消費端：`balance`／`rotate`／`gaps` 那條走樹的路，
/// 與格線放置（`placeGrid` 以及位置庫）。抄第二份不是假想的風險——
/// `relayout` 裡那個 `gapsAreOn(state) ? config(scene).gap : 0` 曾經被改成常數 0 而
/// **沒有任何測試轉紅**（當時只有 `toggleGaps` 那條路徑被驗過）。
public enum GapInset {
    /// 往內縮。縮不動（會變成負的寬高）就原樣回傳：一個負寬的視窗
    /// `AXUIElementSetAttributeValue` 不一定會拒絕，而它整個消失。
    public static func rect(_ rect: Rect, by amount: Double) -> Rect {
        guard amount > 0, rect.width > amount * 2, rect.height > amount * 2 else { return rect }
        return Rect(originX: rect.originX + amount, originY: rect.originY + amount,
                    width: rect.width - amount * 2, height: rect.height - amount * 2)
    }

    /// 一格的位置，含間距。
    ///
    /// **兩處各縮一半**：畫布縮 `gap/2`、那一格再縮 `gap/2`，於是外緣的留白與
    /// 兩格之間的縫都恰好是 `gap`。只縮其中一邊的話兩者會差一倍，而畫面上
    /// 那看起來只是「邊緣怪怪的」。
    public static func cell(_ config: GridConfig, spec: WindowGeometry.GridSpec,
                            canvas: Rect) -> Rect
    {
        let board = rect(canvas, by: config.gap / 2)
        return rect(WindowGeometry.cell(spec, canvas: board), by: config.gap / 2)
    }
}
