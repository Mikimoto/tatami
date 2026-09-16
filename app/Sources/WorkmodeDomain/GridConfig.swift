/// 一台螢幕的格線設定：幾欄幾列、視窗之間留多寬。
///
/// **鍵是 display uuid 而不是角色名。** 角色名住在 `layout.json` 且是
/// per-location——同一台螢幕在 `home` 與 `office` 可以叫不同名字，而格數是硬體的
/// 性質。狀態檔的 `topinset.<display uuid>` 已經是這個先例。代價是設定檔裡會出現
/// 一串讀不出是哪台的 uuid，所以編輯器那一頁**必須顯示螢幕名字**。
public struct GridConfig: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let gap: Double

    /// 6×4 是這個功能原本寫死的預設。間距 8 的理由沿用 `WindowActionsLayout`
    /// 原本那個常數：使用者 `yabairc` 的 `window_gap` 實測是 0，而 0 會讓
    /// 「切換間隙」那個鍵按了完全沒有變化。
    public static let defaults = GridConfig(columns: 6, rows: 4, gap: 8)

    /// 夾在 init 裡而不是讀取時，這樣**每一個**建構點都被夾到——設定檔是人手改
    /// 得動的（`"columns": 0` 打得出來），而 0 欄的格線畫不出東西、負的間距會讓
    /// inset 把矩形往外撐（畫面上是「視窗互相重疊」）。
    public init(columns: Int, rows: Int, gap: Double) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.gap = max(0, gap)
    }

    /// 那台螢幕的設定，沒列到就是預設。
    ///
    /// **空字串的 uuid 永遠不算命中**：新增地點時 `main` 的 uuid 是刻意留空的，
    /// 而 `grids[""]` 若配得到，一台認不出來的螢幕就會吃到別人的設定。
    public static func forDisplay(_ uuid: String,
                                  in table: [String: GridConfig]) -> GridConfig
    {
        guard !uuid.isEmpty, let found = table[uuid] else { return defaults }
        return found
    }
}
