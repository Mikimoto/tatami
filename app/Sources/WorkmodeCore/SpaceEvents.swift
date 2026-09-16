import WorkmodeDomain

// `workmode --space`（phase 3a）。這一組**沒有 bash 對應**——bash 那版沒有這條路徑，
// 所以 `tests/oracle` 對它沒有意見，中文由這個 repo 自己定。
//
// 前四個 case 分別是「這個螢幕為什麼沒動」的**三種**理由加上「動了」，
// 第五個（`frameRejected`）是「動了但沒動到位」。合併成一個帶字串
// 的 case 等於宣稱它們永遠一起變（見 `Reporter.swift` 檔頭的五條約定）：三種理由要修
// 的東西完全不同——螢幕沒接上、螢幕接著但抓不到可見的 space、要去 `spaceTrees`
// 畫一棵樹。

/// `--space` 逐螢幕的結果。
public enum SpaceEvent: Equatable, Sendable {
    /// 這個角色在 `displays` 裡查不到 uuid，或那台螢幕現在沒接上。
    case spaceRoleDisplayMissing(role: String)

    /// 螢幕在，但抓不到它當下可見的 space（query 失敗或那台螢幕一個 space 都沒有）。
    case spaceRoleHasNoVisibleSpace(role: String)

    /// 這個 space 在這個 profile 的 `spaceTrees` 裡沒有樹。
    ///
    /// 帶著 uuid 是因為使用者要拿它去設定裡貼——沒有它，這句話等於叫人自己去查。
    /// **2026-08-30 之前這是兩個 case**（`spaceIsNotNamed` 與 `namedSpaceHasNoTree`），
    /// 因為當時查表要先過名字那一層，兩種失敗要修的東西不同（去 `spaces` 加名字
    /// vs 去 `spaceTrees` 畫樹）。uuid 直接當索引之後只剩一種。
    case spaceHasNoTree(role: String, uuid: String)

    /// AX 設 frame 是請求不是命令：app 可以夾（最小尺寸、超出可視區）、可以不回應。
    /// `actual` 是設完重讀到的值，nil ＝ 設不下去（AX 逾時或找不到那個視窗）。
    /// yabai 那條路這件事被 bsp 吸掉了；這裡要說出來，否則「切過去它沒對齊」
    /// 零訊號。
    case frameRejected(label: String, wanted: Rect, actual: Rect?)

    /// `--all` 專用：設定裡有這棵樹，但那個 uuid 的 space 現在**不在這個角色的螢幕上**
    /// ——被 macOS 刪掉了、或拔插螢幕之後跑到別台去了。兩種在查得到的資訊裡分不出來
    /// （都是「這台上找不到它」），而處置相同：跳過。用別台的畫布去排它會把視窗
    /// 放到螢幕外，那比不動更糟。
    case spaceNotOnItsDisplay(role: String, uuid: String)

    /// 排好了。
    case spaceLaidOut(role: String, uuid: String)

    /// 「這個角色做了或沒做什麼」走 stdout，與 `TreeEvent` 那組跳過的理由同一個管道
    /// （`LayoutEvents.swift:123-129`）：它們不是錯誤。
    /// `frameRejected` 是另一種東西——使用者要的事沒有完全做到，走 stderr。
    public var channel: OutputChannel {
        switch self {
        case .spaceHasNoTree, .spaceLaidOut, .spaceNotOnItsDisplay,
             .spaceRoleDisplayMissing, .spaceRoleHasNoVisibleSpace:
            .stdout
        case .frameRejected:
            .stderr
        }
    }
}
