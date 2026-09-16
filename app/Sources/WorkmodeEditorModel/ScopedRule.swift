import WorkmodeDomain

/// 一條視窗規則寫在檔案的哪一層。
///
/// **地點層是疊加，profile 層是取代。** `__diff windows_for <地點> <profile> <設定>`
/// 對同一份設定實測（2026-08-19：共用兩條、`office` 一條，只換 profile 那個鍵）：
///
/// ```
/// # 沒有 windows 這個鍵 → 共用兩條，接上地點那條
/// 共用A	app	A	-	-
/// 共用B	app	B	-	-
/// 地點郵件	app	Mail	-	-
/// # "windows": null → 與缺鍵逐字相同
/// 共用A	app	A	-	-
/// 共用B	app	B	-	-
/// 地點郵件	app	Mail	-	-
/// # "windows": [ 一條 ] → 前兩層整組不見，一筆都不留
/// profile專屬	app	P	-	-
/// # "windows": [] → 一行都沒有（rc 仍是 0）
/// ```
///
/// 所以取代的觸發條件是**這個鍵有一個真值**，不是「有沒有這個鍵」：`[]` 在 jq 是
/// truthy 所以取代成零條，而 `null` 與 `false` 是假值、沿用前兩層（兩者都實測過，
/// 輸出與缺鍵逐字相同）。共用與地點之間沒有這個開關，永遠是 `add`。
///
/// 機制在 `LayoutQuery.swift:114-122`（產品路徑；`isTruthy` 在 `:153-159`）與
/// `LayoutValidatorJQ.swift:42-51`（validator 算生效 label 用的同一套）。
/// 那個接起來的順序就是認領視窗的優先序，所以前後有意義。
///
/// 這個型別描述的是「這一列寫在哪」，不是「這一列現在生不生效」——後者要看使用者
/// 選了哪個 profile，而表格是整份檔的清單。分不出來源的話，被取代掉的那幾列看起來
/// 與生效的完全一樣。
public enum RuleScope: Equatable, Sendable {
    case shared
    case location(String)
    case profile(location: String, profile: String)
}

public extension RuleScope {
    /// 這一層的 `windows` 陣列在文件裡的路徑。
    ///
    /// 判斷放 Model 不放 view body，與 `isProfileScoped` 同一條：`WorkmodeEditorUI`
    /// 沒有任何測試驗得到（`DependencyRuleTests` 的三條禁令就是為了讓判斷寫不進去），
    /// 而少一段 `.key("profiles")` 的症狀是編輯打在別的地方，畫面上零訊號。
    ///
    /// 鍵名用 `LayoutQuery.reservedKey` 而不是字面的 `"windows"`：全系統只有那一份
    /// 宣告（理由與 `LayoutDocument.locations` 同一條）。
    var windowsPath: [JSONPath.Step] {
        switch self {
        case .shared:
            [.key(LayoutQuery.reservedKey)]
        case let .location(name):
            [.key(name), .key(LayoutQuery.reservedKey)]
        case let .profile(location, profile):
            [.key(location), .key("profiles"), .key(profile), .key(LayoutQuery.reservedKey)]
        }
    }

    /// 「要不要提示取代不是疊加」的判準之一，另一個是 `RuleLayer.declaresRules`
    /// ——`ruleLayers` 對**每個** profile 都產一列，光看 scope 那行提示會永遠出現。
    /// 兩者怎麼合起來在 `LayoutDocument.anyProfileLayerDeclaresRules`：判斷放 Model
    /// 不放 view body，`WorkmodeEditorUI` 沒有任何測試驗得到（`DependencyRuleTests`
    /// 的三條禁令就是為了讓判斷寫不進去），而 `if case` 錯寫成 `.location`
    /// 在畫面上零訊號。
    var isProfileScoped: Bool {
        if case .profile = self {
            return true
        }
        return false
    }
}

/// 表格的一列：規則本身，加上它寫在哪一層。
///
/// 沒有把 `scope` 併進 `RuleRow`：那一支是「一條規則長什麼樣」，同一份內容出現在
/// 兩層時兩者是相等的，而這一支要分得出來。
public struct ScopedRule: Equatable, Sendable {
    public let scope: RuleScope
    /// 它在**自己那一層**的 `windows` 陣列裡的索引，不是在 `allRules` 裡的位置。
    /// 編輯拿它組路徑（`scope.windowsPath + [.index(index)]`），所以它必須對得回檔案。
    ///
    /// 非有不可的理由：`RuleRow` 是**有損投影**（非字串走 `JQPrint.interpolate`，
    /// 所以 `"label": 7` 投影成 `"7"`、缺 label 投影成 `"null"`），把一列整個寫回去
    /// 會把使用者的 `7` 改成 `"7"`。編輯只能表示成「把這條路徑的值設成 X」，
    /// 而 UI 從一列反推不出它在檔案裡的位置。
    public let index: Int
    public let row: RuleRow

    public init(scope: RuleScope, index: Int, row: RuleRow) {
        self.scope = scope
        self.index = index
        self.row = row
    }
}
