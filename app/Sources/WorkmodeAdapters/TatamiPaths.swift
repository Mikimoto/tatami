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

    /// `mise run install` 建的那個 symlink。
    ///
    /// **絕對路徑，不是裸命令名**：消費端是 `HotkeyCommand.swift:72` 與
    /// `MenuActions.swift:121`——它們從 `Tatami.app` spawn 這支當子行程，而那個 app
    /// 是 login item、由 launchd 起，`PATH` 可能只剩
    /// `/usr/bin:/bin:/usr/sbin:/sbin`。裸名在那個環境**安靜失敗**。
    ///
    /// 不是 `Bundle.main.executablePath`：那在 `Tatami.app` 裡會指到 bundle 內那份
    /// 複製品（`mise run app` 封進去的），而使用者期待的是 `mise run install`
    /// 保持最新的那一份。
    ///
    /// 這段 doc 2026-09-15 改過。原文寫「寫進 `yabairc` 的東西要撐得過重新 build」
    /// 與「`skhdrc:164` 用的也是這個路徑」——**兩句都已成假**：寫 `yabairc` 那半
    /// 隨 signal 開關退役（`675aa18`），而 `skhd/skhdrc` 現在零條生效綁定、
    /// 第 164 行只是一個 `#`。守衛本身仍然需要，換的是理由。
    public static var installedExecutable: String {
        NSHomeDirectory() + "/.local/bin/tatami"
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
