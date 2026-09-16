/// 表格上一層規則的清點：這一層有沒有宣告 `windows`，以及它實際產出幾列。
///
/// **`allRules` 帶不出「有宣告卻一列都沒有」，而那正是完全沒有訊號的兩種情況。**
/// 兩種都實測過（`__diff`，2026-08-19）：
///
/// - `"windows": []`：空陣列在 jq 是 truthy，所以 profile 層寫它會把共用層與地點層
///   整組取代成零條（`windows_for` 零行、rc=0），而 `validate` 對這件事本身一聲不吭
///   （實測 rc=0）。它只查「樹引用的 label 在不在生效清單裡」，所以真的抱怨起來
///   指的是那棵樹，不是這個空陣列——使用者照著訊息去改樹，改不到病灶。
///   **但這只對 profile 層成立。** 共用層與地點層之間永遠是疊加（`ScopedRule.swift`
///   檔頭的實測），所以那兩層寫空陣列等於疊加零條＝什麼都沒做，不該出聲。
///   把三種層一視同仁的那個版本讓使用者看到「有 2 層…取代成零條」，而實測他那
///   六條共用規則全部生效（2026-08-29，`__diff windows_for office 開發`）。
/// - `"windows": 7`（不是陣列）：`validate` 一樣 rc=0（jq 在 `add`／`map(.label)`
///   runtime error，整個串流中止，連別處不相關的違規也一起吞掉），但 `windows_for`
///   是 **rc=5 的硬錯**。也就是這份檔存得下去、`workmode` 跑起來會壞，而表格對那
///   一層一列都不畫。
///
/// 所以這兩種都得由編輯器自己出聲，沒有別人會說。
public struct RuleLayer: Equatable, Sendable {
    public let scope: RuleScope

    /// 這一層有沒有 `windows` 這個鍵。**`null` 與 `false` 算沒有**——jq 的 `//`
    /// 把它們當假值，所以它們與缺鍵走同一條路（實測：三者的 `windows_for` 輸出
    /// 逐字相同）。判準的來源是 `LayoutQuery.isTruthy`（`:153-159`）與
    /// `LayoutValidatorJQ.alternative`（`:238-244`），兩支都不是 public，
    /// 所以 `LayoutDocument.declares` 是第三份副本，靠測試釘住那三種輸入。
    public let declaresRules: Bool

    /// 這一層在表格上產出幾列。`declaresRules` 為真而這裡是 0，就是「有宣告但
    /// 看不到」——空陣列與非陣列都落在這裡（`LayoutDocument.rows(at:)` 對非陣列回空）。
    public let ruleCount: Int

    /// 宣告的那個值**是不是陣列**。`ruleCount == 0` 分不出「空陣列」與「不是陣列」，
    /// 而那兩件事的後果完全不同：空陣列只在 profile 層有害（取代），非陣列在任何層
    /// 都會讓 `windows_for` 回 rc=5。合在一起講的那句話對地點層是假的
    /// （2026-08-29 拿使用者真的設定實測）。
    public let declaresArray: Bool

    public init(scope: RuleScope, declaresRules: Bool, ruleCount: Int, declaresArray: Bool) {
        self.scope = scope
        self.declaresRules = declaresRules
        self.ruleCount = ruleCount
        self.declaresArray = declaresArray
    }
}
