import Foundation
import Testing
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain

/// 收下事件的那一端。Adapters 這個 target 沒有 `FakeReporter`（那個住在 CoreTests），
/// 而這裡只需要「說了哪幾句」。
private final class Collector: Reporter, @unchecked Sendable {
    var events: [WorkmodeEvent] = []
    func report(_ event: WorkmodeEvent) {
        events.append(event)
    }
}

private func temporaryPath() -> String {
    NSTemporaryDirectory() + "tatami-hotkeys-\(UUID().uuidString).json"
}

/// 檔案不存在是**常態**（第一次跑，或剛從 skhd 搬過來），不是錯誤。
/// 把它當錯誤會讓所有快捷鍵在第一次啟動時失效。
@Test func aMissingFileFallsBackToTheBuiltInBindingsQuietly() {
    let collector = Collector()
    let document = HotkeyFile.load(from: temporaryPath(), files: FileManagerStore(),
                                   reporter: collector)
    #expect(document == HotkeyDocument.defaults)
    #expect(collector.events.isEmpty)
}

@Test func theDefaultsSurviveARealRoundTripThroughDisk() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try HotkeyFile.save(HotkeyDocument.defaults, to: path, files: FileManagerStore())
    let collector = Collector()
    let read = HotkeyFile.load(from: path, files: FileManagerStore(), reporter: collector)
    #expect(read == HotkeyDocument.defaults)
    #expect(collector.events.isEmpty)
    // 寫出來的要是人看得懂也改得動的 JSON，不是一行。
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("\"key\": \"ctrl + alt + cmd - w\""))
    #expect(text.contains("\"action\": \"apply:visible\""))
}

/// 壞掉的一條被說出來、其餘照收；整份壞掉才退回預設。
/// 一個錯字關掉全部快捷鍵比較糟。
@Test func abadEntryIsNamedAndTheRestStillLoad() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try """
    { "bindings": [
      { "key": "cmd - w", "action": "nope" },
      { "key": "cmd - e", "action": "balance" }
    ] }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    let collector = Collector()
    let document = HotkeyFile.load(from: path, files: FileManagerStore(), reporter: collector)
    #expect(document.bindings.count == 1)
    #expect(document.bindings.first?.action == .balanceSpace)
    #expect(collector.events.count == 1)
    guard case let .hotkey(.hotkeyBindingRejected(detail)) = collector.events[0]
    else { Issue.record("事件形狀不對"); return }
    #expect(detail.contains("hotkeys.json"))
    #expect(detail.contains("nope"))
}

@Test func abrokenFileFallsBackToTheDefaultsAndSaysSo() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
    let collector = Collector()
    let document = HotkeyFile.load(from: path, files: FileManagerStore(), reporter: collector)
    #expect(document == HotkeyDocument.defaults)
    #expect(collector.events.count == 1)
}

/// 同一組鍵綁兩次時後面那條會安靜地不生效（`RegisterEventHotKey` 拒絕重複註冊），
/// 所以載入時就要說出來。
@Test func aDuplicateCombinationIsReportedAtLoadTime() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try """
    { "bindings": [
      { "key": "cmd - w", "action": "close" },
      { "key": "cmd - w", "action": "balance" }
    ] }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    let collector = Collector()
    _ = HotkeyFile.load(from: path, files: FileManagerStore(), reporter: collector)
    #expect(collector.events == [.hotkeyConflict(key: "cmd - w")])
}

/// zone 的鍵與某條綁定撞了也要說出來——**要送去註冊的是綁定加 zone 那一份**
/// （`HotkeyDocument.registrableBindings`），而後來那個會被 `RegisterEventHotKey`
/// 安靜地拒絕。只算 `bindings` 的話這裡一個字都不印。
@Test func aZoneKeyClashingWithABindingIsReportedToo() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try """
    { "bindings": [ { "key": "cmd - w", "action": "close" } ],
      "zones": [ { "name": "左半", "grid": "2:2:0:0:1:1", "key": "cmd - w" } ] }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    let collector = Collector()
    _ = HotkeyFile.load(from: path, files: FileManagerStore(), reporter: collector)
    #expect(collector.events == [.hotkeyConflict(key: "cmd - w")])
}

/// 對照組。少了它，一支「一律回報撞鍵」的實作與正確的實作分不出來——而這一份
/// fixture 與上一條只差 zone 的那個鍵，所以它同時證明了上一條真的是**那個鍵**
/// 造成的，不是「有 zone 就報」。
@Test func aZoneKeyOfItsOwnIsNotAConflict() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try """
    { "bindings": [ { "key": "cmd - w", "action": "close" } ],
      "zones": [ { "name": "左半", "grid": "2:2:0:0:1:1", "key": "ctrl + alt + cmd - 9" } ] }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    let collector = Collector()
    let document = HotkeyFile.load(from: path, files: FileManagerStore(), reporter: collector)
    // 前提檢查：那個 zone 真的被讀進來了（`key` 解不開的話它整個被跳過，
    // 於是「沒有撞鍵」就變成恆真而這條測試什麼都沒驗到）。
    #expect(document.zones.count == 1)
    #expect(document.zones[0].hotkey != nil)
    #expect(collector.events.isEmpty)
}

// MARK: - `readable`：這一份能不能拿來覆寫

// 四種狀態各一條。前兩種是**對照組**：少了它們，一支「一律回 nil」的實作與正確的
// 實作分不出來，而「一律回 nil」的症狀是第一次跑的人永遠存不出第一份設定
// ——那是另一個 bug，不是比較安全的選擇。

