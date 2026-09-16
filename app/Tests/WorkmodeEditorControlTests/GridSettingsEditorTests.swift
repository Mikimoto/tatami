import Testing
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
@testable import WorkmodeEditorControl
import WorkmodeWire

// 假的 store 在 `ControlStoreFake.swift`（`Store`）。

// **`load:` 走產品那一支**（`HotkeyFile.readable`），不是這裡抄一份。
// 抄過一份，而它的代價實測得出來：把產品那支改成一律回 `defaults`——正是這一頁
// 要防的危害——整套測試零 issue，因為這裡跑的是副本。餵一個壞掉的檔（不是一個
// 裸的 nil）仍然是對的，那才看得出 `canSave` 在守什麼；換掉的只是「誰來判斷」。
private func editor(_ store: Store, path: String = "/hotkeys.json") -> GridSettingsEditor {
    GridSettingsEditor(
        load: { HotkeyFile.readable(from: path, files: store) },
        store: { try store.writeAtomically(JSONWriter.format(HotkeyBindings.write($0)),
                                           toPath: path) },
        connected: { [(uuid: "AAAA", name: "內建")] }
    )
}

/// 使用者手改 `hotkeys.json` 掉了一個逗號。`save()` 是「重讀整份、只換 `grids`」，
/// 而那一份重讀出來會是 `HotkeyDocument.defaults`——寫下去等於用內建的 45 條綁定
/// 與 29 個 float app 蓋掉他的檔，靜默。所以這一頁不准存。
@Test func aGridPageWillNotSaveOverAFileItCannotRead() {
    let store = Store(files: ["/hotkeys.json": "{ \"bindings\": [ }"])
    let page = editor(store)
    page.loadOnce()

    #expect(page.canSave == false)
    #expect(page.loadFailure != nil)
    // 齒在這裡：光看 `canSave` 的話，一支「回 .failed 但還是寫下去」的 save 也會過。
    #expect(page.save() != .written)
    #expect(store.writes.isEmpty)
    // 螢幕清單仍然要載入：那一頁得說得出它是在對哪台螢幕講話。
    #expect(page.screens.count == 1)
}

/// 對照組。**少了它，「一律擋」與正確的實作分不出來**——而「一律擋」的症狀是
/// 第一次跑（那個檔本來就不存在）永遠存不出第一份設定。
@Test func aGridPageStillSavesWhenTheFileIsNotThereYet() throws {
    let store = Store(files: [:])
    let page = editor(store)
    page.loadOnce()

    #expect(page.canSave)
    page.set(GridConfig(columns: 3, rows: 2, gap: 12), forDisplay: "AAAA")
    #expect(page.isDirty)
    #expect(page.save() == .written)
    #expect(page.isDirty == false)

    // 讀回磁碟上那一份，不是信 `.written`：`grids` 沒寫進去的話那個回傳值一樣是
    // `.written`（`HotkeyEditorTests` 的同一條記過這件事）。
    let text = try #require(try store.read(atPath: "/hotkeys.json"))
    let reread = try HotkeyBindings.read(JSONParser.parse(text)).document
    #expect(reread.grids["AAAA"] == GridConfig(columns: 3, rows: 2, gap: 12))
    // 另一半的對照：這一頁沒在編的欄位要原樣留著，不是被清成空的。
    #expect(reread.bindings.isEmpty == false)
}

/// **第四種狀態，端到端。** 合法的 JSON，`bindings` 打成 `binding`——`HotkeyBindings.read`
/// 對它回一份空文件加一句 problem 而不是失敗，於是這一頁曾經 `canSave == true`、
/// `save()` 回 `.written`，而寫出去的檔不再有那條 `cmd - w`。
/// 這一條與 `HotkeyFileTests` 那條分工不同：那邊釘的是判斷本身，這邊釘的是
/// 「這一頁真的沒有寫檔」——判斷回對了但 `save()` 照寫的話只有這一條會紅。
@Test func aGridPageWillNotSaveOverAFileWhoseKeysAreMisspelled() {
    let store = Store(files: [
        "/hotkeys.json": "{ \"binding\": [ { \"key\": \"cmd - w\", \"action\": \"balance\" } ] }",
    ])
    let page = editor(store)
    page.loadOnce()

    #expect(page.canSave == false)
    #expect(page.save() != .written)
    #expect(store.writes.isEmpty)
    // 那句話不能**只**講「不是合法的 JSON」——這一份是合法的 JSON，照那樣講會叫
    // 使用者去找一個不存在的語法錯。所以它要點名另一種成因。
    #expect(page.loadFailure?.contains("bindings") == true)
}

