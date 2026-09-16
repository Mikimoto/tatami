/// 「現在有哪些 space 可以命名」的答案。
///
/// **空清單有四個成因，而它們長得一模一樣**——沒接上 yabai、這個角色還沒指定螢幕、
/// 指定了但那台沒接上、以及真的一個都沒有。分不開的話畫面只能說「查不到」，
/// 而使用者會去修錯的地方。與 `spaceStatusText`（`YabaircSpaceEdit.swift`）對
/// 「清單是空的」與「這個編號不存在」是同一條判準。
///
/// **句子放在這裡不放 UI**：`WorkmodeEditorUI` 零測試，四選一與措辭寫進去就沒有
/// 東西驗它（與 `sweepNotice`、`canSave`／`canRestart` 逐字同一條理由）。
public enum SpaceOptions: Equatable, Sendable {
    /// 那台螢幕上的 space，已經過濾且排序過。
    case ready([SpaceChoice])
    /// 沒接上 yabai——沒有現場清單可問。
    case yabaiUnavailable
    /// 這個角色的 `displays` 項目不存在，或是空字串。
    ///
    /// **空字串是刻意留的**：新增地點時 `main` 的 uuid 就是空的（留一個看得見的洞
    /// 比留一個看不見的假值好），所以它必須與「沒定義」走同一條路。
    case noDisplayAssigned
    /// 有 uuid，但它不在 yabai 現在列出來的螢幕裡。
    case displayNotConnected

    /// 給人看的那一句。`.ready` 是 nil——正常路徑上不出聲。
    public var note: String? {
        switch self {
        case .ready: nil
        case .yabaiUnavailable: "沒接上 yabai，查不到現在有哪些 space。"
        case .noDisplayAssigned: "這個角色還沒指定螢幕，指定之後才挑得到它的 space。"
        case .displayNotConnected: "這個角色的螢幕現在沒接上，接上之後才挑得到它的 space。"
        }
    }
}
