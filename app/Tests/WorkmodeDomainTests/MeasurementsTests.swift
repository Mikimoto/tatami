import Testing
@testable import WorkmodeDomain

// 這些 fixture 的形狀照 `yabai -m query --windows` 實際回的欄位名，
// 尤其那三個帶連字號的旗標——它們在 jq 那側必須寫成 `.["is-floating"]`，
// 少一個就變成減法。

/// `{"frame":{...}}`。值一律走 `.number`，因為 bash 那側是 `| floor`。
private func window(_ fields: (String, String)...) -> JSONValue {
    .object([JSONMember(key: "frame",
                        value: .object(fields.map { JSONMember(key: $0.0, value: .number($0.1)) }))])
}

private func sibling(id: String, width: String,
                     floating: Bool = false, minimized: Bool = false,
                     visible: Bool = true) -> JSONValue
{
    .object([
        JSONMember(key: "id", value: .number(id)),
        JSONMember(key: "is-floating", value: .bool(floating)),
        JSONMember(key: "is-minimized", value: .bool(minimized)),
        JSONMember(key: "is-visible", value: .bool(visible)),
        JSONMember(key: "frame", value: .object([JSONMember(key: "w", value: .number(width))])),
    ])
}

// MARK: - win_frame_x 與 chat 自己的寬度

@Test func floorsTheFrameFieldTheWayJQPrintsIt() {
    #expect(Measurements.flooredFrameField(window(("x", "2.9")), "x") == "2")
    // 算出來的數字不再逐字保留：`1e3 | floor` 印的是 `1000`（實測）。
    #expect(Measurements.flooredFrameField(window(("w", "1e3")), "w") == "1000")
    #expect(Measurements.flooredFrameField(window(("x", "-0.4")), "x") == "-1")
}

/// `.frame` 不存在時 bash 走的是 `null | floor`＝jq runtime error（rc=5），
/// 而 stdout 全空（實測），所以呼叫端拿到的是空字串而不是 `null` 這四個字。
@Test func measuresNothingWhenTheFrameOrTheFieldIsMissing() {
    #expect(Measurements.flooredFrameField(.object([]), "x") == nil)
    #expect(Measurements.flooredFrameField(window(("y", "10")), "x") == nil)
    // 字串索引碰到非物件也是 runtime error。
    #expect(Measurements.flooredFrameField(.number("5"), "x") == nil)
    // 欄位在但不是數字：`"abc" | floor` 一樣是 runtime error。
    #expect(Measurements.flooredFrameField(
        .object([JSONMember(key: "frame",
                            value: .object([JSONMember(key: "x", value: .string("3"))]))]), "x"
    ) == nil)
}

// MARK: - chat_vs_sibling_width 的 sibling 那半

@Test func picksTheWidestSiblingAndFloorsIt() {
    let windows = JSONValue.array([
        sibling(id: "1", width: "626.5"),
        sibling(id: "7", width: "1878.9"),
        sibling(id: "2", width: "900"),
    ])
    #expect(Measurements.widestSibling(windows: windows, excluding: .number("3")) == "1878")
}

/// `--argjson c` 讓 `.id != $c` 是**數值**比較：`5` 與 `5.0` 是同一個視窗。
/// 若這裡退化成字串比較，chat 自己就會被算進 sibling，於是 apply_ratio 永遠
/// 覺得方向是對的。
@Test func excludesTheChatWindowByNumericComparisonNotByLiteral() {
    let windows = JSONValue.array([sibling(id: "5.0", width: "1878"), sibling(id: "9", width: "600")])
    #expect(Measurements.widestSibling(windows: windows, excluding: .number("5")) == "600")
}

/// 浮動的橫跨切割線、最小化的不在 bsp 樹裡、不可見的 frame 是舊的。
/// 缺欄位一律排除：`select(.["is-floating"] == false)` 對 null 是 false。
@Test func skipsWindowsThatAreNotPartOfTheTree() {
    let windows = JSONValue.array([
        sibling(id: "1", width: "3000", floating: true),
        sibling(id: "2", width: "2900", minimized: true),
        sibling(id: "3", width: "2800", visible: false),
        // 三個旗標都沒有：null 既不是 false 也不是 true。
        .object([JSONMember(key: "id", value: .number("4")),
                 JSONMember(key: "frame",
                            value: .object([JSONMember(key: "w", value: .number("2700"))]))]),
        sibling(id: "5", width: "626"),
    ])
    #expect(Measurements.widestSibling(windows: windows, excluding: .number("99")) == "626")
}

/// 空清單的 `max` 是 null，`null // empty` 產生 empty，於是 **floor 沒有執行**
/// ——零輸出、rc=0，不是 runtime error。這條是 apply_ratio 的 `[ -n "$ow" ]`
/// 唯一的觸發點：該 space 只有 chat 自己的時候不能去比寬度。
@Test func measuresNothingWhenThereIsNoSibling() {
    #expect(Measurements.widestSibling(windows: .array([]), excluding: .number("5")) == nil)
    #expect(Measurements.widestSibling(windows: .array([sibling(id: "5", width: "1878")]),
                                       excluding: .number("5")) == nil)
    #expect(Measurements.widestSibling(windows: .array([sibling(id: "1", width: "1878",
                                                                floating: true)]),
        excluding: .number("5")) == nil)
    // 根不是容器＝`.[]` 的 runtime error，同樣是零輸出。
    #expect(Measurements.widestSibling(windows: .number("5"), excluding: .number("1")) == nil)
}

// MARK: - observed_axis 的重疊判斷

