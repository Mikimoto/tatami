import AppKit
import ApplicationServices

/// 「現在哪個視窗有焦點」。`grid` 要排的就是它。
///
/// 不走 `YabaiQuery`：那個 enum 的每個 case 對應 bash 裡一個實際存在的呼叫形式
/// （`Ports.swift` 的檔頭），而 bash 從來沒問過焦點——加一個 case 會逼
/// `YabaiProcessClient` 也實作它，而那條路在差分基準上。
///
/// **兩段式**：`NSWorkspace.frontmostApplication` 給最前面那個 app，AX 的
/// `kAXFocusedWindowAttribute` 給它焦點所在的視窗。少了第二段只知道是哪個 app；
/// 一個 app 開五個視窗時那不夠。
///
/// 螢幕鎖住時這裡會回 `noFocusedWindow` 而不是一個錯的 id：AX 那半整個是空的
/// （見 `WindowServerClient` 的 doc），而那是誠實的失敗。
public extension WindowServerClient {
    /// 焦點視窗的 id（十進位字串，與 `query` 回的 `id` 同一個形狀）。
    func focusedWindow() throws -> String {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw WindowServerFailure.noFocusedWindow
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &value
        ) == .success, let window = value else {
            throw WindowServerFailure.noFocusedWindow
        }
        // `as?` 對 AXUIElement 這個 CF 型別在 Swift 6 是條件轉換而不是強制解包，
        // 拿到別的型別（不該發生，但這是 CFTypeRef）時回 nil 而不是 crash。
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else {
            throw WindowServerFailure.noFocusedWindow
        }
        // swiftlint:disable:next force_cast
        let identifier = bridge.windowID(of: window as! AXUIElement)
        guard identifier != 0 else { throw WindowServerFailure.noFocusedWindow }
        return String(identifier)
    }
}
