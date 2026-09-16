/// 沒有人可以問「這個視窗要叫什麼」時，自己推一個。
///
/// **不重用 `WindowRules.rule`**，兩個理由都是實測出來的：
///
/// * 那一支有 26 組凍結語料（`rule_for_window`），它鏡射 bash，改不得。
/// * 而且它**網址優先且用 `url-exact`**（`WindowRules.swift:60`）——對一個開著
///   30 個分頁的 Safari 視窗，那會產出「當前那個分頁的網址」，使用者切一次分頁
///   就失效，而失效的樣子是「那一格又空了」，沒有任何訊息。
///
/// 所以這裡的判準是**穩定度**而不是「有沒有網址」：只有恰好一個分頁的 Safari
/// 視窗，它的網址才真的是那個視窗的身分。
public enum AutoWindowName {
    /// **不叫 `Named`**：`SaveLayout` 已經有一個 `Named`（`rules` ＋ `labels`，
    /// `SaveLayout.swift:281`），同名兩個型別在兩個 scope 裡編得過，
    /// 但讀的人會以為是同一個。
    public struct Derived: Equatable, Sendable {
        public let label: String
        public let rule: JSONValue
    }

    /// - Parameters:
    ///   - dump: Safari 的分頁 dump。每行一個分頁，第一欄是 window id、第四欄是
    ///     is-current（`WindowMatching.swift:107`）。非 Safari 傳空字串即可。
    ///   - taken: 已經用掉的 label——**要含這一次存檔前面幾個視窗剛加的那些**，
    ///     不是只有磁碟上那份。
    ///   - existingAppRules: 已經有 `["app", X]` catch-all 的那些 app，同樣要含
    ///     這一次剛加的。
    /// - Returns: nil ＝ **這個視窗沒有穩定的身分可以認**。那不是遺漏，是正確答案：
    ///   推一條會失效的規則比不推更糟（見型別的 doc）。
    ///
    /// 兩條分支的**順序**是語意的一部分，不是排版：Safari 那條在 catch-all 那道
    /// 守衛**之前**。這個功能存在的理由就是「三個 Safari 視窗、只有兩條認得出
    /// Safari 的規則」，而那時 `existingAppRules` 必定含 `Safari`——守衛排前面的話
    /// 第三個視窗照樣回 nil，等於什麼都沒修。
    public static func derive(id: String, app: String, dump: String,
                              taken: Set<String>,
                              existingAppRules: Set<String>) -> Derived?
    {
        let label = nextLabel(base: app, taken: taken)
        if app == "Safari", tabCount(of: id, in: dump) == 1,
           let url = WindowMatching.currentTabURL(window: id, dump: dump), !url.isEmpty
        {
            // `url-contains` 而不是 `url-exact`：查詢字串（`?authuser=0`）會變，
            // 而它不是身分的一部分。
            return Derived(label: label, rule: object(label: label,
                                                      kind: "url-contains", value: url))
        }
        guard !existingAppRules.contains(app) else { return nil }
        return Derived(label: label, rule: object(label: label, kind: "app", value: app))
    }

    /// 這個視窗有幾個分頁。
    ///
    /// 切割與比對**整段借 `WindowMatching`**（`records`／`fields`／`column` 加
    /// `AwkText.equals`）而不是自己 split 一次：這個計數與 `currentTabURL` 必須對
    /// 同一批列說話，各寫一份的話兩者遲早分岔，而症狀是「算出只有一個分頁，卻拿到
    /// 別的視窗那一列的網址」——畫面上完全看不出來。
    ///
    /// 借過來的語意含 awk 的 numeric-string 比較（`currentTabURL` 的 `$1 == w`
    /// 就是它），所以 `191` 與欄位 `191.0` 算同一個視窗。那正是要一致的地方。
    static func tabCount(of id: String, in dump: String) -> Int {
        let want = AwkText.expandAssignmentEscapes(id)
        var count = 0
        for record in WindowMatching.records(of: dump) {
            let columns = WindowMatching.fields(of: record)
            if AwkText.equals(WindowMatching.column(columns, 1), want) {
                count += 1
            }
        }
        return count
    }

    /// 第一個沒用過的 `<app>`、`<app> 2`、`<app> 3`…
    ///
    /// **不是「最大加一」**：`HotkeyDocument.nextZoneName`（`GridZone.swift:67`）
    /// 是同一條規則，理由也一樣——名字是刪除與撞名判斷的鍵，跳號會留下永遠補不
    /// 回來的洞。
    static func nextLabel(base: String, taken: Set<String>) -> String {
        if !taken.contains(base) {
            return base
        }
        var number = 2
        while taken.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }

    private static func object(label: String, kind: String, value: String) -> JSONValue {
        .object([JSONMember(key: "label", value: .string(label)),
                 JSONMember(key: "match", value: .array([.string(kind), .string(value)]))])
    }
}