@Test func callsItHorizontalWhenTheXRangesOverlap() {
    // 兩個視窗都從螢幕左邊起算、寬度相同＝上下疊著。
    #expect(Measurements.axis(firstX: "0", firstWidth: "2560", secondX: "0", secondWidth: "2560") == "horizontal")
    // 只重疊一個點寬也算重疊。
    #expect(Measurements.axis(firstX: "0", firstWidth: "1281", secondX: "1280", secondWidth: "1280") == "horizontal")
}

@Test func callsItVerticalWhenTheXRangesDoNotOverlap() {
    // 左右分：a 佔 [0,1280)、b 佔 [1280,2560)，邊界剛好相接不算重疊。
    #expect(Measurements.axis(firstX: "0", firstWidth: "1280", secondX: "1280", secondWidth: "1280") == "vertical")
    #expect(Measurements.axis(firstX: "1280", firstWidth: "1280", secondX: "0", secondWidth: "1280") == "vertical")
}

/// 量不到時 bash 的路徑是：空字串在 `$(( ))` 裡是 0，但 `[ "0" -gt "" ]` 是
/// `integer expected`（rc=2）＝條件為假，於是判成 vertical（實測）。
/// 這一條是「不可見 space 上量不到 frame」時的實際行為，不是理論分支。
@Test func fallsBackToVerticalWhenAMeasurementIsMissing() {
    #expect(Measurements.axis(firstX: nil, firstWidth: nil, secondX: nil, secondWidth: nil) == "vertical")
    #expect(Measurements.axis(firstX: "", firstWidth: "", secondX: "", secondWidth: "") == "vertical")
    // 第一個測試過得去（0 + 0 > -1），第二個 `[ "$sum" -gt "" ]` 才出錯。
    #expect(Measurements.axis(firstX: nil, firstWidth: nil, secondX: "-1", secondWidth: "5") == "vertical")
    // a 量得到、b 量不到。
    #expect(Measurements.axis(firstX: "10", firstWidth: "10", secondX: nil, secondWidth: nil) == "vertical")
}

/// 非整數形狀（`1e999 | floor` 印的 `1.7976931348623157e+308`）不是「條件為假」：
/// 實測 bash 的算術展開直接中止整個 `if`，h 與 v 都沒印、rc=1。
/// 所以它與 query 失敗走同一個管道（零輸出＋非零 rc），不是 vertical。
@Test func measuresNothingWhenBashArithmeticWouldFail() {
    #expect(Measurements.axis(firstX: "1.5e+300", firstWidth: "0", secondX: "1", secondWidth: "1") == nil)
    // 短路：第一個 `[` 為假時 `$((bx + bw))` 根本沒有求值，所以壞的 bw 到不了。
    #expect(Measurements.axis(firstX: "0", firstWidth: "0", secondX: "10", secondWidth: "1.5e+300") == "vertical")
}

// MARK: - in_order

/// vertical 看 x、其餘看 y。反直覺是命名的緣故：vertical 指分割線是垂直的
/// （左右分），左右分的先後由 x 決定。
@Test func mapsVerticalToXAndEverythingElseToY() {
    #expect(Measurements.orderField(forAxis: "vertical") == "x")
    #expect(Measurements.orderField(forAxis: "horizontal") == "y")
    // bash 是字面字串比較，不認得的字一律落到 y。
    #expect(Measurements.orderField(forAxis: "VERTICAL") == "y")
    #expect(Measurements.orderField(forAxis: "") == "y")
}

@Test func inOrderNeedsBothMeasurements() {
    #expect(Measurements.isInOrder("0", "1280"))
    #expect(!Measurements.isInOrder("1280", "0"))
    // 相等不算「排在前面」。
    #expect(!Measurements.isInOrder("0", "0"))
    #expect(Measurements.isInOrder("-100", "0"))
    // 任一邊空就是 false ＝「順序不對」，呼叫端會去 swap 再量一次。
    #expect(!Measurements.isInOrder(nil, "1280"))
    #expect(!Measurements.isInOrder("0", nil))
    #expect(!Measurements.isInOrder("", ""))
    // 非整數走的是 `[` 的 integer expected（rc=2）＝false，而不是 axis 那條
    // 算術中止的路——同一種壞值在兩支函式裡的後果不同。
    #expect(!Measurements.isInOrder("1.5e+300", "0"))
}

// MARK: - detect_location 的前半

/// `tr '\n' ' '` 把每個 uuid 後面的換行都換成空白，最後一個也是，所以**結尾有
/// 一個空白**。match_location 的邊界比對依賴它。
@Test func joinsConnectedUUIDsWithATrailingSpace() {
    let displays = JSONValue.array([
        .object([JSONMember(key: "uuid", value: .string("AAA"))]),
        .object([JSONMember(key: "uuid", value: .string("BBB"))]),
    ])
    #expect(Displays.connectedUUIDs(in: displays) == "AAA BBB ")
}

/// runtime error 中止串流但**保留已經印出來的行**（實測
/// `[{uuid:"A"}, 5, {uuid:"B"}]` 得到 `"A "`）。空輸入與非容器是空字串
/// ——後者正是 query 失敗那條路。
@Test func stopsAtTheFirstRuntimeErrorButKeepsWhatWasPrinted() {
    let displays = JSONValue.array([
        .object([JSONMember(key: "uuid", value: .string("AAA"))]),
        .number("5"),
        .object([JSONMember(key: "uuid", value: .string("BBB"))]),
    ])
    #expect(Displays.connectedUUIDs(in: displays) == "AAA ")
    #expect(Displays.connectedUUIDs(in: .array([])) == "")
    #expect(Displays.connectedUUIDs(in: .number("5")) == "")
    // 缺 uuid 的螢幕印的是字面的 `null` 四個字（`jq -r` 對 null 的印法）。
    #expect(Displays.connectedUUIDs(in: .array([.object([])])) == "null ")
}
