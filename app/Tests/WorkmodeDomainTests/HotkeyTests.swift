import Foundation
import Testing
@testable import WorkmodeDomain

/// 這個 parser 唯一有牙齒的驗法：使用者退役前那份 `skhd/skhdrc` 的**全部 47 條**。
///
/// **凍成 `tests/skhdrc-retired-bindings.txt` 而不是讀 `skhd/skhdrc`**：那個檔
/// 2026-09-08 已經沒有任何生效的綁定了（全部搬進 tatami），繼續讀它的話這條
/// 測試會靜默退化成「掃到 0 條、全部通過」。凍結的那份是它退役當天的原文，
/// 用 `git show <retire commit>^:skhd/skhdrc | grep -E '^[a-z0-9 +]+-[^:]*:'` 取的。
///
/// 合成的 fixture 太規則——真檔案裡有 `0x2A` 這種十六進位鍵名、有
/// `shift + alt + cmd` 這種四段修飾鍵、有 `f3`、有數字鍵，還有一整批
/// `ctrl + cmd - 1..9`。少了它，「認得三種寫法」與「認得全部」分不出來。
@Test func parsesEverySkhdrcBindingThatWasRetired() throws {
    let path = repoRoot().appendingPathComponent("tests/skhdrc-retired-bindings.txt")
    let text = try String(contentsOf: path, encoding: .utf8)
    let lines = text.split(separator: "\n").map(String.init)
    let failures = lines.filter { Hotkey.parse($0) == nil }
    #expect(failures.isEmpty, "解不開：\(failures)")
    // 「掃到幾條」要正面確認：檔案被清空或路徑寫錯時，`failures.isEmpty`
    // 是恆真的，外觀與「全部都過」相同。
    #expect(lines.count == 47, "\(lines.count)")
}

@Test func theCanonicalFormRoundTrips() throws {
    // 亂序、別名、大寫，三種都要收斂到同一個規範形式。
    let hotkey = Hotkey.parse("CMD + Option + control - LEFT")
    #expect(hotkey?.description == "ctrl + alt + cmd - left")
    #expect(try Hotkey.parse(#require(hotkey?.description)) == hotkey)
}

@Test func anUnknownModifierIsRejectedRatherThanIgnored() {
    // 忽略它會安靜地註冊一組別的鍵——這是這條測試存在的理由。
    #expect(Hotkey.parse("hyper + cmd - w") == nil)
    #expect(Hotkey.parse("cmd - nosuchkey") == nil)
}

@Test func hexKeyNamesRoundTripThroughTheTable() {
    // skhdrc 真的有一條 `alt + cmd - 0x2A`。
    #expect(HotkeyKeys.code(for: "0x2a") == 42)
    #expect(HotkeyKeys.name(for: 42) == "\\")
    #expect(HotkeyKeys.name(for: 0x7F) == "0x7f")
    #expect(HotkeyKeys.code(for: "0x999") == nil)
}

/// `name(for:)` 走 `first(where:)`，而 Dictionary 的走訪順序不保證。
/// 只有在**沒有兩個名字對到同一個碼**時它才是確定的，所以那件事要斷言。
@Test func everyKeyNameMapsToADistinctCode() {
    let codes = HotkeyKeys.table.values
    #expect(Set(codes).count == codes.count)
}

@Test func carbonMasksAreOrIndependent() {
    let hotkey = Hotkey.parse("ctrl + alt + cmd - w")
    #expect(hotkey?.carbon?.code == 13)
    // 三個 mask 先 OR 進一個區域變數：`#expect` 的巨集會改寫運算式裡的
    // 二元運算子，把 `|` 直接寫在比較式裡會被展開成一個與原意不同的判斷
    // （兩邊都印 6400 卻回 false）。
    let expected: UInt32 = 0x0100 | 0x0800 | 0x1000
    #expect(hotkey?.carbon?.mask == expected)
}

