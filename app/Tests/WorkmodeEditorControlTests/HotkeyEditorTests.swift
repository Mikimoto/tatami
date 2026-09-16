import Testing
import WorkmodeCore
import WorkmodeDomain
@testable import WorkmodeEditorControl
import WorkmodeWire

// 假的 store 在 `ControlStoreFake.swift`（`Store`）。它**寫入時補一個結尾換行**，
// 與 `FileManagerStore` 一致——這個編輯器的外部變更閘門正是靠那個換行才驗得到。

private func editor(_ store: Store, path: String = "/hotkeys.json") -> HotkeyEditor {
    HotkeyEditor(files: store, path: path, parse: JSONParser.parse, format: JSONWriter.format)
}

/// 檔案不存在是**常態**（第一次跑，或剛從 skhd 搬過來）。給預設值並標 dirty，
/// 使用者按一次 ⌘S 就落成檔案——不標 dirty 的話 ⌘S 是灰的，他得先改一條再改回去。
@Test func amissingFileLoadsTheDefaultsAlreadyDirty() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    #expect(hotkeys.bindings == HotkeyBindings.defaults)
    #expect(hotkeys.isDirty)
    #expect(hotkeys.loadFailure == nil)
    #expect(hotkeys.canSave)
}

/// 檔案在但看不懂就**什麼都不給**。給預設值會讓 ⌘S 覆蓋掉一份使用者可能
/// 只是打錯一個逗號的檔。
@Test func anUnparsableFileBlocksSavingInsteadOfOfferingDefaults() {
    let hotkeys = editor(Store(files: ["/hotkeys.json": "{ nope"]))
    hotkeys.load()
    #expect(hotkeys.bindings.isEmpty)
    #expect(hotkeys.canSave == false)
    #expect(hotkeys.save() != .written)
}

@Test func savingTwiceInARowIsUnchangedNotAnExternalChange() {
    let store = Store(files: [:])
    let hotkeys = editor(store)
    hotkeys.load()
    #expect(hotkeys.save() == .written)
    // 這一條在守結尾換行：`FileStore` 補一個而 `JSONWriter.format` 不補，
    // 所以 `loadedText` 記的必須是磁碟上那份。記成沒有換行的版本時，
    // 第二次存檔會被誤判成 `.blockedByExternalChange`。
    #expect(hotkeys.save() == .unchanged)
    #expect(store.writes.count == 1)
}

@Test func aFileChangedUnderneathUsIsRefusedRatherThanOverwritten() {
    let store = Store(files: [:])
    let hotkeys = editor(store)
    hotkeys.load()
    #expect(hotkeys.save() == .written)
    hotkeys.remove(at: 0)
    store.files["/hotkeys.json"] = "{ \"bindings\": [] }\n"
    #expect(hotkeys.save() == .blockedByExternalChange)
    #expect(store.writes.count == 1)
}

@Test func whatWasWrittenLoadsBackAsTheSameBindings() {
    let store = Store(files: [:])
    let first = editor(store)
    first.load()
    first.setAction("balance", at: 0)
    #expect(first.save() == .written)

    let second = editor(store)
    second.load()
    #expect(second.bindings == first.bindings)
    #expect(second.isDirty == false)
}

/// 沒有生效的編輯不算一步：越界的索引、解不開的動作、與原值相同的設定
/// 都不該把檔案標成 dirty。
@Test func editsThatChangeNothingDoNotDirtyTheFile() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    #expect(hotkeys.save() == .written)
    #expect(hotkeys.isDirty == false)

    hotkeys.setAction("nope", at: 0)
    hotkeys.setAction(hotkeys.bindings[0].action.text, at: 0)
    hotkeys.setEnabled(true, at: 0)
    hotkeys.setHotkey(hotkeys.bindings[0].hotkey, at: 0)
    hotkeys.remove(at: 999)
    hotkeys.setAction("close", at: 999)
    #expect(hotkeys.isDirty == false)

    hotkeys.setEnabled(false, at: 0)
    #expect(hotkeys.isDirty)
    #expect(hotkeys.bindings[0].isEnabled == false)
}

/// 新增的那一條**不能搶走使用者正在用的鍵**，所以它用一個一定不會撞的預留組合。
@Test func aNewBindingLandsOnAReservedCombinationNotACommonOne() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    let before = hotkeys.bindings.count
    hotkeys.add()
    #expect(hotkeys.bindings.count == before + 1)
    #expect(hotkeys.conflicts.isEmpty)
    // 動作預設是最無害的那個：只換焦點，不搬視窗。
    #expect(hotkeys.bindings.last?.action == .focusWindow(.west))
}

@Test func aDuplicateCombinationShowsUpInConflicts() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    let first = hotkeys.bindings[0].hotkey
    hotkeys.setHotkey(first, at: 1)
    #expect(hotkeys.conflicts == [first])
    // 關掉之後就不算——關掉的那條不會去搶註冊。
    hotkeys.setEnabled(false, at: 1)
    #expect(hotkeys.conflicts.isEmpty)
}

