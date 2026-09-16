import WorkmodeDomain

// `tatami` 自己的快捷鍵（取代退役的 skhd 綁定；數字不寫在這裡，skhdrc 退役當天
// 是 47 條而搬過來的那些會增減）。這一組**沒有 bash 對應**，
// 所以 `tests/oracle` 對它沒有意見，中文由這個 repo 自己定。
//
// 「排好了」沒有 case：一個成功的快捷鍵動作，證據就是畫面動了。每按一次印一行
// 只會把 `/tmp/tatami_app.log` 灌滿，而那個檔是查「按了沒反應」用的——那時
// 要看的正是這裡的每一句。

/// 按下一個快捷鍵之後發生的事。
public enum HotkeyEvent: Equatable, Sendable {
    /// 沒有焦點視窗。螢幕鎖著時 AX 那半整個是空的，這是誠實的失敗。
    case hotkeyNoFocusedWindow

    /// 那個方向沒有鄰居。**不是錯誤**——畫面最左邊那個視窗按左鍵就是這樣。
    case hotkeyNoNeighbour(direction: String)

    /// `space:7` 而現在只有 5 個 space。帶著它是為了讓人知道要去改設定。
    case hotkeySpaceNotFound(target: String)

    /// `display:3` 而現在只接了兩台。拔掉外接螢幕之後這會很常見。
    case hotkeyDisplayNotFound(target: String)

    /// 一條綁定解不出來。整份拒絕會關掉全部快捷鍵，安靜跳過則讓那一條變成
    /// 「按了沒反應」——所以跳過並且說出來。
    ///
    /// `detail` **自帶出處前綴**（`hotkeys.json 第 3 條：…`）：同一個 case 也給
    /// `tatami __hotkey <動作>` 用，而那條路上沒有那個檔。
    case hotkeyBindingRejected(detail: String)

    /// 同一組鍵綁了兩次。`RegisterEventHotKey` 對重複的組合回錯誤，所以後面那條
    /// 安靜地不生效；不說的話使用者會以為自己改的那條沒存到。
    case hotkeyConflict(key: String)

    /// `shell:` 那道逃生門跑失敗。
    case hotkeyShellFailed(command: String, status: Int32)

    /// 滑鼠拖曳裝好了。**這是正面訊號，不是雜訊**：沒有它，「這個功能開著沒」
    /// 只能靠「沒看到錯誤」推論，而那與「根本沒跑到那段」外觀相同——查這個
    /// 功能為什麼沒反應時，第一件事就是看有沒有這一行、以及修飾鍵是哪一顆。
    case hotkeyMouseTapInstalled(modifier: String)

    /// 滑鼠拖曳裝不起來。`tapCreate` 被系統拒絕（授權還沒生效）或兩顆都關掉，
    /// 兩者在這裡分得出來——後者是使用者自己設的，不該報成失敗。
    case hotkeyMouseTapRefused

    /// 註冊完成。`skipped` 是 `RegisterEventHotKey` 拒絕的那些（多半是被別的
    /// app 或系統佔走了），它們同樣是「按了沒反應」的成因。
    case hotkeysRegistered(count: Int, skipped: Int)

    /// 「這個鍵今天沒做到你要的事」走 stderr；「那個方向沒有鄰居」不是錯誤，
    /// 走 stdout（與 `SpaceEvent` 那幾個跳過的理由同一個管道）。
    public var channel: OutputChannel {
        switch self {
        case .hotkeyMouseTapInstalled, .hotkeyNoNeighbour, .hotkeysRegistered:
            .stdout
        case .hotkeyBindingRejected, .hotkeyConflict, .hotkeyDisplayNotFound,
             .hotkeyMouseTapRefused, .hotkeyNoFocusedWindow, .hotkeyShellFailed,
             .hotkeySpaceNotFound:
            .stderr
        }
    }
}
