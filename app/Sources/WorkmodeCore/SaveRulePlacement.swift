import WorkmodeDomain

// 這一輪新加的規則要落在設定的哪個位置。判斷全在 Domain（`RulePlacement`），
// 這裡只接線與記帳。
//
// 自成一檔的理由是 `file_length`（上限 400，`.swiftlint.yml` 的檔頭明文禁止調參數）：
// `SaveLayout.swift` 與 `SaveLayoutParts.swift` 都在 360 行上下。先例是
// `SaveAutoNames.swift`，而**不放進那一個**是因為它的標題是「自動命名」，
// 而放位置這件事兩條路都要做。

extension SaveLayout {
    /// 一條還沒寫進設定的新規則，以及它要認的視窗屬於哪個 app。
    ///
    /// **app 不從規則反推**：`title-regex` 那條的 `match[1]` 是標題、`url-contains`
    /// 那條是網址，只有 `["app", X]` 那條讀得出來。反推就得再寫一份「哪些 kind
    /// 屬於哪個 app」的對照表，而它與產生規則的那兩支（`WindowRules.rule`、
    /// `AutoWindowName.derive`）遲早分岔——分岔的症狀是規則放錯位置而永遠不生效，
    /// 那在畫面上與「沒加」完全相同。所以在**知道**答案的地方就把它帶上。
    struct NewRule {
        let rule: JSONValue
        let app: String
    }

    struct Seated {
        /// 已經把插得進去的那幾條寫好的整份設定。
        let config: JSONValue
        /// 插不進去的那幾條，交給 `ProfileMerge` 照舊接到落點尾端。
        let remaining: [JSONValue]
    }

    /// 每一條都先試著插到它要贏的那條 catch-all 前面；插不進去的留給呼叫端。
    ///
    /// **兩條路都要走這一趟**（`.terminal` 與 `.automatic`）。`askForNames` 產生的
    /// 規則本來也是接在生效清單的尾端，所以一條認 Safari 分頁的新規則同樣會排在
    /// `["app", "Safari"]` 後面而搶不到那個視窗——使用者親手打了名字卻沒有效果，
    /// 與自動那條是同一個缺陷。
    ///
    /// 逐條餵**上一條的結果**而不是每次都餵原始 `config`：後者的每一次
    /// `RulePlacement.place` 都從沒有前一條的那份算起，於是最後一條的結果會把
    /// 前面幾條整個蓋掉，而回傳值仍然說每一條都放好了。
    func seat(_ rules: [NewRule], location: String, profile: String,
              in config: JSONValue) -> Seated
    {
        var out = config
        var remaining: [JSONValue] = []
        for entry in rules {
            let placement = RulePlacement.place(entry.rule, forApp: entry.app,
                                                location: location, profile: profile,
                                                in: out)
            out = placement.config
            if !placement.placed {
                remaining.append(entry.rule)
            }
        }
        return Seated(config: out, remaining: remaining)
    }
}
