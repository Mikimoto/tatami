/// 一條新規則要放進既有的規則清單的哪個位置。
///
/// **這一支存在的理由是量出來的。** 生效的規則清單是 `shared + local`
/// （`LayoutQuery.swift:120`），而 `RuleResolution` 照那個順序「先到先得」
/// （`RuleResolution.swift:61` 的 `firstUnclaimed`）。所以一條接在**地點層尾端**
/// 的新規則（`ProfileResolution.swift:244` 是那個落點）排在共用層那條
/// `["app", X]` catch-all **後面**——catch-all 先挑走一個該 app 的視窗，而那可能
/// 正是這條規則要認的那一個，於是它拿到 `ruleCandidatesAllClaimed`
/// （`RuleResolution.swift:71`），等於沒加。
///
/// 而「加了卻永遠不生效」在畫面上與「沒加」完全相同：那一格就是空的，一句話都沒有。
/// 所以它是一支有測試的函式，而不是 merge 裡的一行。
///
/// **不改 `ProfileMerge.mergeRules`**（`ProfileResolution.swift:235`）：那一段由
/// `merge` 與 `mergeSpaceTrees` 共用，而 `merge` 有 36 組 `merge_profile` 的凍結語料
/// 鏡射 bash。在那裡動落點等於改差分基準。
public enum RulePlacement {
    public struct Placed: Equatable, Sendable {
        /// 既有的那份清單（可能沒動）。
        public let rules: JSONValue
        /// true ＝ 已經插進這份清單了，呼叫端**不要**再把它接到地點層去。
        public let wentBeforeCatchAll: Bool
    }

    /// 一次放進整份設定的結果。
    public struct Placement: Equatable, Sendable {
        /// 放好之後的整份設定（沒放成就是原封不動的那一份）。
        public let config: JSONValue
        /// true ＝ 已經寫進 `config` 了，呼叫端**不要**再把它交給
        /// `ProfileMerge` 接到落點尾端。
        public let placed: Bool
    }

    /// 把規則放進整份設定的正確位置——**寫回去的那份，就是判斷時讀出來的那份**。
    ///
    /// 與下面那支收單一清單的分開，不是為了少打字：「哪一份才是生效的那份」
    /// 是這裡唯一在回答的問題，而答錯的樣子最惡劣——它會回 `placed: true`
    /// （叫呼叫端別再接一次），同時把規則插進一份沒有人讀的陣列，於是那條規則
    /// **消失了，而畫面上與成功完全相同**。
    ///
    /// - Parameter app: 這條新規則要認的視窗屬於哪個 app。它決定要贏過哪一條
    ///   catch-all。**規則本身讀不出它**：`title-regex` 那條的 `match[1]` 是標題、
    ///   `url-contains` 那條是網址。
    /// - Returns: `placed: false` ＝ 每一份清單裡都沒有那個 app 的 catch-all。
    ///   那時 `config` 原封不動，呼叫端照舊把規則交給 `ProfileMerge` 接到落點尾端
    ///   ——沒有 catch-all 就沒有東西會先搶走那個視窗，接尾端是對的。
    public static func place(_ rule: JSONValue, forApp app: String,
                             location: String, profile: String,
                             in config: JSONValue) -> Placement
    {
        for path in ladder(location: location, profile: profile, in: config) {
            let inserted = insert(rule, forApp: app, into: value(at: path, in: config))
            guard inserted.wentBeforeCatchAll,
                  let updated = try? JSONPath.set(config, path.map { .key($0) },
                                                  to: inserted.rules)
            else { continue }
            return Placement(config: updated, placed: true)
        }
        return Placement(config: config, placed: false)
    }

    /// 要依序試的那幾份清單，順序就是它們在生效清單裡的先後。
    ///
    /// profile 自己有 `windows` 陣列時它**整塊取代**共用層與地點層
    /// （`LayoutQuery.swift:115`），所以那時只有它一份可以試——插進共用層等於插進
    /// 一份沒有人讀的陣列。否則生效的是 `shared + local`（`LayoutQuery.swift:120`），
    /// 共用層排在前面，所以要先試它：贏過共用層那條就同時贏過地點層那條。
    ///
    /// 分支條件是 `case .array`，照抄 `ProfileMerge.mergeRules`
    /// （`ProfileResolution.swift:241`）的落點判斷，**不是** `LayoutQuery` 的
    /// truthy 判斷。兩者只在「profile 的 `windows` 是真值但不是陣列」（例如
    /// `"windows": {}`）時分岔，而那份設定本來就不生效；跟著落點走，
    /// 才保證「插進去的那份」與「接尾端的那份」永遠在同一條清單上。
    private static func ladder(location: String, profile: String,
                               in config: JSONValue) -> [[String]]
    {
        let inProfile = [location, "profiles", profile, LayoutQuery.reservedKey]
        if case .array = value(at: inProfile, in: config) {
            return [inProfile]
        }
        return [[LayoutQuery.reservedKey], [location, LayoutQuery.reservedKey]]
    }

    private static func value(at path: [String], in config: JSONValue) -> JSONValue {
        JSONPath.get(config, path.map { .key($0) }) ?? .null
    }

    /// - Parameters:
    ///   - shared: **跑在呼叫端那個落點之前**的那份規則清單。profile 自己有
    ///     `windows` 時它整塊取代共用層與地點層（`LayoutQuery.swift:115`），
    ///     所以呼叫端要傳的是那一份而不是無條件傳共用層——傳錯的話這裡會插進一份
    ///     根本不生效的清單，而回 true 又叫呼叫端別再接一次，那條規則就消失了。
    ///     `place` 就是替呼叫端回答「哪一份」的，所以產品路徑只叫 `place`。
    ///   - app: 這條新規則要認的視窗屬於哪個 app。它決定要贏過哪一條 catch-all。
    public static func insert(_ rule: JSONValue, forApp app: String,
                              into shared: JSONValue) -> Placed
    {
        guard case let .array(rows) = shared,
              let index = rows.firstIndex(where: { isCatchAll($0, for: app) })
        else { return Placed(rules: shared, wentBeforeCatchAll: false) }
        var out = rows
        out.insert(rule, at: index)
        return Placed(rules: .array(out), wentBeforeCatchAll: true)
    }

    /// `["app", <這個 app>]`。比的是 `match` 的頭兩個元素。
    ///
    /// **只看 `match`，而那是一個已知的缺口不是「fallback 不算」。**
    /// `RuleResolution.swift:121-124` 讀得出來（沒有實跑過）：一條 `fallback` 是
    /// `["app", X]` 的規則，在它自己的 `match` 一個視窗都沒找到時**照樣會認領**
    /// 該 app 的視窗——所以它
    /// 在那種情況下也是一條 catch-all。這裡不涵蓋它，是因為那個身分**隨每次執行
    /// 變動**（開著 chat 分頁時它不是 catch-all，關掉就是），而落點是寫進
    /// `layout.json` 的持久決定；用一個會變的條件去決定一個不變的位置，兩者遲早
    /// 對不上。代價寫在這裡：那種設定底下這條新規則仍然可能輸掉那次認領。
    ///
    /// 非物件的 entry（`windows` 裡的純量，`CLAUDE.md` 記過真的有人打出
    /// `["糟糕"]`）走 subscript 回 nil 那條路，一律不是 catch-all。
    private static func isCatchAll(_ entry: JSONValue, for app: String) -> Bool {
        guard case let .array(match) = entry["match"] ?? .null, match.count >= 2,
              case .string("app") = match[0], case let .string(value) = match[1]
        else { return false }
        return value == app
    }
}
