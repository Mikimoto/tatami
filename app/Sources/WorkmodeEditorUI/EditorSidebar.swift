import WorkmodeEditorControl

// 側欄的選取與它的列。**搬出 `EditorWindow` 的理由是 lint**：快捷鍵那一頁接上
// 之後那個 struct 的 body 超過 `type_body_length`（上限 250，不計註解與空行），
// 而 `.swiftlint.yml` 開頭明寫不准為了讓數字消失去調參數。這兩個型別不碰任何
// `private` 欄位，所以搬得動（`EditorWindowSave.swift` 同一個判準）。

/// 側欄選中的是什麼。規則總表不屬於任何地點，所以不能只用 (location, profile)。
enum Selection: Hashable {
    case rules
    /// `hotkeys.json`。與 `rules` 一樣不屬於任何地點。
    case hotkeys
    /// 每台螢幕的格數與間距。同上不屬於任何地點。
    case grid
    /// 地點自己也是一個可選的 row：它的 desc、螢幕角色與 profile 清單都在那個面板。
    case location(String)
    case profile(location: String, profile: String)
}

enum EditorSidebar {
    /// 側欄的一列。**名字不能當 id**，與 `CanvasView.IndexedCanvasRole` 及
    /// `RuleTableView.IndexedRule` 同一條——這裡踩到的是第三次：`office` 與 `home`
    /// 底下都有一個叫「開發」的 profile，而巢狀 `ForEach(profiles, id: \.self)`
    /// 讓那兩列在同一個 `List` 裡共用 id `"開發"`，於是點其中一個**兩個一起反白**
    /// （2026-08-21 使用者實測截圖）。
    ///
    /// phase 2c 之前地點是 `Section`，那給了內層一個作用域所以看不出來；2c 把地點
    /// 改成可選的 row（`Section` 標題在 `List(selection:)` 裡選不到）之後才現形。
    ///
    /// 用來源順序的整數：天生唯一，順序也有意義。
    struct SidebarRow: Identifiable {
        let id: Int
        let selection: Selection
        /// nil 代表這是地點自己那一列；非 nil 是它底下的 profile 名。
        let profile: String?
        let location: String
    }

    static func rows(of controller: EditorController) -> [SidebarRow] {
        var out: [SidebarRow] = []
        for location in controller.locations {
            out.append(SidebarRow(id: out.count, selection: .location(location),
                                  profile: nil, location: location))
            for profile in controller.document?.profiles(in: location) ?? [] {
                out.append(SidebarRow(
                    id: out.count,
                    selection: .profile(location: location, profile: profile),
                    profile: profile, location: location
                ))
            }
        }
        return out
    }
}
