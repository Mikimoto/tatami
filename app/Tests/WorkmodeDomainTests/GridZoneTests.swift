import Testing
import WorkmodeDomain

private func document(_ zones: JSONValue) -> JSONValue {
    .object([JSONMember(key: "bindings", value: .array([])),
             JSONMember(key: "zones", value: zones)])
}

@Test func aZoneRoundTripsWithItsShortcut() {
    let json = document(.array([.object([
        JSONMember(key: "name", value: .string("左半")),
        JSONMember(key: "grid", value: .string("2:2:0:0:1:1")),
        JSONMember(key: "key", value: .string("ctrl + alt - left")),
    ])]))
    let (parsed, problems) = HotkeyBindings.read(json)
    #expect(problems.isEmpty)
    #expect(parsed.zones.count == 1)
    #expect(parsed.zones[0].name == "左半")
    #expect(parsed.zones[0].spec.columns == 2)
    #expect(parsed.zones[0].hotkey?.description == "ctrl + alt - left")
    let again = HotkeyBindings.read(HotkeyBindings.write(parsed)).document
    #expect(again.zones == parsed.zones)
}

/// **沒有快捷鍵的 zone 是合法的**——Lasso 的截圖裡就有沒掛徽章的格，
/// 而 `HotkeyBinding.hotkey` 是非 optional 的，所以 zone 不能塞進 `bindings`。
@Test func aZoneWithoutAShortcutIsFine() {
    let json = document(.array([.object([
        JSONMember(key: "name", value: .string("右上")),
        JSONMember(key: "grid", value: .string("2:2:1:0:1:1")),
    ])]))
    let (parsed, problems) = HotkeyBindings.read(json)
    #expect(problems.isEmpty)
    #expect(parsed.zones[0].hotkey == nil)
}

/// 壞掉的**單一條**逐條說出來再跳過，與綁定同一條慣例。
@Test func aMalformedZoneIsReportedAndSkipped() {
    let json = document(.array([
        .object([JSONMember(key: "name", value: .string("好的")),
                 JSONMember(key: "grid", value: .string("2:2:0:0:1:1"))]),
        .object([JSONMember(key: "name", value: .string("壞的")),
                 JSONMember(key: "grid", value: .string("左半"))]),
        .object([JSONMember(key: "grid", value: .string("2:2:0:0:1:1"))]),
    ]))
    let (parsed, problems) = HotkeyBindings.read(json)
    #expect(parsed.zones.count == 1)
    #expect(problems.count == 2)
}

/// 有快捷鍵的 zone 變成一條 `HotkeyBinding`，與既有 45 條**走同一條註冊路徑**
/// ——不另開一套，於是 `isSafeAsGlobalShortcut` 與撞鍵檢查照樣套用在 zone 上。
@Test func zonesWithKeysBecomeRegistrableBindings() {
    let json = document(.array([
        .object([JSONMember(key: "name", value: .string("有鍵")),
                 JSONMember(key: "grid", value: .string("2:2:0:0:1:1")),
                 JSONMember(key: "key", value: .string("ctrl + alt - left"))]),
        .object([JSONMember(key: "name", value: .string("沒鍵")),
                 JSONMember(key: "grid", value: .string("2:2:1:0:1:1"))]),
    ]))
    let parsed = HotkeyBindings.read(json).document
    #expect(parsed.registrableBindings.count == 1)
    #expect(parsed.registrableBindings[0].action
        == .placeGrid(rows: 2, columns: 2, originX: 0, originY: 0, width: 1, height: 1))
}

/// 一個裸的按鍵（沒有 cmd／ctrl／alt）在 zone 上也要被拒——
/// `RegisterEventHotKey` 註冊的組合會被系統吃掉，一個裸的 `w` 會讓每個 app 裡
/// 的每一次打字都變成搬視窗，而且無法從那個 app 裡救回來。
///
/// **鍵寫成 `- w` 而不是 `w`**：`Hotkey.parse` 切在第一個 `-`，沒有 `-` 就
/// 直接回 nil，於是 `w` 會被守衛的**前**半（認不得按鍵）擋掉而永遠走不到
/// `isSafeAsGlobalShortcut`——實測拿掉那個條件五條全綠，這條測試等於沒有牙齒。
/// `- w` 是空修飾鍵集合的規範形式（`Hotkey.description` 印的就是它）。
@Test func anUnsafeShortcutOnAZoneIsRejected() {
    let json = document(.array([.object([
        JSONMember(key: "name", value: .string("危險")),
        JSONMember(key: "grid", value: .string("2:2:0:0:1:1")),
        JSONMember(key: "key", value: .string("- w")),
    ])]))
    let (parsed, problems) = HotkeyBindings.read(json)
    #expect(parsed.zones.isEmpty)
    #expect(problems.count == 1)
}

/// **面板只碰 `zones`。** 它與編輯器的「快捷鍵」頁寫同一個檔，動到別的鍵就是
/// 互相蓋掉對方，而症狀是「我剛設的快捷鍵不見了」。
///
/// 這一條驗的是那個純函式：整份文件進、只有 zones 不同的整份文件出。
@Test func addingAZoneLeavesEverythingElseAlone() {
    let before = HotkeyDocument(bindings: HotkeyBindings.defaults,
                                floatApps: HotkeyBindings.defaultFloatApps,
                                grids: ["x": GridConfig(columns: 4, rows: 4, gap: 20)])
    // 前提檢查：這三個欄位本來就不是空的，否則「沒被動到」是恆真的。
    #expect(!before.bindings.isEmpty)
    #expect(!before.floatApps.isEmpty)
    #expect(!before.grids.isEmpty)

    let after = before.addingZone(named: "區塊 1",
                                  spec: .init(rows: 2, columns: 2, originX: 0, originY: 0,
                                              width: 1, height: 1))
    #expect(after.bindings == before.bindings)
    #expect(after.floatApps == before.floatApps)
    #expect(after.grids == before.grids)
    #expect(after.mouse == before.mouse)
    #expect(after.zones.count == 1)
    #expect(after.zones[0].name == "區塊 1")
}

/// 名字自動挑第一個沒用過的數字。固定或留空的話按第二次就撞名——與
/// 「新增規則」挑 `新規則 N` 同一條。
@Test func theAutomaticNameSkipsTheOnesAlreadyTaken() {
    var document = HotkeyDocument(bindings: [], floatApps: [])
    #expect(document.nextZoneName == "區塊 1")
    document.zones = [
        GridZone(name: "區塊 1", spec: .init(rows: 1, columns: 1, originX: 0, originY: 0,
                                           width: 1, height: 1)),
        GridZone(name: "區塊 3", spec: .init(rows: 1, columns: 1, originX: 0, originY: 0,
                                           width: 1, height: 1)),
    ]
    // 挑的是**沒用過的**那個，不是「最大加一」——3 已經有人用了但 2 沒有。
    #expect(document.nextZoneName == "區塊 2")
}

@Test func removingAZoneLeavesEverythingElseAlone() {
    var before = HotkeyDocument(bindings: HotkeyBindings.defaults, floatApps: [])
    before.zones = [
        GridZone(name: "留下", spec: .init(rows: 1, columns: 1, originX: 0, originY: 0,
                                         width: 1, height: 1)),
        GridZone(name: "刪掉", spec: .init(rows: 1, columns: 1, originX: 0, originY: 0,
                                         width: 1, height: 1)),
    ]
    let after = before.removingZone(named: "刪掉")
    #expect(after.zones.map(\.name) == ["留下"])
    #expect(after.bindings == before.bindings)
}
