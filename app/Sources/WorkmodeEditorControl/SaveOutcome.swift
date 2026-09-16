import WorkmodeDomain

/// 存檔的四種結果。三種擋下來的各自要在畫面上講不同的話，所以不能收斂成 Bool。
public enum SaveOutcome: Equatable, Sendable {
    case written
    /// `LayoutValidator` 擋下來的。與 `workmode validate` 同一支，所以編輯器擋掉的
    /// 與 CLI 擋掉的必然一致。
    case blockedByValidation([LayoutProblem])
    /// 檔案在載入之後被別人改過。phase 1 的 UI 只把這件事講出來（`EditorWindow.swift:91`
    /// 印「關掉重開會載入新的內容」），沒有「蓋過去」的選項——`save(force: true)`
    /// 在 `app/Sources/` 底下一個呼叫點都沒有，只有測試在走它。那條路 phase 2
    /// 有編輯動作、真的會有東西可以蓋的時候才接上去。
    case blockedByExternalChange
    /// 寫檔本身失敗（權限、磁碟）。原子寫保證沒有留下半份檔案。
    case failed(String)
}