// MARK: - 位置庫

/// 一份**每個欄位都非空**的檔：兩條綁定、一個 float app、一組非預設的 mouse、
/// 一台螢幕的 grids、三個 zone（第二個帶快捷鍵）。
///
/// 每個欄位都非空是刻意的：`save()` 那條測試要證明「這一頁沒動到別人的欄位」，
/// 而拿一份本來就空的檔去驗，那件事是**恆真的**。
private let fullFile = """
{
  "bindings": [
    { "key": "ctrl + alt + cmd - w", "action": "balance" },
    { "key": "alt + cmd - home", "action": "grid:2:2:0:0:1:1" }
  ],
  "float": ["訊息"],
  "mouse": { "modifier": "ctrl", "button1": "move", "button2": "resize" },
  "grids": { "AAAA": { "columns": 8, "rows": 5, "gap": 4 } },
  "zones": [
    { "name": "左半", "grid": "2:2:0:0:1:1" },
    { "name": "右半", "grid": "2:2:1:0:1:1", "key": "alt + cmd - end" },
    { "name": "整片", "grid": "1:1:0:0:1:1" }
  ]
}
"""

private func loadedPage() -> GridSettingsEditor {
    let page = editor(Store(files: ["/hotkeys.json": fullFile]))
    page.loadOnce()
    return page
}

@Test func aZoneCanBeRenamed() {
    let page = loadedPage()
    #expect(page.renameRejection(at: 0, to: "左邊那半") == nil)
    page.renameZone(at: 0, to: "左邊那半")

    #expect(page.zones.map(\.name) == ["左邊那半", "右半", "整片"])
    #expect(page.isDirty)
    // 改名不該碰到那個 zone 的其他欄位。
    #expect(page.zones[0].gridText == "2:2:0:0:1:1")
}

/// 撞名要擋，理由是硬的：`removingZone(named:)` 用**名字**比對，兩個同名會一次
/// 刪掉兩個。齒在第二個 `#expect`——只看拒絕訊息的話，一支「回訊息但還是改下去」
/// 的實作也會過。
@Test func aZoneWillNotTakeANameThatIsAlreadyUsed() {
    let page = loadedPage()
    let refusal = page.renameRejection(at: 0, to: "整片")
    #expect(refusal != nil)

    page.renameZone(at: 0, to: "整片")
    #expect(page.zones.map(\.name) == ["左半", "右半", "整片"])
    #expect(page.isDirty == false)
}

/// 改成自己的名字不算撞名（`LayoutName.rejection` 的 `existing` 逐字同一條）。
/// **這是撞名那條的對照組**：少了它，一支「只要名字已經存在就拒絕」的實作也會過，
/// 而那種實作讓使用者連把游標點進去再點出來都會被罵。
@Test func renamingAZoneToItsOwnNameIsNotAClash() {
    let page = loadedPage()
    #expect(page.renameRejection(at: 0, to: "左半") == nil)
}

@Test func aZoneWillNotTakeAnEmptyName() {
    let page = loadedPage()
    #expect(page.renameRejection(at: 0, to: "") != nil)
    page.renameZone(at: 0, to: "")
    #expect(page.zones.map(\.name) == ["左半", "右半", "整片"])
    #expect(page.isDirty == false)
}

