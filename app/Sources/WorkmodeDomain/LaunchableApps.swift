/// `--launch` 要確保哪幾個 app 在跑。
///
/// 這是純函式：從設定與「這一輪要套的樹引用到的 label」推出一份 app 名字，
/// 不碰外部世界。開不開它們是 `SpaceLayout` 的事。
///
/// 名字有兩個來源，**規則自己的 `launch` 欄位優先**：
///
///   1. `launch`（明講的）——`url-exact`／`url-contains`／`title-regex` 只有這一條路：
///      它們的 `matchValue` 是網址或標題 regex，裡面沒有任何東西可以拿去 `open -a`
///      （一個 `url-contains` 規則要的視窗可能屬於 Safari、Chrome 或任何瀏覽器，
///      設定檔一個字都沒說）。沒寫 `launch` 的 url 類規則就**還是**幫不上忙，
///      那不再是缺口而是「這份設定沒講」。
///   2. `match`／`fallback` 的 kind 是 `app` 時的那個值（推出來的）。
///
/// 明講的贏：`launch` 是非空字串時就只收它，不再看 `match`。這讓「配 X 但開 Y」
/// 表達得出來，而反過來（推出來的贏）會讓那個欄位在 `app` 類規則上靜默無效。
///
/// `fallback` 也算：規則配不到 `match` 時會退到它，而它同樣可能是 `app`。
/// 漏掉 fallback 的症狀與 `SpaceLayout.needsSafariTabs` 漏掉它時相同——
/// 「這個視窗有時候開得起來、有時候不會」。
public enum LaunchableApps {
    /// - Parameters:
    ///   - labels: 這一輪要套的那幾棵樹引用到的 label（`LayoutTree.referencedLabels`
    ///     的結果）。比對用 `JSONValue` 的相等而不是印出來的字串，與
    ///     `LayoutValidator` 的 `treeChecks` 同一個語意：規則寫 `"label": 7`
    ///     而樹裡寫 `"7"` 是兩個不同的 label，印出來卻一模一樣。
    ///   - config: 整份 `layout.json`。
    ///
    /// - Returns: 去重後的 app 名字。**順序是設定檔裡規則的順序**
    ///   （`LayoutQuery.windowRules` 維持來源順序），同一個 app 被多條規則引用時
    ///   留在**第一次**出現的位置。定義一個順序是為了讓測試斷言得起來，而且
    ///   `AppPresence.ensure` 是一個一個等的（每個最多 10 秒），順序會被使用者看見。
    ///
    /// 規則讀不出來（jq 的 runtime error，例如 `windows` 不是陣列）就回空陣列：
    /// 那份設定接下來的 `rules.resolve` 本來就會失敗，這裡不是報告它的地方。
    public static func named(labels: [JSONValue], location: String, profile: String,
                             in config: JSONValue) -> [String]
    {
        var out: [String] = []
        var seen: Set<String> = []
        try? LayoutQuery.windowRules(location: location, profile: profile, in: config) { rule in
            guard labels.contains(rule.label) else { return }
            // 空名字 `open -a ""` 只會失敗一次再等滿逾時，那不是設定的意圖，
            // 所以 `launch: ""` 與沒寫 `launch` 走同一條路（往下推）。
            if case let .string(explicit) = rule.launch, !explicit.isEmpty {
                if seen.insert(explicit).inserted {
                    out.append(explicit)
                }
                return
            }
            for pair in [(rule.matchKind, rule.matchValue),
                         (rule.fallbackKind, rule.fallbackValue)]
            {
                guard case let .string(kind) = pair.0,
                      kind == WindowMatching.Kind.app.rawValue,
                      case let .string(app) = pair.1, !app.isEmpty
                else { continue }
                if seen.insert(app).inserted {
                    out.append(app)
                }
            }
        }
        return out
    }
}
