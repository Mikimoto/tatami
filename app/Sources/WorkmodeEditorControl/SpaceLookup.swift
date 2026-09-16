import WorkmodeEditorModel

/// 「這個角色的螢幕上有哪些 space」單獨一個檔，理由與 `WindowLookup.swift`
/// 逐字相同：`EditorController.swift` 已經在 swiftlint `file_length` 的 400 行門檻
/// 邊上，而那個參數不准調（`.swiftlint.yml` 檔頭明文禁止）。
public extension EditorController {
    /// 角色 → 螢幕 uuid → 現場的 display index → 那台螢幕的 space。
    ///
    /// **回 `SpaceOptions` 而不是陣列**：空陣列有四個成因而它們長得一模一樣，
    /// 分不開的話畫面只能說「查不到」，使用者會去修錯的地方。
    ///
    /// **每次呼叫最多 spawn 兩個子行程**（`--displays` 與 `--spaces`）——只有走到
    /// `.ready` 才兩個都跑，三條失敗路各是 1 個或 0 個。所以 UI 要
    /// 查一次記起來，不能寫在 view body 的求值路徑上——`connectedDisplays()` 與
    /// 舊的 `connectedSpaces()` 都踩過這個坑。
    ///
    /// **display index 不能記住**：重新插拔會跳號（實測使用者的機器是 1、3、2），
    /// 所以每次都從 uuid 現算。
    func spaceOptions(displayUUID: String?, treed: [String]) -> SpaceOptions {
        // yabai 先問：沒有它就什麼都列不出來，這時候講「螢幕沒接上」是我們沒問到
        // 卻怪到設定頭上。
        guard let spaces, let displays else { return .yabaiUnavailable }
        // **空字串與 nil 同一條路**：新增地點時 `main` 的 uuid 就是刻意留空的
        // （留一個看得見的洞比留一個看不見的假值好），寫成 `if let` 會讓 `""` 落進
        // 「螢幕沒接上」而訊息指錯地方。
        guard let displayUUID, !displayUUID.isEmpty else { return .noDisplayAssigned }
        guard let index = displays().first(where: { $0.uuid == displayUUID })?.index else {
            return .displayNotConnected
        }
        return .ready(SpaceChoice.merge(spaces(), treed: treed, onDisplay: index))
    }
}
