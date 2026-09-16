import Testing
@testable import WorkmodeDomain

// `space_rects`：把 yabai 的視窗清單整理成矩形。與 SpacesTests 分開的理由同上——
// 它自己帶著一整組視窗語料（srWindows）與四支只有它用得到的取值工具。
//
// 最後那一組驗的是 jq 的 dtoa：`floor` 算出來的數字**不再**逐字保留，改走 jq
// 自己的印法，與 layout.json 那條「字面值原樣保留」是相反的規則。

// MARK: - space_rects 的語料

/// 預設是「一般的、看得見的視窗」。這樣寫是為了讓下面 srWindows 裡的**例外**
/// 自己跳出來：整組只有 608 是浮動的、700 是最小化的，那正是它們在語料裡的角色。
private struct Flags {
    var floating = false
    var minimized = false
    var visible = true
}

private struct Frame {
    let originX: String
    let originY: String
    let width: String
    let height: String
}

private func window(id: String, app: String, title: String,
                    flags: Flags = Flags(), frame: Frame) -> JSONValue
{
    obj([("id", num(id)), ("app", .string(app)), ("title", .string(title)),
         ("is-floating", .bool(flags.floating)), ("is-minimized", .bool(flags.minimized)),
         ("is-visible", .bool(flags.visible)),
         ("frame", obj([("x", num(frame.originX)), ("y", num(frame.originY)),
                        ("w", num(frame.width)), ("h", num(frame.height))]))])
}

/// 與 tests/test_workmode.sh 的 SR_WINS 相同：149/191 是 main 上真正受管理的兩個，
/// 608 是浮動的 Finder，700 是最小化的，701 與 149 的 frame 完全相同（yabai stack）。
private let srWindows = JSONValue.array([
    window(id: "149", app: "Ghostty", title: "claude",
           frame: Frame(originX: "1724", originY: "43", width: "1692", height: "1349")),
    window(id: "191", app: "Safari", title: "個人",
           frame: Frame(originX: "24", originY: "43", width: "1692", height: "1349")),
    window(id: "608", app: "Finder", title: "raw", flags: Flags(floating: true),
           frame: Frame(originX: "602", originY: "874", width: "920", height: "436")),
    window(id: "700", app: "Zed", title: "min", flags: Flags(minimized: true, visible: false),
           frame: Frame(originX: "0", originY: "0", width: "10", height: "10")),
    window(id: "701", app: "Xcode", title: "stack",
           frame: Frame(originX: "1724", originY: "43", width: "1692", height: "1349")),
])

/// jq 的 `tostring`。Domain 不能依賴 Wire 的 writer，所以容器的 compact 形式由
/// 呼叫端供給——測試這邊只需要純量，容器另有一條專門的斷言。
private func scalarText(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case let .bool(flag): flag ? "true" : "false"
    case let .number(literal): literal
    case let .string(text): text
    case .array, .object: "<容器>"
    }
}

private func rects(_ windows: JSONValue, _ idmap: JSONValue) throws -> SpaceRectsResult {
    try SpaceRects.compute(windows: windows, idmap: idmap, idText: scalarText)
}

private func field(_ value: JSONValue, _ key: String) -> JSONValue? {
    guard case let .object(members) = value else { return nil }
    return members.first { $0.key == key }?.value
}

private func rectList(_ result: SpaceRectsResult) -> [JSONValue] {
    guard case let .array(items) = result.rects else { return [] }
    return items
}

// MARK: - space_rects（test_workmode.sh:618-623、:662）

@Test func keepsManagedWindowsSortedByXWithTheirKnownLabels() throws {
    let result = try rects(srWindows, obj([("191", .string("工作瀏覽"))]))
    let pairs = rectList(result).map { rect in
        "\(scalarText(field(rect, "label") ?? .null)):\(scalarText(field(rect, "x") ?? .null))"
    }
    #expect(pairs.joined(separator: ",") == "工作瀏覽:24,:1724")
}

@Test func aFullyOverlappingStackKeepsOnlyOneRect() throws {
    #expect(try rectList(rects(srWindows, obj([]))).count == 2)
}

/// 被當成 stack 丟掉的視窗要能報出來，否則畫面上有東西沒存到而報告完全看不出來。
@Test func theDroppedStackWindowIsReported() throws {
    let dropped = try rects(srWindows, obj([])).dropped
    #expect(dropped.count == 1)
    #expect(field(dropped[0], "app") == .string("Xcode"))
}

