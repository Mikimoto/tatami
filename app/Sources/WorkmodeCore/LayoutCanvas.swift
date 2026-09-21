import WorkmodeDomain

/// 「這台螢幕上，視窗真正排得進去的那塊矩形」。
///
/// 抽出來是因為**兩條路都要用它**：`--space` 套整棵樹，`grid` 套一格。各算一份的話
/// 同一個位置會差一個 inset（本機實測 30pt），而那個差在畫面上看起來只是「格線有點
/// 不準」——沒有任何訊息說得出為什麼，而且兩邊都覺得自己是對的。
public enum LayoutCanvas {
    /// 我們對外報的那個「螢幕 frame」：**頂端用原始的，左右與底端用可視區的**。
    ///
    /// 混用兩個來源是 2026-09-21 那個「排滿的視窗上下各空一條」的根因。
    /// `NSScreen.visibleFrame` 只在**選單列與 Dock 當下所在的那台**螢幕上扣掉它們，
    /// 而 `TopInset` 學到的值只在「那台螢幕沒有選單列」時才取得到樣本
    /// （`FrameLayout.isTopInsetSample` 要求視窗被往下推），套用時卻不問它現在是不是
    /// 主螢幕。主螢幕一換（關筆電蓋、拔插螢幕、改排列），同一段選單列就被扣兩次。
    ///
    /// 那天的實測：BenQ 原始 `(1728, -1026, 3008, 1692)`、學到的 inset 30，而它當主
    /// 螢幕時可視區是 `(-996, 1626)`，再減 30 得到 `(-966, 1596)`——逐字就是當時量到
    /// 的 Ghostty frame（頂端空 30、底端空 36）。ASUS 只被扣 Dock 時同樣對得上。
    ///
    /// 統一成「頂端一律原始、選單列一律用學的」是對的，因為 **macOS 在每一台螢幕上都
    /// 夾那個頂端，不只主螢幕**：同日實測，對主螢幕（內建）的視窗要求 y=0 拿回 y=33。
    /// `visibleFrame` 只是在主螢幕上順便把它報出來而已，那個夾一直都在。
    ///
    /// 底端與左右維持可視區：Dock 沒有「學」的機制（它不夾視窗——實測視窗蓋得過
    /// Dock），而 AppKit 已經在它所在那台扣好了。
    ///
    /// 代價（明講）：一台還沒學過的螢幕，第一輪頂端那列會被 macOS 往下推一次，而且
    /// 要等滿 `WindowServerClient.setFrame` 的輪詢預算。那正是 `TopInset` 的取樣條件，
    /// 所以它學得起來、第二輪就精確——外接螢幕本來就要付這一輪，改動之後主螢幕也付
    /// 一次。**那一輪不安靜**：`FrameLayout` 的豁免只涵蓋 y，而被往下推的視窗高度也
    /// 短了同樣那幾點，所以頂端那列會各印一句 `frameRejected`。實測 2026-09-21，內建
    /// 螢幕第一輪印「要 0,0 432×1081、實際 0,33 432×1048」，第二輪就不見了。
    /// 不為它放寬豁免：高度對不上本來就是要說出來的事（app 的最小尺寸走同一條）。
    public static func displayFrame(raw: Rect, visible: Rect) -> Rect {
        Rect(originX: visible.originX, originY: raw.originY, width: visible.width,
             height: visible.originY + visible.height - raw.originY)
    }

    /// - Parameters:
    ///   - frame: 那台螢幕的 frame（`yabai -m query --displays` 形狀的那個，在我們這
    ///     條路上是 `displayFrame` 組出來的——頂端原始、底端可視區）。
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
