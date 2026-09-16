import Testing
import WorkmodeCore
import WorkmodeDomain

// 這一層只驗三件事：問哪一個 query、問幾次、問的順序。判斷本身在
// WorkmodeDomainTests.MeasurementsTests。
//
// argv 的斷言不是形式：CLAUDE.md 記著 `--window` 與 `--space` 打錯一個字就會量到
// 別的東西，而「量錯視窗」與「量對視窗但判斷寫錯」在結果上長得一模一樣。

private func window(_ fields: (String, String)...) -> JSONValue {
    .object([JSONMember(key: "frame",
                        value: .object(fields.map { JSONMember(key: $0.0, value: .number($0.1)) }))])
}

private func managed(id: String, width: String) -> JSONValue {
    .object([
        JSONMember(key: "id", value: .number(id)),
        JSONMember(key: "is-floating", value: .bool(false)),
        JSONMember(key: "is-minimized", value: .bool(false)),
        JSONMember(key: "is-visible", value: .bool(true)),
        JSONMember(key: "frame", value: .object([JSONMember(key: "w", value: .number(width))])),
    ])
}

/// 兩個地點，main 分別是 AAA 與 BBB。match_location 只比 main。
private let layout = JSONValue.object([
    JSONMember(key: "home", value: .object([
        JSONMember(key: "displays", value: .object([
            JSONMember(key: "main", value: .string("AAA")),
        ])),
    ])),
    JSONMember(key: "office", value: .object([
        JSONMember(key: "displays", value: .object([
            JSONMember(key: "main", value: .string("BBB")),
        ])),
    ])),
])

// MARK: - win_frame_x

@Test func frameXAsksForThatOneWindowAndFloorsIt() {
    let yabai = FakeYabai()
    yabai.stub(.window("7"), [window(("x", "1280.9"))])

    #expect(WindowMeasurements(yabai: yabai).frameX(window: "7") == "1280")
    #expect(yabai.allArgv == [["query", "--windows", "--window", "7"]])
}

/// query 失敗（視窗不在了）在 bash 是 yabai rc=1 ＋ stdout 全空，接著 jq 吃空輸入
/// 回 rc=0 零輸出——所以呼叫端拿到空字串，不是錯誤。
@Test func frameXIsEmptyWhenTheWindowIsGone() {
    let yabai = FakeYabai()
    yabai.stubFailure(.window("999999"), YabaiError.commandFailed(argv: [], status: 1))

    #expect(WindowMeasurements(yabai: yabai).frameX(window: "999999") == nil)
}

// MARK: - chat_vs_sibling_width

@Test func chatWidthMeasuresTheChatWindowItself() {
    let yabai = FakeYabai()
    yabai.stub(.window("7"), [window(("w", "626.9"))])

    #expect(WindowMeasurements(yabai: yabai).width(chat: "7", space: "3", of: .chat) == "626")
    // chat 那條不問整個 space：多問一次就是多一個視窗可以移動的空隙。
    #expect(yabai.allArgv == [["query", "--windows", "--window", "7"]])
}

@Test func siblingWidthAsksForTheWholeSpaceAndSkipsChat() {
    let yabai = FakeYabai()
    yabai.stub(.windowsOnSpace("3"), [.array([managed(id: "7", width: "626"),
                                              managed(id: "9", width: "1878.5")])])

    #expect(WindowMeasurements(yabai: yabai).width(chat: "7", space: "3",
                                                   of: .widestSibling) == "1878")
    #expect(yabai.allArgv == [["query", "--windows", "--space", "3"]])
}

/// 該 space 只有 chat 自己：`max` 是 null、`// empty` 讓 floor 不執行，零輸出。
/// 這是 apply_ratio 的 `[ -n "$ow" ]` 唯一的觸發點——它拿到空字串就不去翻 ratio。
@Test func siblingWidthIsEmptyWhenChatIsAloneOnTheSpace() {
    let yabai = FakeYabai()
    yabai.stub(.windowsOnSpace("3"), [.array([managed(id: "7", width: "2560")])])

    #expect(WindowMeasurements(yabai: yabai).width(chat: "7", space: "3",
                                                   of: .widestSibling) == nil)
    // 空結果不是「沒問」——問過了，只是清單被濾光。
    #expect(yabai.allArgv == [["query", "--windows", "--space", "3"]])
}

@Test func siblingWidthIsEmptyWhenTheSpaceQueryFails() {
    let yabai = FakeYabai()
    yabai.stubFailure(.windowsOnSpace("3"), YabaiError.malformedOutput(argv: []))

    #expect(WindowMeasurements(yabai: yabai).width(chat: "7", space: "3",
                                                   of: .widestSibling) == nil)
}

// MARK: - observed_axis

