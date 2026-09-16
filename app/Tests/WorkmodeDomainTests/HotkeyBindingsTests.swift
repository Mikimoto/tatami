import Testing
@testable import WorkmodeDomain

@Test func theDefaultsSurviveAWriteAndRead() {
    let (document, problems) = HotkeyBindings.read(HotkeyBindings.write(HotkeyDocument.defaults))
    #expect(problems.isEmpty)
    #expect(document == HotkeyDocument.defaults)
}

@Test func aDisabledBindingKeepsItsFlagAndTheOthersStayClean() throws {
    let rows = try [
        HotkeyBinding(hotkey: #require(Hotkey.parse("cmd - w")), action: .closeWindow, isEnabled: false),
        HotkeyBinding(hotkey: #require(Hotkey.parse("cmd - e")), action: .balanceSpace),
    ]
    let json = HotkeyBindings.write(HotkeyDocument(bindings: rows, floatApps: []))
    // `enabled` 只有 false 才寫出來，所以第二條只有兩個欄位。
    guard case let .object(top) = json, case let .array(items) = top[0].value,
          case let .object(first) = items[0], case let .object(second) = items[1]
    else { Issue.record("形狀不對"); return }
    #expect(first.map(\.key) == ["key", "action", "enabled"])
    #expect(second.map(\.key) == ["key", "action"])
    #expect(HotkeyBindings.read(json).document.bindings == rows)
}

/// 壞掉的那一條被報出來，其餘照收——整份拒絕會讓一個錯字關掉全部快捷鍵。
@Test func abadRowIsReportedAndSkippedWithoutTakingTheOthersDown() {
    let json = JSONValue.object([JSONMember(key: "bindings", value: .array([
        .object([JSONMember(key: "key", value: .string("cmd - w")),
                 JSONMember(key: "action", value: .string("nope"))]),
        .object([JSONMember(key: "key", value: .string("hyper - w")),
                 JSONMember(key: "action", value: .string("close"))]),
        .object([JSONMember(key: "key", value: .string("cmd - e")),
                 JSONMember(key: "action", value: .string("close"))]),
    ]))])
    let (document, problems) = HotkeyBindings.read(json)
    #expect(document.bindings.count == 1)
    #expect(document.bindings.first?.hotkey.key == "e")
    #expect(problems.count == 2)
    #expect(problems[0].contains("nope"))
    #expect(problems[1].contains("hyper - w"))
}

@Test func missingBindingsArrayIsAProblemNotAnEmptyList() {
    let (document, problems) = HotkeyBindings.read(.object([]))
    #expect(document.bindings.isEmpty)
    #expect(problems.count == 1)
}

/// 重複的組合裡，後面那條會安靜地不生效（`RegisterEventHotKey` 拒絕重複註冊），
/// 所以 UI 要說得出來。關掉的那條不算——它不會去搶註冊。
@Test func conflictsOnlyCountTheEnabledOnes() throws {
    let key = try #require(Hotkey.parse("cmd - w"))
    let rows = [
        HotkeyBinding(hotkey: key, action: .closeWindow),
        HotkeyBinding(hotkey: key, action: .balanceSpace, isEnabled: false),
    ]
    #expect(HotkeyBindings.conflicts(in: rows).isEmpty)
    #expect(HotkeyBindings.conflicts(in: [rows[0], rows[0]]) == [key])
    #expect(HotkeyBindings.conflicts(in: HotkeyBindings.defaults).isEmpty)
}

/// `float` 清單要能寫出去再讀回來，而**空清單不寫那個鍵**（預設值寫進檔案
/// 只是雜訊）。非字串的元素跳過，不把整份清單弄掉。
@Test func theFloatListRoundTripsAndSkipsGarbage() {
    let document = HotkeyDocument(bindings: [], floatApps: ["Finder", "訊息"])
    let json = HotkeyBindings.write(document)
    #expect(HotkeyBindings.read(json).document.floatApps == ["Finder", "訊息"])
    guard case let .object(top) = HotkeyBindings.write(HotkeyDocument(bindings: [],
                                                                      floatApps: []))
    else { Issue.record("形狀不對"); return }
    #expect(!top.contains { $0.key == "float" })

    let mixed = JSONValue.object([
        JSONMember(key: "bindings", value: .array([])),
        JSONMember(key: "float", value: .array([.string("Finder"), .number("7"), .null,
                                                .string("Another App")])),
    ])
    #expect(HotkeyBindings.read(mixed).document.floatApps == ["Finder", "Another App"])
}

/// `mouse` 整個鍵不存在＝用內建值（`fn`／move／resize），不是關掉它。
@Test func amissingMouseObjectMeansTheDefaults() {
    let (document, problems) = HotkeyBindings.read(.object([
        JSONMember(key: "bindings", value: .array([])),
    ]))
    #expect(document.mouse == MouseSettings.defaults)
    #expect(problems.isEmpty)
}

/// **打錯的按鍵動作是「關掉那顆」，不是靜默退回預設。**
/// 「那顆沒反應」查得出來（他打的字還在檔案裡），「悄悄變成 move」查不出來。
@Test func anUnknownButtonActionTurnsThatButtonOff() {
    let json = JSONValue.object([
        JSONMember(key: "bindings", value: .array([])),
        JSONMember(key: "mouse", value: .object([
            JSONMember(key: "modifier", value: .string("cmd")),
            JSONMember(key: "button1", value: .string("mvoe")),
            JSONMember(key: "button2", value: .string("off")),
        ])),
    ])
    let (document, problems) = HotkeyBindings.read(json)
    #expect(document.mouse.modifier == .cmd)
    #expect(document.mouse.button1 == nil)
    #expect(document.mouse.button2 == nil)
    #expect(document.mouse.isDisabled)
    #expect(problems.isEmpty)
}

/// modifier 打錯則**整個物件**退回預設並報一句：沒有修飾鍵可用的話兩顆都動不了，
/// 那不是「關掉一顆」那種可以安靜處理的事。
@Test func anUnknownModifierFallsBackAndSaysSo() {
    let json = JSONValue.object([
        JSONMember(key: "bindings", value: .array([])),
        JSONMember(key: "mouse", value: .object([
            JSONMember(key: "modifier", value: .string("hyper")),
        ])),
    ])
    let (document, problems) = HotkeyBindings.read(json)
    #expect(document.mouse == MouseSettings.defaults)
    #expect(problems.count == 1)
    #expect(problems[0].contains("hyper"))
}

/// 與預設相同時不寫那個物件（檔案是給人看的）；不同時寫，而**關掉的那顆寫成
/// `"off"`**——省略它會在下一次讀的時候變回預設值。
@Test func theMouseObjectRoundTripsAndOmitsTheDefaults() {
    let plain = HotkeyBindings.write(HotkeyDocument(bindings: [], floatApps: []))
    guard case let .object(top) = plain else { Issue.record("形狀不對"); return }
    #expect(!top.contains { $0.key == "mouse" })

    let custom = MouseSettings(modifier: .alt, button1: .resize, button2: nil)
    let json = HotkeyBindings.write(HotkeyDocument(bindings: [], floatApps: [],
                                                   mouse: custom))
    #expect("\(json)".contains("off"))
    #expect(HotkeyBindings.read(json).document.mouse == custom)
}
