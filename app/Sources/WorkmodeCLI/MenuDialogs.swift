import AppKit

/// 選單列的模態對話框。
///
/// 從 `MenuCommand.swift` 搬出來的理由是 `file_length`（上限 400，`.swiftlint.yml`
/// 檔頭明文禁止調參數）：那個檔本來 311 行，而子選單與兩個新對話框放不進去。
/// 先例是 `EditCommand.swift` → `SaveCommand.swift`。
///
/// 分界是「選單組裝」與「問人一句話」：這裡每一支都 `runModal()`，而
/// `MenuCommand` 一次都不叫它。所以「按了會不會跳東西出來」只要看這個檔。
@MainActor
enum MenuDialogs {
    /// 覆蓋既有 profile 的確認。
    ///
    /// **破壞性那顆不排第一**：第一顆是 Enter 的預設鍵，而這個對話框存在的理由
    /// 正是攔下反射性的確認（與關窗那個「有未儲存的變更」逐字同一條）。
    ///
    /// **點名 profile 與它現有幾個 space 的樹**：子選單之後這個框可能問的是一個
    /// 不是目前在用的 profile，所以「這個 profile」講不清是哪個；而數字讓
    /// 「覆蓋一個空殼」與「覆蓋兩天的工作」分得出來。
    static func confirmOverwrite(profile: String, trees: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "把每個 space 目前的排版存進「\(profile)」？"
        alert.informativeText = (trees > 0
            ? "這會覆蓋「\(profile)」裡那 \(trees) 個 space 的樹。"
            : "「\(profile)」現在沒有存過任何 space 的樹。")
            + "認不出名字的視窗不會被存進去。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "覆蓋")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 問一個新 profile 的名字。回 nil ＝取消或打了空的。
    static func askNewProfileName() -> String? {
        let alert = NSAlert()
        alert.messageText = "存成新的 profile"
        alert.informativeText = "名字不能有空白，也不能叫 auto。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")
        // 讓游標一開始就在輸入框裡，不然要先點一下才打得了字。
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 存檔的結果一定要看得到——選單列上「按了沒反應」與「存好了」長得一樣。
    static func reportSaveResult(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "存檔結果"
        alert.informativeText = text.isEmpty ? "沒有輸出。" : text
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    /// 切 profile 失敗。
    ///
    /// 為什麼要一個對話框：這件事的訊息本來只落 stderr（`/tmp/tatami_menu.log`），
    /// 而選單列上「切失敗了」與「切好了」長得一模一樣——2026-09-10 就是這樣讓
    /// 一次「重排之後視窗沒就位」查了兩輪才找到成因。與 `reportSaveResult`
    /// 逐字同一條理由。
    ///
    /// 明講「版面沒有動」：使用者按的那一項是「切過去並重排」，而我們停在第一步。
    static func reportSwitchFailure(profile: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = "沒切成「\(profile)」"
        alert.informativeText = (reason.isEmpty ? "沒有說明。" : reason)
            + "\n版面沒有動。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