/// 檔案不存在＝第一次跑，或剛從 skhd 搬過來。存得出去。
@Test func amissingFileIsSafeToOverwriteWithTheDefaults() {
    #expect(HotkeyFile.readable(from: temporaryPath(), files: FileManagerStore())
        == HotkeyDocument.defaults)
}

/// 空檔與不存在同一條：`touch` 出來的、或上一次寫到一半的，都不是使用者的設定。
@Test func anEmptyFileIsSafeToOverwriteToo() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try "".write(toFile: path, atomically: true, encoding: .utf8)
    #expect(HotkeyFile.readable(from: path, files: FileManagerStore())
        == HotkeyDocument.defaults)
}

/// 少一個逗號。這一份重讀出來是內建的預設值，覆寫回去就是刪掉他的設定。
@Test func afileThatDoesNotParseIsNotSafeToOverwrite() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try "{ \"bindings\": [ }".write(toFile: path, atomically: true, encoding: .utf8)
    #expect(HotkeyFile.readable(from: path, files: FileManagerStore()) == nil)
}

/// **2026-09-09 的資料遺失缺陷。** 合法的 JSON、打錯的鍵名（`bindings` → `binding`）
/// ——`HotkeyBindings.read` 對它回一份空文件加一句 problem 而不是失敗，於是這一份
/// 看起來「讀得到」而覆寫回去會把 45 條綁定與 29 個 float app 一次刪光，零訊息。
/// 最外層是陣列走的是同一條，所以一起釘在這裡。
@Test func afileThatParsesButIsNotAHotkeyDocumentIsNotSafeToOverwrite() throws {
    let files = FileManagerStore()
    for text in ["{ \"binding\": [ { \"key\": \"cmd - w\", \"action\": \"balance\" } ] }",
                 "[ { \"key\": \"cmd - w\", \"action\": \"balance\" } ]",
                 "{ \"bindings\": { \"key\": \"cmd - w\" } }"]
    {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(HotkeyFile.readable(from: path, files: files) == nil, "\(text) 不該可覆寫")
    }
}

/// 壞掉的**一條**不算「看不懂」：那是少一條，不是整份不是設定。分不開的話
/// 一個打錯的動作名就會讓這一頁再也存不了檔。
@Test func asingleBadEntryStillLeavesTheFileSafeToOverwrite() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    try """
    { "bindings": [ { "key": "cmd - w", "action": "nope" } ], "float": ["Finder"] }
    """.write(toFile: path, atomically: true, encoding: .utf8)
    let document = HotkeyFile.readable(from: path, files: FileManagerStore())
    #expect(document?.bindings.isEmpty == true)
    // 齒在這裡：讀得到就要**讀到那份檔的內容**，不是內建的預設值——回 defaults
    // 的話那個 float 清單會在下一次 ⌘S 被 29 個內建名字取代。
    #expect(document?.floatApps == ["Finder"])
}

// MARK: - 位置庫的寫檔：面板是 hotkeys.json 的第二個 writer

/// 面板記一個 zone 之後，**別的鍵一個都不能少**。
///
/// 這一條走的是真的磁碟：`readable` → Domain 的 `addingZone` → `save` → 再讀一次
/// ——`GridCommand.writeZones` 做的就是這三步（那一層零測試，所以驗在這裡）。
/// 它防的是使用者最痛的那個症狀：「我在編輯器設好的快捷鍵，用了一次面板就不見了」。
@Test func recordingAZoneThroughDiskKeepsEverythingElse() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let files = FileManagerStore()
    try """
    {"bindings":[{"key":"ctrl + alt + cmd - 8","action":"grid:2:2:0:0:1:1"}],
     "float":["Sample App"],"grids":{"ABC":{"columns":3,"rows":3,"gap":12}}}
    """.write(toFile: path, atomically: true, encoding: .utf8)

    let before = try #require(HotkeyFile.readable(from: path, files: files))
    // 前提檢查：這三個欄位本來就不是空的，否則「沒被動到」是恆真的。
    #expect(before.bindings.count == 1)
    #expect(before.floatApps == ["Sample App"])
    #expect(before.grids.count == 1)

    let spec = WindowGeometry.GridSpec(rows: 2, columns: 2, originX: 0, originY: 0,
                                       width: 1, height: 1)
    try HotkeyFile.save(before.addingZone(named: before.nextZoneName, spec: spec),
                        to: path, files: files)

    let after = try #require(HotkeyFile.readable(from: path, files: files))
    #expect(after.bindings == before.bindings)
    #expect(after.floatApps == before.floatApps)
    #expect(after.grids == before.grids)
    #expect(after.mouse == before.mouse)
    #expect(after.zones.map(\.name) == ["區塊 1"])
}

/// 刪掉之後同樣只少那一個。
@Test func deletingAZoneThroughDiskKeepsEverythingElse() throws {
    let path = temporaryPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let files = FileManagerStore()
    try """
    {"bindings":[{"key":"ctrl + alt + cmd - 8","action":"grid:2:2:0:0:1:1"}],
     "float":["Sample App"],
     "zones":[{"name":"留下","grid":"2:2:0:0:1:1"},{"name":"刪掉","grid":"2:2:1:0:1:1"}]}
    """.write(toFile: path, atomically: true, encoding: .utf8)

    let before = try #require(HotkeyFile.readable(from: path, files: files))
    #expect(before.zones.count == 2)
    try HotkeyFile.save(before.removingZone(named: "刪掉"), to: path, files: files)

    let after = try #require(HotkeyFile.readable(from: path, files: files))
    #expect(after.zones.map(\.name) == ["留下"])
    #expect(after.bindings == before.bindings)
    #expect(after.floatApps == before.floatApps)
}