/// zone 的鍵也算。**撞掉的那一半就在這一頁上**：註冊時先來的贏，所以與 zone 撞鍵的
/// 那一條綁定是這一列會安靜地不生效，而 UI 拿 `conflicts` 把它標紅。zone 不在這一頁
/// 編（它從 `loadedDocument` 帶過來），所以只算 `bindings` 的話那一列永遠不會紅。
@Test func aZoneKeyClashingWithABindingShowsUpInConflicts() {
    let store = Store(files: ["/hotkeys.json": """
    { "bindings": [ { "key": "cmd - w", "action": "close" } ],
      "zones": [ { "name": "左半", "grid": "2:2:0:0:1:1", "key": "cmd - w" } ] }
    """])
    let hotkeys = editor(store)
    hotkeys.load()
    #expect(hotkeys.conflicts == [Hotkey(key: "w", modifiers: [.cmd])])
}

/// 對照組：同一份設定，只把 zone 的鍵換掉。少了它，一支「有 zone 就回非空」的實作
/// 與正確的實作分不出來。
@Test func aZoneKeyThatClashesWithNothingLeavesConflictsEmpty() {
    let store = Store(files: ["/hotkeys.json": """
    { "bindings": [ { "key": "cmd - w", "action": "close" } ],
      "zones": [ { "name": "左半", "grid": "2:2:0:0:1:1", "key": "ctrl + alt + cmd - 9" } ] }
    """])
    let hotkeys = editor(store)
    hotkeys.load()
    // 前提檢查：那條綁定與那個 zone 都真的讀進來了。兩者任一被跳過的話
    // 「沒有撞鍵」就是恆真的。
    #expect(hotkeys.bindings.count == 1)
    #expect(hotkeys.problems.isEmpty)
    #expect(hotkeys.conflicts.isEmpty)
}

@Test func restoringTheDefaultsIsOneUndoableStep() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    #expect(hotkeys.save() == .written)
    hotkeys.remove(at: 0)
    hotkeys.restoreDefaults()
    #expect(hotkeys.bindings == HotkeyBindings.defaults)
    #expect(hotkeys.isDirty)
    // 內容繞了一圈回到磁碟上那份，所以存檔是 `.unchanged` 而不是 `.written`
    // ——而它照樣清掉 dirty（與 `YabaircEditor` 同一條）。
    #expect(hotkeys.save() == .unchanged)
    #expect(hotkeys.isDirty == false)
    // 已經是預設值時再按一次不算一步。
    hotkeys.restoreDefaults()
    #expect(hotkeys.isDirty == false)
}

/// **手加的 float 清單不能在 ⌘S 時無聲消失。** 編輯器寫回的是 `write` 的輸出，
/// read/write 少收哪個欄位，那個欄位就會在存檔那一刻不見——這條就是在守那件事。
@Test func aHandWrittenFloatListSurvivesAnUnrelatedEditAndSave() {
    let store = Store(files: ["/hotkeys.json": """
    { "bindings": [ { "key": "cmd - e", "action": "balance" } ],
      "float": ["Finder", "訊息"] }
    """])
    let hotkeys = editor(store)
    hotkeys.load()
    #expect(hotkeys.floatApps == ["Finder", "訊息"])
    hotkeys.setAction("close", at: 0)
    #expect(hotkeys.save() == .written)
    let onDisk = store.files["/hotkeys.json"] ?? ""
    #expect(onDisk.contains("Finder"))
    #expect(onDisk.contains("訊息"))
}

/// 清單的三個編輯動作：空字串與重複都不收（不算一步），刪除照索引。
@Test func floatListEditsRejectBlanksAndDuplicates() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    #expect(hotkeys.save() == .written)
    hotkeys.addFloatApp("  ")
    hotkeys.addFloatApp("Finder") // 預設清單已經有
    #expect(hotkeys.isDirty == false)
    hotkeys.addFloatApp(" Xcode ")
    #expect(hotkeys.floatApps.last == "Xcode")
    #expect(hotkeys.isDirty)
    let count = hotkeys.floatApps.count
    hotkeys.removeFloatApp(at: 999)
    #expect(hotkeys.floatApps.count == count)
    hotkeys.removeFloatApp(at: count - 1)
    #expect(!hotkeys.floatApps.contains("Xcode"))
}

/// 還原預設連 float 清單一起還原。
@Test func restoringDefaultsAlsoRestoresTheFloatList() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    hotkeys.removeFloatApp(at: 0)
    hotkeys.restoreDefaults()
    #expect(hotkeys.floatApps == HotkeyDocument.defaults.floatApps)
}

/// 滑鼠設定與綁定同一份檔案、同一個 dirty、同一個 ⌘S——**存檔不能把它弄掉**
/// （與 float 清單同一條：read/write 少收哪個欄位，那個欄位就在 ⌘S 那一刻消失）。
@Test func theMouseSettingsSurviveASaveAndReload() {
    let store = Store(files: [:])
    let hotkeys = editor(store)
    hotkeys.load()
    #expect(hotkeys.mouse == MouseSettings.defaults)
    hotkeys.setMouse(MouseSettings(modifier: .cmd, button1: .resize, button2: nil))
    #expect(hotkeys.isDirty)
    #expect(hotkeys.save() == .written)

    let reopened = editor(store)
    reopened.load()
    #expect(reopened.mouse == MouseSettings(modifier: .cmd, button1: .resize, button2: nil))
}