/// 只有空白的名字與空的一樣——縮圖牆上那一格看不出是什麼。
///
/// **全形空白 U+3000 用碼位組出來，不要直接打**：它在原始碼裡與一般空白肉眼
/// 分不出來，而這條測試釘的正好就是那個差別（`Character.isWhitespace` 認得它，
/// 一支手寫的「只修掉 ASCII 空白」的 trim 不認得）。
@Test func aZoneNameOfNothingButSpacesIsEmpty() throws {
    let page = loadedPage()
    let fullWidth = try String(#require(UnicodeScalar(0x3000)))
    #expect(page.renameRejection(at: 0, to: " \(fullWidth)\t") != nil)
}

/// 前後的空白修掉。改名成「 左半 」在檔案裡與「左半」是兩個不同的名字，而畫面上
/// 一模一樣——收下它就是替刪除埋一個「刪不掉」的地雷。
@Test func aZoneNameLosesTheSpaceAroundIt() {
    let page = loadedPage()
    page.renameZone(at: 2, to: "  整片畫布  ")
    #expect(page.zones[2].name == "整片畫布")
}

/// 守衛與動作綁在一起（先例 `insertingAgreesWithCanInsertRule`）。名單裡放一個
/// **既有的名字**與一個空的，那兩項就是這條測試存在的理由。
@Test func renamingAgreesWithTheRenameRejection() {
    let names = ["左邊那半", "整片", "", "   ", "右半", "還可以的名字"]
    for name in names {
        let page = loadedPage()
        let before = page.zones
        let allowed = page.renameRejection(at: 0, to: name) == nil
        page.renameZone(at: 0, to: name)
        #expect((page.zones != before) == allowed,
                "「\(name)」：守衛說 \(allowed)，動作做的是另一件事")
    }
}

@Test func aZoneCanTakeASafeHotkey() {
    let page = loadedPage()
    let hotkey = Hotkey(key: "1", modifiers: [.ctrl, .alt, .cmd])
    #expect(page.hotkeyRejection(hotkey) == nil)
    page.setHotkey(hotkey, forZoneAt: 0)

    #expect(page.zones[0].hotkey == hotkey)
    #expect(page.isDirty)
}

/// 一個裸的 `w` 會讓每個 app 裡的每一次打字都變成排視窗，而且無法從那個 app 裡
/// 救回來。判準走 Domain 那一支（`isSafeAsGlobalShortcut`），這裡釘的是
/// 「這一頁真的沒有收下它」。
@Test func aZoneWillNotTakeABareKey() {
    let page = loadedPage()
    let bare = Hotkey(key: "w", modifiers: [.shift])
    #expect(page.hotkeyRejection(bare) != nil)

    page.setHotkey(bare, forZoneAt: 0)
    #expect(page.zones[0].hotkey == nil)
    #expect(page.isDirty == false)
}

/// 守衛與動作綁在一起，與 `renamingAgreesWithTheRenameRejection` 同一條。
@Test func settingAHotkeyAgreesWithTheHotkeyRejection() {
    let keys = [Hotkey(key: "w", modifiers: []),
                Hotkey(key: "w", modifiers: [.shift]),
                Hotkey(key: "w", modifiers: [.cmd]),
                Hotkey(key: "w", modifiers: [.ctrl, .alt])]
    for key in keys {
        let page = loadedPage()
        let allowed = page.hotkeyRejection(key) == nil
        page.setHotkey(key, forZoneAt: 0)
        #expect((page.zones[0].hotkey == key) == allowed,
                "\(key.description)：守衛說 \(allowed)，動作做的是另一件事")
    }
}

/// **撞鍵不擋，改用警告**——與「快捷鍵」那一頁逐字相同的處置（見
/// `hotkeyRejection` 的 doc）。所以這條要驗兩件事：收下了，而且說得出它撞了。
///
/// 撞的對象是**既有的一條綁定**（`alt + cmd - home`），不是另一個 zone：只看
/// `zones` 的實作在後者也會過，而那正是 `registrableBindings` 要防的漏洞。
@Test func aZoneHotkeyThatClashesIsTakenButReported() {
    let page = loadedPage()
    let taken = Hotkey(key: "home", modifiers: [.alt, .cmd])
    #expect(page.hotkeyRejection(taken) == nil)
    page.setHotkey(taken, forZoneAt: 0)

    #expect(page.zones[0].hotkey == taken)
    #expect(page.conflicts.contains(taken))
}

/// 對照組：沒撞的那一組不該出現在清單裡。少了它，一支「一律回全部按鍵」的
/// `conflicts` 也會過。
@Test func aZoneHotkeyThatClashesWithNobodyIsNotReported() {
    let page = loadedPage()
    let fresh = Hotkey(key: "9", modifiers: [.ctrl, .alt, .cmd])
    page.setHotkey(fresh, forZoneAt: 0)
    #expect(page.conflicts.contains(fresh) == false)
}