/// 裸鍵與只加 shift 都不能當全域快捷鍵：`RegisterEventHotKey` 會吃掉那個事件，
/// 於是每個 app 裡的每一次打字都變成重排視窗，而且從那個 app 裡救不回來。
@Test func aGlobalShortcutNeedsARealModifier() {
    #expect(Hotkey.parse("- w")?.isSafeAsGlobalShortcut == false)
    #expect(Hotkey.parse("shift - w")?.isSafeAsGlobalShortcut == false)
    #expect(Hotkey.parse("cmd - w")?.isSafeAsGlobalShortcut == true)
    #expect(Hotkey.parse("ctrl - w")?.isSafeAsGlobalShortcut == true)
    #expect(Hotkey.parse("alt - w")?.isSafeAsGlobalShortcut == true)
    // 預設那 45 條一條都不能踩到這個。
    let unsafe = HotkeyBindings.defaults.filter { !$0.hotkey.isSafeAsGlobalShortcut }
    #expect(unsafe.isEmpty, "\(unsafe.map(\.hotkey.description))")
}

/// 退役的 47 條裡，**兩條**不在預設值裡，而兩條的理由不同：
///
/// - `ctrl + alt + cmd - r`（重啟 yabai 與 skhd 兩個服務，而那兩個服務本身正在退役）
///   **從來沒搬過**。
/// - `cmd - f3` 搬過來了，2026-09-15 又拿掉——它指向使用者自己的
///   `~/.config/tatami/scripts/taggleShowHideDesktop.sh`，而全新安裝沒有那個檔。
///
/// 清單寫死而不是寫「至多兩條」：這條在守「搬移完整」而不是「解析得了」，
/// 少搬一條的症狀是一個使用者按了很久的鍵從此沒反應，而沒有任何別的東西會發現。
@Test func onlyTheServiceRestartAndTheAuthorsScriptHaveNoNewHome() throws {
    let path = repoRoot().appendingPathComponent("tests/skhdrc-retired-bindings.txt")
    let retired = try String(contentsOf: path, encoding: .utf8)
        .split(separator: "\n").compactMap { Hotkey.parse(String($0)) }
    let moved = Set(HotkeyBindings.defaults.map(\.hotkey))
    let missing = retired.filter { !moved.contains($0) }
    #expect(missing.map(\.description) == ["cmd - f3", "ctrl + alt + cmd - r"])
}

/// `0x2a` 與 `\` 是同一顆鍵（keycode 42），所以它們必須是同一個 `Hotkey`——
/// 不然 `conflicts` 抓不到它們撞在一起，而第二次註冊會被系統安靜地拒絕。
/// 使用者退役前的 skhdrc 寫的就是 `alt + cmd - 0x2A`。
@Test func twoSpellingsOfTheSameKeyAreTheSameHotkey() {
    #expect(Hotkey.parse("alt + cmd - 0x2A") == Hotkey.parse("alt + cmd - \\"))
    #expect(Hotkey.parse("alt + cmd - 0x2A")?.description == "alt + cmd - \\")
    // 表裡沒有的原樣留著：那時 `carbon` 回 nil，呼叫端會說「認不得按鍵」。
    #expect(Hotkey(key: "NoSuchKey", modifiers: [.cmd]).key == "nosuchkey")
}

/// 預設的 float 清單必須與凍結副本 `tests/default-float-apps.txt` **逐字對帳**。
///
/// 少搬一個的症狀是那個 app 開始被 balance／rotate／gaps 排進版面，而沒有別的
/// 東西會發現——所以這裡比的是順序與內容都相同，不是集合。
///
/// **這份清單 2026-09-16 從 29 條縮成 13 條。** 原本它是退役前 `yabairc` 那 29 條
/// `manage=off` 的逐字副本，其中大半是市售第三方軟體，也就是一台特定機器的
/// 安裝清單。要查當初搬過來的是哪 29 個，看這個檔在 `7630907` 的版本。
@Test func theDefaultFloatListMatchesItsFrozenCopy() throws {
    let path = repoRoot().appendingPathComponent("tests/default-float-apps.txt")
    let frozen = try String(contentsOf: path, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(frozen.count == 13)
    #expect(HotkeyBindings.defaultFloatApps == frozen)
}
