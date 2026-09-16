import Testing
@testable import WorkmodeDomain

/// 每一個預設綁定的動作都要能印出來再解回同一個值。
///
/// 用 `defaults` 當語料而不是自己挑幾個 case：那份清單就是會被寫進使用者檔案的
/// 東西，而漏掉的那個 case 正好是最不常想到的那個。
@Test func everyDefaultActionRoundTrips() {
    for binding in HotkeyBindings.defaults {
        #expect(HotkeyAction.parse(binding.action.text) == binding.action, "\(binding.action.text)")
    }
    // 45 = 14 排版 + 10 位置 + 16 跨 space／螢幕 + 5 其餘。數字寫死是為了讓
    // 「compactMap 靜默丟掉一條」看得見——那條的症狀只是「這個鍵沒反應」。
    //
    // **2026-09-15 從 46 掉到 45**：`cmd - f3` 指向使用者自己的
    // `~/.config/tatami/scripts/taggleShowHideDesktop.sh`，而全新安裝沒有那個檔——
    // 一個按了靜默失敗的預設綁定，與「這個功能壞了」在畫面上分不出來。
    #expect(HotkeyBindings.defaults.count == 45)
}

@Test func aShellCommandKeepsItsColons() {
    let action = HotkeyAction.parse("shell:open https://example.com:8080/x")
    #expect(action == .runShell("open https://example.com:8080/x"))
    #expect(action?.text == "shell:open https://example.com:8080/x")
    #expect(HotkeyAction.parse("shell:") == nil)
}

@Test func garbageActionsAreRejected() {
    // 容錯會讓一條打錯的規則變成「這個鍵沒反應」，那是最難查的失效。
    for text in ["focus", "focus:sideways", "grid:2:2:0:0:1", "grid:0:2:0:0:1:1",
                 "resize:20", "resize:x:0", "space:", "rotate:sideways", "nope"]
    {
        #expect(HotkeyAction.parse(text) == nil, "\(text)")
    }
}

@Test func gridArgumentsKeepYabaisOrder() {
    // `2:2:0:1:1:1` 在 yabai 是左下角（start-x 0、start-y 1），順序一換就是右上角。
    #expect(HotkeyAction.parse("grid:2:2:0:1:1:1")
        == .placeGrid(rows: 2, columns: 2, originX: 0, originY: 1, width: 1, height: 1))
}

/// 使用者那 45 條裡不能有任何一條在畫面上顯示成一串生字串。
///
/// 「有名字」的判準是**它不等於自己的原始字串**——只檢查 `label` 非空的話，
/// 退回那條路也會過，而那正是要抓的東西。
@Test func everyDefaultActionHasARealName() {
    for binding in HotkeyBindings.defaults {
        let label = HotkeyCatalogue.label(for: binding.action)
        #expect(label != binding.action.text, "\(binding.action.text)")
        #expect(!label.isEmpty)
    }
}

/// 選單列的那些必須是解得開也印得回去的——它們直接被寫進 hotkeys.json。
@Test func everyCatalogueEntryRoundTripsAndIsNamed() {
    for group in HotkeyCatalogue.groups {
        for action in group.actions {
            #expect(HotkeyAction.parse(action.text) == action, "\(action.text)")
            #expect(HotkeyCatalogue.label(for: action) != action.text, "\(action.text)")
        }
    }
}
