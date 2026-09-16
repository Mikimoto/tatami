import Foundation
import WorkmodeCore

/// osascript 回非零。
///
/// 只有 `safari_tab_dump` 用得到：`app_running` 的 port 簽名不 throw，因為 bash 那側
/// `[ "$(osascript … 2>/dev/null)" = "true" ]` 把「osascript 壞了」與「沒在跑」
/// 收斂成同一條路。
public enum OsascriptError: Error, Equatable, Sendable {
    case failed(status: Int32)
}

/// `/usr/bin/osascript` 寫死，不像 yabai 那樣去找。
///
/// 它是 macOS 內建的，不能被移除也不會裝在別的地方；而「先 Homebrew 再 PATH」那套
/// 存在的理由（skhd 起的 process 沒有 shell 的 PATH）在這裡剛好反過來——
/// `/usr/bin` 在任何 PATH 裡都有，寫死路徑只是把那個查詢省掉。
let osascriptPath = "/usr/bin/osascript"

/// workmode.sh:584 的 `safari_tab_dump`。
public struct SafariOsascriptClient: SafariClient, Sendable {
    public init() {}

    /// 這段字串必須與 workmode.sh:585-611 的 heredoc **逐位元組相同**。
    ///
    /// AppleScript 是空白與換行敏感的語言，而這份輸出（`<id>\t<url>\t<title>\t<is-current>`）
    /// 會餵給 `WindowMatching` 裡的位元組層 ERE 引擎——差一個位元組就是靜默配不到視窗。
    /// 驗法是 `workmode __smoke safari-script` 印出這裡的內容，與
    /// `awk 'NR>=585 && NR<=611' scripts/workmode.sh` 做 `cmp`。
    public static let script = """
    set TABCH to (ASCII character 9)
    tell application "Safari"
      set out to ""
      repeat with w in windows
        set wid to (id of w) as text
        set ci to 0
        try
          set ci to (index of current tab of w)
        end try
        set i to 0
        repeat with t in tabs of w
          set i to i + 1
          set u to ""
          try
            set u to (URL of t) as text
          end try
          set nm to ""
          try
            set nm to (name of t) as text
          end try
          set isc to "0"
          if i = ci then set isc to "1"
          set out to out & wid & TABCH & u & TABCH & nm & TABCH & isc & linefeed
        end repeat
      end repeat
      return out
    end tell

    """

    /// 腳本從 **stdin** 餵進去，不用 `-e`。
    ///
    /// bash 是 heredoc，而 `-e` 是「每個參數一行敘述」的模式：多行腳本用 `-e` 要拆成
    /// 一串參數，換行與縮排的處理就不一樣了。既然要逐位元組對齊，就別換管道。
    ///
    /// stderr 不擋：bash 這個呼叫點**沒有** `2>/dev/null`（`app_running` 與
    /// `open -a` 才有），Safari 沒有自動化權限時的那句抱怨要讓使用者看得到。
    ///
    /// rc≠0 就 throw，即使 bash 那側沒人看它（`dump=$(safari_tab_dump)`，而腳本沒開
    /// `set -e`，所以失敗等於 dump 是空字串）。理由與 YabaiClient 相同：要複製
    /// 「當成空的」就在 Core 寫 `(try? client.tabDump()) ?? ""`，讓那個決定看得見。
    public func tabDump() throws -> String {
        let result = try runProcess(executable: osascriptPath, arguments: [],
                                    stdin: Data(Self.script.utf8), inheritStderr: true)
        guard result.status == 0 else { throw OsascriptError.failed(status: result.status) }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