@Test func observedAxisMeasuresBothWindowsOnceEachInOrder() {
    let yabai = FakeYabai()
    yabai.stub(.window("7"), [window(("x", "0"), ("w", "2560"))])
    yabai.stub(.window("9"), [window(("x", "0"), ("w", "2560"))])

    #expect(WindowMeasurements(yabai: yabai).observedAxis("7", "9") == "horizontal")
    // 兩次而不是四次：bash 把 JSON 存進變數再解四次，量的是同一個瞬間。
    #expect(yabai.allArgv == [
        ["query", "--windows", "--window", "7"],
        ["query", "--windows", "--window", "9"],
    ])
}

/// bash 是 `|| return 1`——這是少數看 exit code 的地方。呼叫端拿到空字串，
/// 而空字串永遠不等於樹裡的 axis，所以它會去 `--toggle split`。
@Test func observedAxisGivesUpWhenAQueryFails() {
    let yabai = FakeYabai()
    yabai.stub(.window("7"), [window(("x", "0"), ("w", "2560"))])
    yabai.stubFailure(.window("9"), YabaiError.commandFailed(argv: [], status: 1))

    #expect(WindowMeasurements(yabai: yabai).observedAxis("7", "9") == nil)
    #expect(yabai.allArgv.count == 2, "第一次成功之後仍要去問第二個，才知道它失敗了")

    // 第一個就失敗時第二個**不會**被問（bash 的 `|| return 1` 在中間）。
    let other = FakeYabai()
    other.stubFailure(.window("7"), YabaiError.commandFailed(argv: [], status: 1))
    #expect(WindowMeasurements(yabai: other).observedAxis("7", "9") == nil)
    #expect(other.allArgv == [["query", "--windows", "--window", "7"]])
}

// MARK: - in_order

@Test func inOrderComparesXForVerticalAndYForHorizontal() {
    let yabai = FakeYabai()
    yabai.stubFixed(.window("7"), window(("x", "0"), ("y", "1440")))
    yabai.stubFixed(.window("9"), window(("x", "1280"), ("y", "0")))

    let measurements = WindowMeasurements(yabai: yabai)
    #expect(measurements.isInOrder("7", "9", axis: "vertical"))
    #expect(!measurements.isInOrder("7", "9", axis: "horizontal"))
}

/// 與 observed_axis 不同：這裡沒有 `|| return`，兩次 query 都一定發生，
/// 失敗只是拿到空字串。少問第二次的話「兩邊都量不到」與「只有第一邊量不到」
/// 在結果上相同，錯誤就藏起來了。
@Test func inOrderQueriesBothWindowsEvenWhenTheFirstOneFails() {
    let yabai = FakeYabai()
    yabai.stubFailure(.window("7"), YabaiError.commandFailed(argv: [], status: 1))
    yabai.stub(.window("9"), [window(("x", "1280"))])

    #expect(!WindowMeasurements(yabai: yabai).isInOrder("7", "9", axis: "vertical"))
    #expect(yabai.allArgv == [
        ["query", "--windows", "--window", "7"],
        ["query", "--windows", "--window", "9"],
    ])
}

// MARK: - detect_location

@Test func detectLocationMatchesTheLocationWhoseMainIsConnected() {
    let yabai = FakeYabai()
    yabai.stub(.displays, [.array([
        .object([JSONMember(key: "uuid", value: .string("ZZZ"))]),
        .object([JSONMember(key: "uuid", value: .string("BBB"))]),
    ])])

    #expect(WindowMeasurements(yabai: yabai).detectLocation(in: layout) == "office")
    #expect(yabai.allArgv == [["query", "--displays"]])
}

/// query 失敗 → connected 是空字串 → 沒有地點的 main 配得上。
@Test func detectLocationFindsNothingWhenTheDisplaysQueryFails() {
    let yabai = FakeYabai()
    yabai.stubFailure(.displays, YabaiError.commandFailed(argv: [], status: 1))

    #expect(WindowMeasurements(yabai: yabai).detectLocation(in: layout) == nil)
}

/// 但空的 connected **不是**一律沒命中：`displays.main` 為空時 pattern 收斂成兩個
/// 相連的空白，而空的 connected 組出來的草堆剛好就是兩個空白，於是那個地點命中。
/// 這是 bash 現行行為（match_location 的 doc 記著），不是這一層可以順手修的東西。
@Test func detectLocationStillMatchesALocationWhoseMainIsEmpty() {
    let yabai = FakeYabai()
    yabai.stubFailure(.displays, YabaiError.commandFailed(argv: [], status: 1))
    let broken = JSONValue.object([
        JSONMember(key: "home", value: .object([
            JSONMember(key: "displays", value: .object([
                JSONMember(key: "main", value: .string("")),
            ])),
        ])),
    ])

    #expect(WindowMeasurements(yabai: yabai).detectLocation(in: broken) == "home")
}