@Test func eachRectCarriesItsAppAndSize() throws {
    let first = try rectList(rects(srWindows, obj([])))[0]
    #expect(field(first, "app") == .string("Safari"))
    #expect(field(first, "w") == num("1692"))
    #expect(field(first, "h") == num("1349"))
}

@Test func anEmptyWindowListGivesAnEmptyArrayNotNull() throws {
    let result = try rects(.array([]), obj([]))
    #expect(result.rects == .array([]))
    #expect(result.dropped.isEmpty)
}

// MARK: - space_rects 的邊界（實測）

/// 鍵序是 rects_to_tree 與差分都看得到的東西，所以整份物件一起釘。
@Test func theRectObjectKeepsJQsKeyOrder() throws {
    let one = JSONValue.array([window(id: "7", app: "A", title: "t",
                                      frame: Frame(originX: "1", originY: "2",
                                                   width: "3", height: "4"))])
    #expect(try rects(one, obj([("7", .string("L"))])).rects == .array([
        obj([("id", num("7")), ("app", .string("A")), ("title", .string("t")),
             ("label", .string("L")), ("x", num("1")), ("y", num("2")),
             ("w", num("3")), ("h", num("4"))]),
    ]))
}

/// 三個旗標都要恰好對上：缺欄位是 null，null 既不是 false 也不是 true。
@Test func aWindowMissingOneOfTheThreeFlagsIsExcluded() throws {
    let missing = JSONValue.array([obj([
        ("id", num("1")), ("app", .string("A")),
        ("is-minimized", .bool(false)), ("is-visible", .bool(true)),
        ("frame", obj([("x", num("0")), ("y", num("0")),
                       ("w", num("1")), ("h", num("1"))])),
    ])])
    #expect(try rects(missing, obj([])).rects == .array([]))
}

/// `.title // ""`：缺欄位與 null 都收斂成空字串。
@Test func aMissingTitleBecomesAnEmptyString() throws {
    let untitled = JSONValue.array([obj([
        ("id", num("1")), ("app", .string("A")), ("title", .null),
        ("is-floating", .bool(false)), ("is-minimized", .bool(false)),
        ("is-visible", .bool(true)),
        ("frame", obj([("x", num("0")), ("y", num("0")),
                       ("w", num("1")), ("h", num("1"))])),
    ])])
    #expect(try field(rectList(rects(untitled, obj([])))[0], "title") == .string(""))
}

/// `$m[.id | tostring]` 用的是 id 的**字面值**，所以 `191.0` 查的是 "191.0"、
/// 對不上 "191"；而 id 本身照樣逐字保留在輸出裡。
@Test func theLabelIsLookedUpByTheIdsLiteralText() throws {
    let floaty = JSONValue.array([window(id: "191.0", app: "A", title: "t",
                                         frame: Frame(originX: "0", originY: "0",
                                                      width: "1", height: "1"))])
    let rect = try rectList(rects(floaty, obj([("191", .string("L"))])))[0]
    #expect(field(rect, "label") == .string(""))
    #expect(field(rect, "id") == num("191.0"))
}

/// 那個查表就是靠呼叫端給的 `tostring`——容器 id 的 compact 形式在 Wire，
/// 所以這一層只是照用，不自己算。
@Test func theCallerSuppliedToStringDecidesTheLookupKey() throws {
    let weird = JSONValue.array([obj([
        ("id", obj([("k", num("1"))])), ("app", .string("A")),
        ("is-floating", .bool(false)), ("is-minimized", .bool(false)),
        ("is-visible", .bool(true)),
        ("frame", obj([("x", num("0")), ("y", num("0")),
                       ("w", num("1")), ("h", num("1"))])),
    ])])
    let result = try SpaceRects.compute(windows: weird,
                                        idmap: obj([("{\"k\":1}", .string("L"))]),
                                        idText: { _ in "{\"k\":1}" })
    #expect(field(rectList(result)[0], "label") == .string("L"))
}

/// `$m` 是 null 時 `null["k"]` 是 null（不是錯），於是 label 收斂成空字串；
/// 是陣列就報錯（`Cannot index array with string`）。
@Test func aNullIdmapGivesEmptyLabelsAndAnArrayOneIsARuntimeError() throws {
    let one = JSONValue.array([window(id: "1", app: "A", title: "t",
                                      frame: Frame(originX: "0", originY: "0",
                                                   width: "1", height: "1"))])
    #expect(try field(rectList(rects(one, .null))[0], "label") == .string(""))
    #expect(throws: SpaceRectsError.runtime) { try rects(one, .array([num("1")])) }
}

