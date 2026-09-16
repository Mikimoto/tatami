import Testing
@testable import WorkmodeDomain

// `obj` 用 `JSONFixtures.swift` 那份共用的（逐字相同）。計畫裡本檔自帶一份 `private`
// 版本，但同一個 module 裡再宣告一次就是 invalid redeclaration——那份 fixture 當初
// 正是為了不要有第八份副本才收成一份的。

/// 既有的鍵**原地**更新——這是整個編輯器的地基。換位置的話，一個 ratio 的改動
/// 會變成整檔 diff，而 `DocumentTransparencyTests` 正是在守這件事。
@Test func settingAnExistingKeyKeepsItsPosition() throws {
    let before = obj([("z", .number("1")), ("a", .number("2"))])
    let after = try JSONPath.set(before, [.key("z")], to: .number("9"))
    #expect(after == obj([("z", .number("9")), ("a", .number("2"))]))
}

/// 新的鍵接在尾端，不排序。
@Test func settingANewKeyAppendsIt() throws {
    let before = obj([("z", .number("1"))])
    let after = try JSONPath.set(before, [.key("a")], to: .number("2"))
    #expect(after == obj([("z", .number("1")), ("a", .number("2"))]))
}

/// 陣列索引：這是 `ProfileMerge.setPath` 沒有而編輯器需要的那一半。
@Test func settingAnArrayElementKeepsTheRest() throws {
    let before = obj([("w", .array([.number("1"), .number("2"), .number("3")]))])
    let after = try JSONPath.set(before, [.key("w"), .index(1)], to: .string("x"))
    #expect(after == obj([("w", .array([.number("1"), .string("x"), .number("3")]))]))
}

/// 數字字面值原樣帶過：`set` 不得碰到路徑以外的任何位元組。
@Test func untouchedNumberLiteralsSurvive() throws {
    let before = obj([("keep", .number("2.50")), ("edit", .number("1"))])
    let after = try JSONPath.set(before, [.key("edit")], to: .number("7"))
    guard case let .object(members) = after else { Issue.record("不是物件"); return }
    #expect(members[0].value == .number("2.50"))
}

@Test func deletingRemovesTheKeyAndKeepsOrder() throws {
    let before = obj([("a", .number("1")), ("b", .number("2")), ("c", .number("3"))])
    #expect(try JSONPath.delete(before, [.key("b")])
        == obj([("a", .number("1")), ("c", .number("3"))]))
}

@Test func deletingAnArrayElementShiftsTheRest() throws {
    let before = obj([("w", .array([.string("a"), .string("b"), .string("c")]))])
    #expect(try JSONPath.delete(before, [.key("w"), .index(0)])
        == obj([("w", .array([.string("b"), .string("c")]))]))
}

@Test func insertingPutsItAtTheGivenIndex() throws {
    let before = obj([("w", .array([.string("a"), .string("c")]))])
    #expect(try JSONPath.insert(before, [.key("w")], at: 1, .string("b"))
        == obj([("w", .array([.string("a"), .string("b"), .string("c")]))]))
}

/// 搬動是「拿掉再插入」，而**順序有意義**（前面的規則先認領視窗）。
@Test func movingReordersWithoutLosingAnything() throws {
    let before = obj([("w", .array([.string("a"), .string("b"), .string("c")]))])
    #expect(try JSONPath.move(before, [.key("w")], from: 2, to: 0)
        == obj([("w", .array([.string("c"), .string("a"), .string("b")]))]))
}

/// 中繼節點型別不對就報錯，**不要靜默建東西**：編輯器的路徑一律來自它剛剛
/// 投影出來的東西，走不通就是投影與文件不同步，那是 bug 不是要補的洞。
@Test func aWrongShapeAlongTheWayThrows() {
    let before = obj([("w", .string("not an array"))])
    #expect(throws: (any Error).self) {
        try JSONPath.set(before, [.key("w"), .index(0)], to: .null)
    }
}

/// 越界不接受。`set` 只改既有元素，長度要變就用 insert／delete。
@Test func anOutOfRangeIndexThrows() {
    let before = obj([("w", .array([.string("a")]))])
    #expect(throws: (any Error).self) {
        try JSONPath.set(before, [.key("w"), .index(5)], to: .null)
    }
}

/// `move` 的 `to` 越界要 throw 而不是夾到邊界。夾的話「搬到第 99 位」會靜默變成
/// 「搬到最後」，呼叫端卻以為自己指定的位置生效了——而規則的順序決定誰先認領視窗。
///
/// 這條是補的：Task 1 的突變清單原本就有這一項，實作時跑出來**全綠**（那時唯一的
/// move 測試 `from:2, to:0` 兩端都在範圍內），實作者照實回報沒有硬湊，缺口由這裡收。
@Test func movingToAnOutOfRangeSlotThrows() {
    let before = obj([("w", .array([.string("a"), .string("b")]))])
    // 移除 from 之後只剩 1 個元素，所以 to:99 越界。
    #expect(throws: (any Error).self) {
        try JSONPath.move(before, [.key("w")], from: 0, to: 99)
    }
    #expect(throws: (any Error).self) {
        try JSONPath.move(before, [.key("w")], from: 0, to: -1)
    }
}

/// 改名**不動位置**。這一條的鑑別力在 `profiles` 的鍵序：`開發` 原本排在
/// `會議` 前面，改名後仍要在前面。「delete 舊的 ＋ set 新的」的實作會把它接到
/// 尾端（`set` 對新鍵是接尾端），於是順序變成 `會議, 主力` —— 這條紅。
@Test func renamingAKeyKeepsItsPosition() throws {
    let before = obj([("開發", .string("A")), ("會議", .string("B"))])
    let after = try JSONPath.renameKey(before, [], from: "開發", to: "主力")
    #expect(after == obj([("主力", .string("A")), ("會議", .string("B"))]))
}

@Test func renamingReachesDownAPath() throws {
    let before = obj([("office", obj([("profiles", obj([("舊", num("1"))]))]))])
    let after = try JSONPath.renameKey(before, [.key("office"), .key("profiles")],
                                       from: "舊", to: "新")
    #expect(JSONPath.get(after, [.key("office"), .key("profiles"), .key("新")]) == num("1"))
}

/// 三種拒絕。都 throw 而不是靜默 no-op：呼叫端（Model）會先擋，走到這裡代表
/// 投影與文件不同步。
@Test func renamingRefusesTheThreeBadCases() {
    let object = obj([("有", .null)])
    #expect(throws: (any Error).self) {
        try JSONPath.renameKey(object, [], from: "沒有", to: "新")
    }
    let two = obj([("甲", .null), ("乙", .null)])
    #expect(throws: (any Error).self) {
        try JSONPath.renameKey(two, [], from: "甲", to: "乙")
    }
    #expect(throws: (any Error).self) {
        try JSONPath.renameKey(.array([]), [], from: "甲", to: "乙")
    }
}

/// 改成同一個名字是 no-op 而不是「to 已存在」的錯誤。
@Test func renamingToTheSameNameIsANoOp() throws {
    let object = obj([("甲", num("1"))])
    #expect(try JSONPath.renameKey(object, [], from: "甲", to: "甲") == object)
}
