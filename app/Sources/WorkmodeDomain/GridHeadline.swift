/// 格線面板抬頭那一行。
///
/// **這一行存在的理由是一個實際會發生的誤會**：面板排的是**焦點視窗**
/// （`GridTarget` 走 `engine.focusedWindow()`），不是滑鼠底下那一個。兩者不同時
/// 它會排到別的視窗上，而在那之前面板一個字都沒說，所以看不出為什麼。
///
/// 放 Domain 而不是直接在 `NSView` 裡拼字串：那一層零測試（與
/// `WorkmodeEditorUI`／fzf 同一個處境），而「app 名字是空的要說什麼」
/// 與「格數怎麼夾」都是判斷。
public enum GridHeadline {
    /// - Parameter app: yabai 形狀的 `app` 欄位（本地化名稱）。空字串＝查不到。
    public static func text(app: String, displayIndex: String,
                            columns: Int, rows: Int) -> String
    {
        // 夾法與 `GridSelection`／`WindowGeometry.cell` 的 `max(1, …)` 相同：
        // 抬頭寫 `0×4` 而格線畫一欄，那個矛盾使用者看得到。
        let name = app.isEmpty ? "焦點視窗" : app
        return "\(name) · screen \(displayIndex) · \(max(1, columns))×\(max(1, rows))"
    }
}