/// 沒有快捷鍵的 zone 是常態，所以清得掉這件事一定要做得到。
@Test func aZoneHotkeyCanBeCleared() {
    let page = loadedPage()
    #expect(page.zones[1].hotkey != nil)
    page.clearHotkey(forZoneAt: 1)

    #expect(page.zones[1].hotkey == nil)
    #expect(page.isDirty)
    // 清掉快捷鍵不是刪掉這個 zone。
    #expect(page.zones.map(\.name) == ["左半", "右半", "整片"])
}

@Test func deletingAZoneTakesOnlyThatOne() {
    let page = loadedPage()
    page.removeZone(named: "右半")

    #expect(page.zones.map(\.name) == ["左半", "整片"])
    #expect(page.isDirty)
}

/// 刪一個不存在的名字什麼都不做，**而且不標 dirty**——標了的話 ⌘S 會亮起來，
/// 而使用者沒有改過任何東西。
@Test func deletingAZoneThatIsNotThereChangesNothing() {
    let page = loadedPage()
    page.removeZone(named: "沒有這個")

    #expect(page.zones.count == 3)
    #expect(page.isDirty == false)
}

/// **這一頁存檔不准動到別人的欄位。** 走真的檔案（讀回磁碟上那一份再解析），
/// 不是信 `.written`——`zones` 沒寫進去的話那個回傳值一樣是 `.written`。
///
/// 前面那四個 `#expect` 是**前提檢查**：拿一份本來就空的檔去驗，「沒被動到」
/// 是恆真的。
@Test func savingTheGridPageKeepsEverythingItDoesNotOwn() throws {
    let store = Store(files: ["/hotkeys.json": fullFile])
    let page = editor(store)
    page.loadOnce()

    // 前提：這四個欄位一開始就不是空的／不是預設值。
    #expect(page.zones.count == 3)
    let before = try HotkeyBindings.read(JSONParser.parse(fullFile)).document
    #expect(before.bindings.count == 2)
    #expect(before.floatApps == ["訊息"])
    #expect(before.mouse != MouseSettings.defaults)
    #expect(before.grids["AAAA"] == GridConfig(columns: 8, rows: 5, gap: 4))

    page.renameZone(at: 0, to: "左邊那半")
    page.setHotkey(Hotkey(key: "1", modifiers: [.ctrl, .alt, .cmd]), forZoneAt: 2)
    page.removeZone(named: "右半")
    #expect(page.save() == .written)

    let text = try #require(try store.read(atPath: "/hotkeys.json"))
    let after = try HotkeyBindings.read(JSONParser.parse(text)).document
    // 這一頁擁有的：改對了。
    #expect(after.zones.map(\.name) == ["左邊那半", "整片"])
    #expect(after.zones[1].hotkey == Hotkey(key: "1", modifiers: [.ctrl, .alt, .cmd]))
    // 這一頁不擁有的：一個都沒少。
    #expect(after.bindings == before.bindings)
    #expect(after.floatApps == before.floatApps)
    #expect(after.mouse == before.mouse)
    #expect(after.grids == before.grids)
}

/// `grids` 與 `zones` 同一個 ⌘S。分開存的話「格數存了、位置庫沒存」這種狀態就會
/// 存在，而畫面上兩者長得一樣。
@Test func theGridPageSavesBothOfTheFieldsItOwns() throws {
    let store = Store(files: ["/hotkeys.json": fullFile])
    let page = editor(store)
    page.loadOnce()

    page.set(GridConfig(columns: 3, rows: 3, gap: 12), forDisplay: "AAAA")
    page.renameZone(at: 0, to: "左邊那半")
    #expect(page.save() == .written)

    let text = try #require(try store.read(atPath: "/hotkeys.json"))
    let after = try HotkeyBindings.read(JSONParser.parse(text)).document
    #expect(after.grids["AAAA"] == GridConfig(columns: 3, rows: 3, gap: 12))
    #expect(after.zones.map(\.name) == ["左邊那半", "右半", "整片"])
}
