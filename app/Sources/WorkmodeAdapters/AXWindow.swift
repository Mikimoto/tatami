import ApplicationServices
import Foundation
import WorkmodeDomain

/// 一個視窗的 AX 元素，以及對它的五個操作。
///
/// **`kAXWindowsAttribute` 列不出不可見 space 上的視窗**（2026-09-03 實測：Mail 在
/// space 8 的視窗回 0 個）。yabai 的 workaround（`window_manager.c`，attribution
/// decodism／alt-tab-macos#1324）：暴力搜 `element_id` 0…0x7fff 造 remote token，
/// role 是 `AXWindow` 且 `_AXUIElementGetWindow` 等於目標 id 就是它。實測第 43 個
/// 就中、17ms。token 是 20 bytes：pid@0、magic `0x636f636f`@8、element_id（8 bytes）@12。
struct AXWindow {
    // fileprivate 而不是 private：`Bridge` 的儲存屬性用得到它們，而那兩個是 fileprivate。
    fileprivate typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    fileprivate typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    /// 兩個私有符號一次載入。與 `SkyLight` 同一個態度：缺了就說名字。
    struct Bridge {
        fileprivate let getWindow: GetWindow
        fileprivate let create: CreateWithRemoteToken

        init() throws {
            let path = "/System/Library/Frameworks/ApplicationServices.framework"
                + "/Frameworks/HIServices.framework/HIServices"
            guard let handle = dlopen(path, RTLD_NOW) else { throw WindowServerFailure.symbolMissing("HIServices") }
            guard let get = dlsym(handle, "_AXUIElementGetWindow") else {
                throw WindowServerFailure.symbolMissing("_AXUIElementGetWindow")
            }
            guard let make = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else {
                throw WindowServerFailure.symbolMissing("_AXUIElementCreateWithRemoteToken")
            }
            getWindow = unsafeBitCast(get, to: GetWindow.self)
            create = unsafeBitCast(make, to: CreateWithRemoteToken.self)
        }
    }

    /// AX 一秒不回就放棄：一個卡住的 app 不該讓整輪套版停住。
    static let timeoutSeconds: Float = 1

    let element: AXUIElement
    private let bridge: Bridge

    /// 先走正規的 `kAXWindowsAttribute`（可見 space 上的視窗都在），找不到才暴力搜。
    static func find(pid: pid_t, id: CGWindowID, bridge: Bridge) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)
        var listed: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &listed) == .success,
           let windows = listed as? [AXUIElement]
        {
            for candidate in windows where bridge.windowID(of: candidate) == id {
                return AXWindow(element: candidate, bridge: bridge)
            }
        }
        return search(pid: pid, id: id, bridge: bridge)
    }

    /// 一個 app 的 `kAXWindowsAttribute` 一次問完，建成 id → 元素。
    ///
    /// `find` 是「一個視窗問一次」，而過濾整份清單時同一個 pid 會被問很多次；
    /// 一次建表之後每個 pid 只付一次 AX 往返（2026-09-03 實測：14 個候選、
    /// 8 個 pid，整批 **100ms**）。不在表裡**不代表**沒有元素——不可見 space 上的
    /// 視窗一律不在（見型別的 doc），那種要 `search`。
    static func windowsByID(pid: pid_t, bridge: Bridge) -> [CGWindowID: AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeoutSeconds)
        var listed: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &listed) == .success,
              let windows = listed as? [AXUIElement]
        else { return [:] }
        var out: [CGWindowID: AXWindow] = [:]
        for candidate in windows {
            let id = bridge.windowID(of: candidate)
            guard id != 0 else { continue }
            out[id] = AXWindow(element: candidate, bridge: bridge)
        }
        return out
    }

    /// remote token 的暴力搜。切出來是為了 `file_length` 之外的另一件事：
    /// 這一段是整個檔唯一會失敗得很安靜的地方（magic 錯了就一個 `AXWindow` 都找不到，
    /// 症狀與「這台機器沒有不可見 space 的視窗」完全相同），值得自己一個名字。
    static func search(pid: pid_t, id: CGWindowID, bridge: Bridge) -> AXWindow? {
        var token = [UInt8](repeating: 0, count: 0x14)
        withUnsafeBytes(of: UInt32(bitPattern: pid)) { token.replaceSubrange(0 ..< 4, with: $0) }
        withUnsafeBytes(of: UInt32(0x636F_636F)) { token.replaceSubrange(8 ..< 12, with: $0) }
        for elementID in UInt64(0) ..< 0x7FFF {
            withUnsafeBytes(of: elementID) { token.replaceSubrange(12 ..< 20, with: $0) }
            guard let candidate = bridge.create(Data(token) as CFData)?.takeRetainedValue() else { continue }
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == kAXWindowRole as String,
                  bridge.windowID(of: candidate) == id
            else { continue }
            AXUIElementSetMessagingTimeout(candidate, timeoutSeconds)
            return AXWindow(element: candidate, bridge: bridge)
        }
        return nil
    }

    /// 兩次 set（position、size）：AX 沒有一次設 frame 的屬性。
    ///
    /// **這一支只設一次，重試在 `WindowServerClient.setFrame`。** 位置先設時套用的
    /// 是視窗**當下的**尺寸，新位置配舊尺寸放不下就被拒絕——而
    /// `AXUIElementSetAttributeValue` 照樣回 `.success`，這一層看不出來。
    /// 在這裡連著跑第二輪**沒有用**（實測）：AX 設完要 85–115ms 畫面才追上，
    /// 背靠背的第二輪讀到的仍是舊尺寸。要重試就得等結果，而「等結果」那個迴圈
    /// 在上一層——所以它在那裡。
    func setFrame(_ frame: Rect) throws {
        var origin = CGPoint(x: frame.originX, y: frame.originY)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size)
        else { throw WindowServerFailure.unresponsive("\(windowID)") }
        for (attribute, value) in [(kAXPositionAttribute, position), (kAXSizeAttribute, extent)] {
            let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
            guard result == .success else { throw WindowServerFailure.unresponsive("\(windowID)") }
        }
    }

    var isMinimized: Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    func deminimize() {
        _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    var title: String? {
        string(kAXTitleAttribute)
    }

    /// `AXStandardWindow`／`AXDialog`／… 這一類。**這是「這是不是一個真視窗」唯一
    /// 可靠的訊號**——`role` 對面板與真視窗都是 `AXWindow`。判準寫在
    /// `WindowServerClient.managedSubroles`。
    var subrole: String? {
        string(kAXSubroleAttribute)
    }

    /// Safari／Chrome 的視窗把目前分頁的 URL 放在這裡。其他 app 多半沒有這個屬性。
    var document: String? {
        string(kAXDocumentAttribute)
    }

    var windowID: CGWindowID {
        bridge.windowID(of: element)
    }

    private func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// internal 而不是 private：`FocusedWindow.swift` 也要用 `windowID(of:)`。
extension AXWindow.Bridge {
    func windowID(of element: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success ? id : 0
    }
}
