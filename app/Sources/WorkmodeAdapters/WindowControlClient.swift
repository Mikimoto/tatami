import AppKit
import ApplicationServices
import WorkmodeCore

/// `WindowControl` 的實作，掛在既有的引擎上。
///
/// 不另開一個型別：`focusedWindow()` 已經是 `WindowServerClient` 的 extension
/// （`FocusedWindow.swift`），而 `focus` 與 `close` 要的是同一份 pid ↔ 視窗 id
/// 的對照與同一支 `axWindow`。分開會讓那張表被建兩次。
extension WindowServerClient: WindowControl {
    /// 把視窗抬到最前面，並讓它的 app 取得焦點。
    ///
    /// **兩件事都要做**。只 raise：視窗上來了但鍵盤還在原本那個 app，打字打到別處。
    /// 只 activate：焦點到了那個 app，但它自己選一個視窗（多半是最近用過的那個），
    /// 而不是我們指定的這個。
    public func focus(window: String) throws {
        let target = try axWindow(window)
        // 先 raise 再 activate：反過來的話 app 啟動時會把它自己挑的視窗帶到前面，
        // 我們的 raise 就被蓋掉了。
        _ = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString,
                                         kCFBooleanTrue)
        guard let id = CGWindowID(window), let info = self.window(id: id),
              let application = NSRunningApplication(processIdentifier: info.pid)
        else { return }
        application.activate()
    }

    /// 按它的關閉鈕。
    ///
    /// **不是 `kAXCloseAction`**（那個 action 不存在），也不是 kill 那個行程：
    /// 有未存檔案的 app 會跳自己的對話框，那是對的行為——skhdrc 那條走的是
    /// `yabai -m window --close`，它做的也是這件事。
    public func close(window: String) throws {
        let target = try axWindow(window)
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target.element, kAXCloseButtonAttribute as CFString,
                                            &button) == .success,
            let button, CFGetTypeID(button) == AXUIElementGetTypeID()
        else { throw WindowServerFailure.windowNotFound(window) }
        // swiftlint:disable:next force_cast
        _ = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }
}

/// `shell:` 那道逃生門。
///
/// `/bin/sh -c` 而不是自己切字：那個字串是使用者從 `skhdrc` 搬過來的，
/// 裡面有 `~`、`&&`、管線與引號，自己切等於寫半個 shell。信任層級與 `skhdrc`
/// 相同（那個檔本來就是使用者自己寫的 shell）。
public struct ShellCommandRunner: ShellRunner {
    public init() {}

    public func run(_ command: String) throws {
        let result = try runProcess(executable: "/bin/sh", arguments: ["-c", command],
                                    inheritStderr: true)
        guard result.status == 0 else {
            throw ShellRunnerError.commandFailed(command: command, status: result.status)
        }
    }
}
