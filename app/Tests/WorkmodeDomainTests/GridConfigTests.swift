import Testing
import WorkmodeDomain

private let builtin = "55555555-5555-4555-8555-555555555555"

@Test func anUnlistedDisplayGetsTheDefaults() {
    #expect(GridConfig.forDisplay("nobody", in: [:]) == GridConfig.defaults)
    #expect(GridConfig.defaults.columns == 6)
    #expect(GridConfig.defaults.rows == 4)
    #expect(GridConfig.defaults.gap == 8)
}

@Test func aListedDisplayGetsItsOwn() {
    let table = [builtin: GridConfig(columns: 4, rows: 4, gap: 20)]
    let found = GridConfig.forDisplay(builtin, in: table)
    #expect(found.columns == 4)
    #expect(found.gap == 20)
}

/// 格數夾回至少 1，與 `GridSelection`／`WindowGeometry.cell` 同一條——
/// 這個檔是人手改得動的，`"columns": 0` 打得出來，而 0 欄的格線畫不出東西。
@Test func zeroAndNegativeGridsAreClampedAtOne() {
    let table = ["x": GridConfig(columns: 0, rows: -3, gap: -5)]
    let found = GridConfig.forDisplay("x", in: table)
    #expect(found.columns == 1)
    #expect(found.rows == 1)
    // 負的間距會讓 inset 把矩形往外撐，而畫面上那是「視窗互相重疊」。
    #expect(found.gap == 0)
}

/// **空字串的 uuid 必須與「沒列到」同一條路。** 新增地點時 `main` 的 uuid 就是
/// 刻意留空的（`layout.json` 那邊 validate 只查鍵存不存在），而 `grids[""]`
/// 若配得到就會讓一台認不出來的螢幕吃到別人的設定。
@Test func anEmptyUuidNeverMatches() {
    #expect(GridConfig.forDisplay("", in: ["": GridConfig(columns: 2, rows: 2, gap: 0)])
        == GridConfig.defaults)
}

private let board = Rect(originX: 100, originY: 200, width: 1000, height: 600)

/// **兩處各縮一半**：畫布縮 `gap/2`、每一格再縮 `gap/2`，於是外緣的留白與
/// 兩個視窗之間的縫都恰好是 `gap`。只縮其中一邊的話兩者會差一倍，而畫面上
/// 那看起來只是「邊緣怪怪的」。
@Test func adjacentCellsAreExactlyOneGapApart() {
    let left = GapInset.cell(GridConfig(columns: 2, rows: 1, gap: 20),
                             spec: .init(rows: 1, columns: 2, originX: 0, originY: 0,
                                         width: 1, height: 1), canvas: board)
    let right = GapInset.cell(GridConfig(columns: 2, rows: 1, gap: 20),
                              spec: .init(rows: 1, columns: 2, originX: 1, originY: 0,
                                          width: 1, height: 1), canvas: board)
    #expect(abs((right.originX - (left.originX + left.width)) - 20) < 1e-9)
    // 外緣也是一個 gap，不是半個。
    #expect(abs((left.originX - board.originX) - 20) < 1e-9)
    #expect(abs((board.originX + board.width - (right.originX + right.width)) - 20) < 1e-9)
}

/// **對照組**：`gap == 0` 時與完全不套間距逐位元組相同。少了它，
/// 「一律縮 8」與正確的實作分不出來。
@Test func zeroGapIsByteForByteTheSameAsNoInset() {
    let spec = WindowGeometry.GridSpec(rows: 4, columns: 6, originX: 2, originY: 1,
                                       width: 2, height: 2)
    let inset = GapInset.cell(GridConfig(columns: 6, rows: 4, gap: 0),
                              spec: spec, canvas: board)
    let plain = WindowGeometry.cell(spec, canvas: board)
    #expect(inset == plain)
}

