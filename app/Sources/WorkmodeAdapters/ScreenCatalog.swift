import AppKit
import CoreGraphics

/// 螢幕的**名稱**——yabai 給不出這個。
///
/// 實測（2026-08-21）：`yabai -m query --displays` 的欄位是
/// `id / uuid / index / label / frame / has-focus / spaces`，而 `label` 三台都是
/// 空字串——那是 `yabai -m display --label` 讓使用者自己貼的標籤，不是硬體名稱。
/// 真名只有 macOS 知道，而 `CGDisplayCreateUUIDFromDisplayID` 產出的 UUID 與 yabai
/// 的**逐字相同**（3/3 對得上：`55555555-…`／`22222222-…`／`11111111-…`），
/// 尺寸也相同（1728×1117／2560×1440／3008×1692），所以兩邊接得起來。
///
/// **不是一個 port。** `WorkmodeCore/Ports.swift` 的那些協定是 **Core** 需要的東西，
/// 而 Core 從來不問螢幕叫什麼——只有編輯器要。所以它是 Adapters 裡一個獨立的查詢，
/// 由 `WorkmodeCLI` 呼叫，走既有的 `connectedDisplays` 閉包交進編輯器。
public enum ScreenCatalog {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let width: Int
        public let height: Int

        public init(name: String, width: Int, height: Int) {
            self.name = name
            self.width = width
            self.height = height
        }
    }

    /// UUID → 名稱與尺寸。查不到 UUID 的螢幕不出現在字典裡（合併那側會讓它
    /// 以「沒有名稱」的形態留在清單上，見 `DisplayChoice.merge`）。
    ///
    /// 實測在**非 GUI 的 CLI 行程**裡也查得到（`workmode __smoke screens` 從終端機
    /// 跑，三台都出來），所以不需要先 `NSApplication.shared` 起一個 app。
    @MainActor public static func byUUID() -> [String: Entry] {
        var catalog: [String: Entry] = [:]
        for screen in NSScreen.screens {
            guard let uuid = uuid(of: screen) else { continue }
            catalog[uuid] = Entry(name: screen.localizedName,
                                  width: Int(screen.frame.width),
                                  height: Int(screen.frame.height))
        }
        return catalog
    }

    /// `NSScreenNumber` → `CGDirectDisplayID` → CFUUID → 字串。
    /// 那三段任何一段拿不到就回 nil，呼叫端把那台螢幕整個跳過——寫一個假的鍵
    /// 進字典會讓它去對上別台螢幕的 uuid。
    @MainActor private static func uuid(of screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? CGDirectDisplayID,
              let reference = CGDisplayCreateUUIDFromDisplayID(number)
        else { return nil }
        return CFUUIDCreateString(nil, reference.takeRetainedValue()) as String
    }
}
