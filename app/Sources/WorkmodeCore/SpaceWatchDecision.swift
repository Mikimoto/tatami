import WorkmodeDomain

/// 常駐的選單列 app 要不要自己聽 space 切換。
///
/// 2026-09-08 之前這件事只有一個實作：yabai 的 `space_changed` signal 呼叫
/// `tatami __space-signal`。那條路把 tatami 綁在 yabai 身上——yabai 不在就沒有事件。
/// 現在 `Tatami.app` 自己聽得到（`NSWorkspace.activeSpaceDidChangeNotification`，
/// 實測 2026-09-08 連切四次四次都到）。
///
/// **2026-09-15 起只剩一個判斷：開關開了沒。** 在那之前還有第二個——「yabai 的
/// signal 還裝著嗎」——因為兩個來源同時開著就是每次切 space 排兩次，而畫面上那
/// 看起來只是「排版跳了一下」。yabai 從這台機器移除、`SignalBlock` 的寫入那半也
/// 拆光之後，沒有任何東西會裝上那個 signal，所以那個問題連同它一起退役了。
///
/// **留著 enum 而不換成 Bool**：呼叫端那個 `switch` 的窮舉檢查值錢（將來多一個
/// 「誰負責」的來源會是編譯錯誤，不是漏掉一條分支），而 `key` 與「`on` 以外都是關」
/// 那條規則要有一個家。
///
/// **放 Core 因為它是判斷**：AppKit 那半（收通知、起計時器）在 CLI，而那一層
/// 沒有測試跑得到。
public enum SpaceWatchDecision: Equatable, Sendable {
    /// 這個行程負責聽。
    case observe
    /// 使用者沒開這個功能。
    case disabled

    /// 狀態檔裡的鍵。`on` 以外的任何值（含缺鍵）都是關。
    ///
    /// 預設關是刻意的：這是這個工具**唯一**會持續在背景改變畫面的功能，
    /// 其餘都是使用者按了才動。
    public static let key = "autospace"

    /// - Parameter state: 狀態檔全文。
    public static func decide(state: String) -> SpaceWatchDecision {
        StateFile.value(forKey: key, in: state) == "on" ? .observe : .disabled
    }
}