/// 間距比格子還大時**不要把矩形縮成負的**——一個負寬的視窗
/// `AXUIElementSetAttributeValue` 不一定會拒絕，而它整個消失。
@Test func aGapWiderThanTheCellLeavesTheRectAlone() {
    let spec = WindowGeometry.GridSpec(rows: 1, columns: 1, originX: 0, originY: 0,
                                       width: 1, height: 1)
    let huge = GapInset.cell(GridConfig(columns: 1, rows: 1, gap: 100_000),
                             spec: spec, canvas: board)
    #expect(huge.width > 0)
    #expect(huge.height > 0)
}

@Test func gridsRoundTripThroughTheDocument() {
    let json = JSONValue.object([
        JSONMember(key: "bindings", value: .array([])),
        JSONMember(key: "grids", value: .object([
            JSONMember(key: builtin, value: .object([
                JSONMember(key: "columns", value: .number("4")),
                JSONMember(key: "rows", value: .number("4")),
                JSONMember(key: "gap", value: .number("20")),
            ])),
        ])),
    ])
    let (document, problems) = HotkeyBindings.read(json)
    #expect(problems.isEmpty)
    #expect(document.grids[builtin] == GridConfig(columns: 4, rows: 4, gap: 20))
    // 寫回去要拿得回同一份。
    let again = HotkeyBindings.read(HotkeyBindings.write(document)).document
    #expect(again.grids == document.grids)
}

/// **與預設相同時不寫進檔案**，與 `mouse` 同一條慣例：預設值寫進去只是雜訊，
/// 而這個檔是給人看的。
@Test func aDisplayWithTheDefaultsIsNotWrittenOut() {
    var document = HotkeyDocument(bindings: [], floatApps: [])
    document.grids = [builtin: GridConfig.defaults]
    guard case let .object(members) = HotkeyBindings.write(document) else {
        Issue.record("write 沒有回物件")
        return
    }
    #expect(!members.contains { $0.key == "grids" })
}

/// 壞掉的**單一台螢幕**跳過並說一句，不整份拒絕——與綁定同一條慣例：
/// 一個打錯的字不該關掉全部螢幕的設定。
@Test func aMalformedDisplayIsReportedAndSkipped() {
    let json = JSONValue.object([
        JSONMember(key: "bindings", value: .array([])),
        JSONMember(key: "grids", value: .object([
            JSONMember(key: "good", value: .object([
                JSONMember(key: "columns", value: .number("3")),
                JSONMember(key: "rows", value: .number("2")),
            ])),
            JSONMember(key: "bad", value: .string("4x4")),
        ])),
    ])
    let (document, problems) = HotkeyBindings.read(json)
    #expect(document.grids["good"]?.columns == 3)
    // 缺 gap 用預設的 8，不是 0。
    #expect(document.grids["good"]?.gap == 8)
    #expect(document.grids["bad"] == nil)
    #expect(problems.count == 1)
    #expect(problems[0].contains("bad"))
}

/// **鍵序要排過。** 字典沒有順序，不排的話同一份設定每次存檔都可能換行序，
/// 而那是一個沒有內容的 diff。
///
/// 這一條要**兩台**螢幕才有鑑別力：只有一個鍵時 `.sorted()` 拿掉也不會紅，
/// 而 Task 7 原本那三條測試的 grids 都最多一個鍵（實作者自己指出來的）。
@Test func theWrittenDisplaysComeOutInSortedKeyOrder() {
    var document = HotkeyDocument(bindings: [], floatApps: [])
    document.grids = ["ZZZZ": GridConfig(columns: 2, rows: 2, gap: 4),
                      "AAAA": GridConfig(columns: 3, rows: 3, gap: 6)]
    guard case let .object(members) = HotkeyBindings.write(document),
          case let .object(rows)? = members.first(where: { $0.key == "grids" })?.value
    else {
        Issue.record("write 沒有寫出 grids")
        return
    }
    #expect(rows.map(\.key) == ["AAAA", "ZZZZ"])
}