@Test func settingTheSameMouseValueIsNotAStep() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    #expect(hotkeys.save() == .written)
    hotkeys.setMouse(MouseSettings.defaults)
    #expect(hotkeys.isDirty == false)
}

@Test func restoringDefaultsAlsoRestoresTheMouseSettings() {
    let hotkeys = editor(Store(files: [:]))
    hotkeys.load()
    hotkeys.setMouse(MouseSettings(modifier: .shift, button1: nil, button2: nil))
    hotkeys.restoreDefaults()
    #expect(hotkeys.mouse == MouseSettings.defaults)
}

/// 這一頁沒在編的鍵**要活過 ⌘S**。
///
/// 2026-09-09 實測到的資料遺失：`save()` 原本拿 `bindings`／`floatApps`／`mouse`
/// **重組**一份新的 `HotkeyDocument`，於是使用者手寫的 `grids` 區塊在按下 ⌘S
/// 的那一刻無聲消失——而 `HotkeyDocument` 自己的 doc 就在警告這個形狀
/// （「read/write 少收哪個欄位，那個欄位就會在使用者按 ⌘S 的那一刻無聲消失」）。
///
/// 鑑別力在**存完之後重讀那個檔**：只斷言 `save() == .written` 的話，
/// 刪掉整個 `grids` 也會過。
@Test func savingKeepsTheKeysThisPageDoesNotEdit() throws {
    let onDisk = """
    {
      "bindings": [],
      "grids": {
        "AAAA": { "columns": 4, "rows": 4, "gap": 20 }
      }
    }
    """
    let store = Store(files: ["/hotkeys.json": onDisk])
    let hotkeys = editor(store)
    hotkeys.load()
    // 改一條這一頁擁有的東西，讓它 dirty 而且內容真的變了。
    hotkeys.addFloatApp("Finder")
    #expect(hotkeys.save() == .written)

    let written = try #require((try? store.read(atPath: "/hotkeys.json")) ?? nil)
    let reread = try HotkeyBindings.read(JSONParser.parse(written)).document
    #expect(reread.grids["AAAA"] == GridConfig(columns: 4, rows: 4, gap: 20))
    #expect(reread.floatApps == ["Finder"])
    // 對照組：這一頁**有**在編的東西照樣寫得出去，所以上面那條不是恆真的。
    #expect(reread.bindings.isEmpty)
}

/// **parse 得過、但不是一份 hotkeys 設定**，與「少打一個逗號」走同一條路。
///
/// 2026-09-09 實測到的資料遺失：`bindings` 打成 `binding` 時 `HotkeyBindings.read`
/// 回的是一份**空文件加一句 problem** 而不是失敗，於是 `canSave` 為真、`save()`
/// 回 `.written`，而寫出去的是一份空設定——下面那個 `float` 清單與打錯的那一塊
/// 一起從檔案上消失。
@Test func aFileThatParsesButIsNotAHotkeysDocumentBlocksSaving() {
    let store = Store(files: ["/hotkeys.json": """
    { "binding": [ { "key": "cmd - e", "action": "balance" } ],
      "float": ["Sample App"] }
    """])
    let hotkeys = editor(store)
    hotkeys.load()
    #expect(hotkeys.bindings.isEmpty)
    #expect(hotkeys.floatApps.isEmpty)
    #expect(hotkeys.canSave == false)
    hotkeys.addFloatApp("Probe")
    #expect(hotkeys.save() != .written)
    // 鑑別力在這兩條：`save()` 回別的值而檔案照樣被覆寫過的話，上面那條仍然會過。
    #expect(store.writes.isEmpty)
    #expect(store.files["/hotkeys.json"]?.contains("Sample App") == true)
}

/// 對照組：壞掉的是**某一條**綁定而不是整份文件。這一頁的慣例是逐條說出來再跳過，
/// 所以 ⌘S 照樣按得下去。
///
/// 少了這條，上面那個守衛換成「有 problem 就一律擋」也會過——而那會讓一個錯字
/// 關掉整頁，正是既有那條慣例在防的事。
@Test func oneBrokenBindingStillLeavesTheFileSavable() {
    let store = Store(files: ["/hotkeys.json": """
    { "bindings": [ { "key": "cmd - e", "action": "balance" },
                    { "action": "close" } ],
      "float": ["Sample App"] }
    """])
    let hotkeys = editor(store)
    hotkeys.load()
    #expect(hotkeys.bindings.count == 1)
    #expect(hotkeys.problems.count == 1)
    #expect(hotkeys.loadFailure == nil)
    #expect(hotkeys.canSave)
    hotkeys.addFloatApp("Probe")
    #expect(hotkeys.save() == .written)
    #expect(store.files["/hotkeys.json"]?.contains("Probe") == true)
}