/// group_by 的鍵是 `[x, y, w, h]` 且排序過，所以丟掉的那些照**組**的順序報出來，
/// 不是照來源順序；同一組之內才是來源順序。
@Test func theDroppedWindowsFollowTheSortedGroupOrder() throws {
    func at(_ id: String, _ app: String, _ originX: String) -> JSONValue {
        window(id: id, app: app, title: "t",
               frame: Frame(originX: originX, originY: "0", width: "10", height: "10"))
    }
    let stacked = JSONValue.array([at("1", "Za", "900"), at("2", "Zb", "900"),
                                   at("3", "Aa", "100"), at("4", "Ab", "100"),
                                   at("5", "Ac", "100")])
    let result = try rects(stacked, obj([]))
    #expect(result.dropped.map { field($0, "app") } ==
        [.string("Ab"), .string("Ac"), .string("Zb")])
    // 留下來的是每組**來源順序**的第一個，再依 x 排序。
    #expect(rectList(result).map { field($0, "app") } == [.string("Aa"), .string("Za")])
}

/// `.frame.x | floor` 對非數字報錯，整個串流中止。
@Test func aNonNumericOrMissingFrameIsARuntimeError() throws {
    func withFrame(_ frame: JSONValue) -> JSONValue {
        .array([obj([("id", num("1")), ("app", .string("A")),
                     ("is-floating", .bool(false)), ("is-minimized", .bool(false)),
                     ("is-visible", .bool(true)), ("frame", frame)])])
    }
    #expect(throws: SpaceRectsError.runtime) { try rects(withFrame(.null), obj([])) }
    #expect(throws: SpaceRectsError.runtime) {
        try rects(withFrame(obj([("x", .string("z")), ("y", num("0")),
                                 ("w", num("1")), ("h", num("1"))])), obj([]))
    }
}

@Test func aNonIterableWindowListIsARuntimeError() throws {
    #expect(throws: SpaceRectsError.runtime) { try rects(num("5"), obj([])) }
    #expect(throws: SpaceRectsError.runtime) { try rects(.array([num("5")]), obj([])) }
}

/// floor 會把小數往下取，負的往更小的方向。
@Test func fractionalFramesAreFlooredDownwards() throws {
    let fractional = JSONValue.array([window(id: "1", app: "A", title: "t",
                                             frame: Frame(originX: "1.9", originY: "-0.5",
                                                          width: "2.50", height: "3"))])
    let rect = try rectList(rects(fractional, obj([])))[0]
    #expect(field(rect, "x") == num("1"))
    #expect(field(rect, "y") == num("-1"))
    #expect(field(rect, "w") == num("2"))
    #expect(field(rect, "h") == num("3"))
}

// MARK: - jq 的 double 印法

/// `floor` 算出來的數字不再是字面值，jq 改用它自己的 dtoa 印，規則與 `layout.json`
/// 那條「逐字保留」完全不同。左邊是輸入的字面值，右邊是 2026-08-14 拿
/// jq 1.8.2 實跑 `floor` 得到的輸出，一條都不是照語意推的。
///
/// 轉指數的門檻不是固定的量級，而是「最短往返表示的位數 + 15」：`1e15` 印成整數
/// 而 `1e16` 印成 `1e+16`，但 `1.5e16`（兩位數字）又印回整數。
@Test func flooredNumbersArePrintedTheWayJQPrintsComputedDoubles() {
    let measured = [
        ("0", "0"), ("-0.0", "-0"), ("0.5", "0"), ("-0.5", "-1"), ("-3.7", "-4"),
        ("1724", "1724"), ("1e3", "1000"), ("2.50", "2"),
        ("1e15", "1000000000000000"), ("5e15", "5000000000000000"),
        ("1e16", "1e+16"), ("1.5e16", "15000000000000000"),
        ("1e17", "1e+17"), ("99999999999999999", "1e+17"),
        ("123456789012345678", "123456789012345680"),
        ("12345678901234567890", "12345678901234567000"),
        ("9007199254740993", "9007199254740992"),
        ("-1e15", "-1000000000000000"), ("-1e16", "-1e+16"),
        ("1.5e20", "1.5e+20"), ("1e21", "1e+21"), ("1e300", "1e+300"),
        // jq 把溢位的字面值收斂到 DBL_MAX 再印。
        ("1e999", "1.7976931348623157e+308"),
        ("-1e999", "-1.7976931348623157e+308"),
    ]
    for (literal, expected) in measured {
        #expect(SpaceRects.flooredText(literal) == expected, "floor(\(literal))")
    }
}
