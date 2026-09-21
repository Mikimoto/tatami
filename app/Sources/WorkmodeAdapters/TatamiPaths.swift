import Foundation

/// `layout.json`、`hotkeys.json` 與狀態檔的位置。
///
/// **兩段**：`TATAMI_DIR`（舊名 `WORKMODE_DIR` 仍認得，下一個版本拿掉）
/// → `~/.config/tatami`。目錄是**扁平**的，沒有 `scripts/` 那一層。
///
/// **2026-09-15 之前有第三段**：從執行檔往上找帶有 `scripts/layout.json` 的祖先。
/// 那一段存在的理由是**寫入**那側——`--save` 會覆寫 `layout.json`，而從一個 scratch
/// checkout 跑它就會寫進使用者正在用的設定（bash 寫的是那個 checkout 自己的檔）。
/// 設定搬出 repo 之後（`~/Developer/tatami` 只放程式碼）那一段**永遠找不到東西**、
/// 會靜默落到最後一段，也就是它本來要防的事。所以拿掉它，而不是留一個假的守衛：
/// **要沙盒就明寫 `TATAMI_DIR`**——這個 repo 每一次沙盒實測本來就都這樣跑。
///
/// 代價，明講：在 repo 裡跑 `./app/.build/debug/tatami --save` 會真的寫使用者的設定。
/// 那是刻意的——開發版與正式版行為逐字相同，開發機上看到的就是使用者看到的。
///
/// 用 `NSHomeDirectory()` 而不是展開 `~`：後者要自己處理 `$HOME` 沒設的情況，
/// 而那正是這支程式從 launchd（`Tatami.app` 是 login item）被叫起來時的環境。
/// **Swift 的 module 名還是 `Workmode*`**（這個檔住在 `WorkmodeAdapters`），改的只有
/// 型別名。理由見 CLAUDE.md：380 處 `workmode.sh:NNN` 是那支已刪除的 bash 的出處
/// 軌跡，module 改名等於把那條線索一起剪斷。
public struct TatamiPaths: Sendable {
    /// 那兩個檔所在的目錄。
    public let directory: String

    public var layout: String {
        directory + "/layout.json"
    }

    public var state: String {
        directory + "/.tatami-state"
    }

    /// 快捷鍵設定。與 `layout.json` 同一個目錄，但是**另一個檔**——那份有
    /// `LayoutValidator` 與 2257 組凍結語料在守，多一個 top-level 鍵要動 validator，
    /// 而換來的只是少一個檔案。
    public var hotkeys: String {
        directory + "/hotkeys.json"
    }

    /// **正在跑的那個執行檔自己。**
    ///
    /// 消費端是 `HotkeyCommand.swift` 與 `MenuActions.swift`——它們 spawn 一個新的
    /// `tatami <子命令>`（`grid`／`edit`）。spawn 自己保證了「父子是同一個版本」，
    /// 而那正是 cask 的 `binary` stanza 對使用者的承諾：一個產物、一個版本。
    ///
    /// **2026-09-21 從寫死的 `~/.local/bin/tatami` 改成這樣，因為前者對每一個
    /// 用 Homebrew 裝的人都是死的。** 那條 symlink 是 `mise run install` 建的開發
    /// 用入口；cask 把 CLI 連到 `/opt/homebrew/bin/tatami`，全新安裝的人 `~/.local`
    /// 底下什麼都沒有。選單列的「格線」與「編輯設定」、以及 ⌃⌥⌘G，三個入口在
    /// 0.1.0 對他們**全部無效且無聲**。
    ///
    /// 舊 doc 反對用 `Bundle.main.executablePath` 的理由是「在 .app 裡它指到 bundle
    /// 內的複製品，而使用者期待 `mise run install` 保持最新的那一份」。那是開發
    /// 便利的論點，而它換來的是**選單列與它 spawn 的子行程可能是兩個版本**——
    /// 混版比舊版糟。要讓 bundle 跟上就跑 `mise run app`。
    ///
    /// 三種情境實測（2026-09-21，各用一個自編的 probe 執行檔）：
    ///
    /// | 怎麼叫的 | `executablePath` |
    /// |---|---|
    /// | 裸執行檔 | 它自己的路徑 |
    /// | bundle 內直接叫 | `…/Probe.app/Contents/MacOS/Probe` |
    /// | 經 symlink 叫 bundle 內那份 | **symlink 自己的路徑** |
    ///
    /// 第三種是 cask 的形狀（`/opt/homebrew/bin/tatami`），回傳值仍是可 spawn 的
    /// 有效路徑，所以三種都成立。**都是絕對路徑**，而那是硬需求：這個 app 由
    /// launchd 起，`PATH` 可能只剩 `/usr/bin:/bin:/usr/sbin:/sbin`，裸命令名在那裡
    /// 安靜失敗。
    ///
    /// **回 Optional 而不是退回一個猜的路徑**：猜錯正是這個缺陷的成因。拿不到就
    /// 讓呼叫端說出來（`MenuActions.spawn`）。實務上 Foundation 對任何執行檔都
    /// 給得出這個值，那條 nil 路徑沒有已知的觸發輸入。
    public static var runningExecutable: String? {
        Bundle.main.executablePath
    }

    public init(directory: String) {
        self.directory = directory
    }

    /// 兩段：`TATAMI_DIR`（舊名 `WORKMODE_DIR` 仍認得）→ `~/.config/tatami`。
    ///
    /// 空字串的覆寫當成沒設：`TATAMI_DIR=` 是「取消覆寫」而不是「用根目錄」。
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory())
    {
        if let override = environment["TATAMI_DIR"] ?? environment["WORKMODE_DIR"],
           !override.isEmpty
        {
            directory = override
        } else {
            directory = home + "/.config/tatami"
        }
    }
}
