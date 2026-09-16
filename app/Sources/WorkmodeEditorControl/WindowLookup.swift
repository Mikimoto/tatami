import WorkmodeEditorModel

/// 「現在開著哪些視窗」這一支單獨一個檔，理由與 `SaveCommand.swift` 從 `main.swift`
/// 搬出來同一條：`EditorController.swift` 已經在 swiftlint `file_length` 的 400 行
/// 門檻邊上，而那個參數不准調（`.swiftlint.yml` 檔頭明文禁止）。
public extension EditorController {
    /// 現在開著哪些視窗。挑一個就能建出一條規則。
    ///
    /// **回空陣列而不是 nil**（與 `connectedDisplays()` 同一條）：呼叫端要顯示的是
    /// 一份清單，「查不到」與「一台都沒開」在畫面上都是同一件事。
    ///
    /// **這一支要兩秒**：它 spawn 兩個子行程，而 Safari 的分頁 dump 實測 1.94 秒
    /// （13 視窗／93 分頁）。UI 一定要查一次記起來，不能寫在 body 的求值路徑上
    /// ——`connectedDisplays()` 與 `spaceOptions()` 已經踩過這個坑。
    func connectedWindows() -> [WindowChoice] {
        windows?() ?? []
    }
}
