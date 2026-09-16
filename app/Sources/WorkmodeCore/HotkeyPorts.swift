// 快捷鍵動作需要、而 `Ports.swift` 那 8 個沒有涵蓋的兩件事。
//
// 分成獨立檔而不是塞進 `Ports.swift`：那個檔的檔頭說得很清楚，它的每個 case
// 都對應 bash 裡一個實際存在的呼叫形式，而這兩個沒有——bash 從來沒有把焦點
// 交給某個視窗，也沒有關過視窗。

/// 對焦點視窗本身動手：問它是誰、把焦點給它、關掉它。
///
/// 「問它是誰」與 `WindowServer.setFrame` 分開，是因為前者要 `NSWorkspace` 與 AX
/// 兩段（見 `FocusedWindow.swift`）而後者只要 AX；合成一個 port 會讓 fake 得同時
/// 假裝兩件無關的事。
public protocol WindowControl {
    /// 十進位字串，與 `YabaiQuery` 回的 `id` 同一個形狀。
    func focusedWindow() throws -> String
    /// 把那個視窗抬到最前面並讓它的 app 取得焦點。
    func focus(window: String) throws
    /// 按它的關閉鈕。**不是強制結束**——有未存檔案的 app 會跳自己的對話框，
    /// 那是對的行為。
    func close(window: String) throws
}

/// `shell:` 那道逃生門。
///
/// 存在的理由是使用者的 `skhdrc` 裡有與視窗管理無關的綁定（顯示／隱藏桌面那條
/// 改的是 Finder 的 defaults），少了它那個檔就退不了役。信任層級與 `skhdrc`
/// 相同：那個檔本來就是使用者自己寫的 shell。
public protocol ShellRunner {
    /// 交給 `/bin/sh -c`。非零 exit code 要 throw——安靜失敗的命令與
    /// 「這個鍵沒反應」外觀相同。
    func run(_ command: String) throws
}

public enum ShellRunnerError: Error, Equatable, Sendable {
    case commandFailed(command: String, status: Int32)
}
