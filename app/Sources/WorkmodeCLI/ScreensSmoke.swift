import Foundation
import WorkmodeAdapters

/// `tatami __smoke screens` 的實作：對**真的** `NSScreen` 跑一輪唯讀驗證。
///
/// `ScreenCatalog` 碰的是真實世界，fake 測得到合併規則（`DisplayChoiceTests`），
/// 測不到「NSScreen 真的接上了、名稱真的拿得到、尺寸真的是正的」。
///
/// 放在自己的檔而不是 `PortSmoke.swift`：它不是一個 port（Core 從來不問螢幕叫
/// 什麼），而 `main.swift` 只差幾行就撞到 `file_length` 400。
///
/// **2026-09-14 之前這個檔叫 `YabaiSmoke.swift`**，裡面還有 `__smoke yabai`
/// 與 `__smoke settings` 兩支。yabai 那天從這台機器移除之後兩支都永遠跑不起來，
/// 所以整個拆掉了——理由與代價見 `CLAUDE.md` 的「yabai 的不變式」那一節。
/// 這一支留下來是因為它一個字都不碰 yabai。
@MainActor func runScreensSmoke() -> Never {
    let catalog = ScreenCatalog.byUUID()
    guard !catalog.isEmpty else {
        print("FAIL 一台螢幕都查不到——NSScreen.screens 在這個行程裡是空的")
        exit(1)
    }
    var failures = 0
    for (uuid, entry) in catalog.sorted(by: { $0.key < $1.key }) {
        let bad = entry.name.isEmpty || entry.width <= 0 || entry.height <= 0
        failures += bad ? 1 : 0
        print("\(bad ? "FAIL" : "ok  ") \(uuid)：\(entry.name.debugDescription)"
            + " \(entry.width)×\(entry.height)")
    }
    print(failures == 0 ? "--- smoke passed（\(catalog.count) 台）---" : "--- \(failures) 項失敗 ---")
    exit(failures == 0 ? 0 : 1)
}
