import WorkmodeDomain

/// 「這台螢幕上，視窗真正排得進去的那塊矩形」。
///
/// 抽出來是因為**兩條路都要用它**：`--space` 套整棵樹，`grid` 套一格。各算一份的話
/// 同一個位置會差一個 inset（本機實測 30pt），而那個差在畫面上看起來只是「格線有點
/// 不準」——沒有任何訊息說得出為什麼，而且兩邊都覺得自己是對的。
public enum LayoutCanvas {
    /// - Parameters:
    ///   - frame: 那台螢幕的 frame（`yabai -m query --displays` 形狀的那個，
    ///     在我們這條路上是 window server 給的可視區）。
    ///   - display: 那台螢幕的 uuid。inset 是**每台各自**學到的，所以不能傳 index。
    ///   - state: 狀態檔的全文。學不到就是 0，那時最上面一列會被 macOS 往下推，
    ///     而下一次 `--space` 就會學到（見 `TopInset`）。
    public static func of(frame: Rect, display: String, state: String) -> FrameLayout.Canvas {
        let inset = TopInset.learned(display: display, in: state)
        return FrameLayout.Canvas(
            frame: Rect(originX: frame.originX, originY: frame.originY + inset,
                        width: frame.width, height: frame.height - inset),
            rawTop: frame.originY
        )
    }
}
