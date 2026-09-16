import WorkmodeCore
import WorkmodeDomain

// `SpaceLayout` 的設定與 fake 接線。名字一律帶 spaceLayout／spc 前綴：Swift 的頂層
// 宣告在同一個測試 target 裡會撞名（是 invalid redeclaration 不是遮蔽），而
// ApplyLayoutFixtures 已經佔走了 config／display／visibleSpace 那幾個名字。

let spcLayoutPath = "/x/layout.json"
let spcStatePath = "/x/.tatami-state"
let spcLayoutText = "<layout.json>"

/// `windows` 有兩條 app 規則（`Code` → `Ghostty`、`Chat` → `Chat`）。第二條是
/// `eachSpaceGetsItsOwnTree` 的鑑別力來源：兩棵樹要引用**不同**的 label，
/// 否則「查對的那棵」與「拿第一棵」下的命令一模一樣。
///
/// `spaceTrees` 的鍵是 **space uuid**（2026-08-30 起）——名字那一層拿掉了。
func spcConfig(displays: [(String, String)] = [("main", "A")],
               spaceTrees: [(String, [(String, JSONValue)])] = [("main", [("U-1", leaf("Code"))])])
    -> JSONValue
{
    func nested(_ pairs: [(String, [(String, JSONValue)])]) -> JSONValue {
        .object(pairs.map { role in
            JSONMember(key: role.0, value: .object(role.1.map { JSONMember(key: $0.0, value: $0.1) }))
        })
    }
    return .object([
        JSONMember(key: "windows", value: .array([
            .object([
                JSONMember(key: "label", value: .string("Code")),
                JSONMember(key: "match", value: .array([.string("app"), .string("Ghostty")])),
            ]),
            .object([
                JSONMember(key: "label", value: .string("Chat")),
                JSONMember(key: "match", value: .array([.string("app"), .string("Chat")])),
            ]),
        ])),
        JSONMember(key: "home", value: .object([
            JSONMember(key: "desc", value: .string("家")),
            JSONMember(key: "displays", value: .object(
                displays.map { JSONMember(key: $0.0, value: .string($0.1)) }
            )),
            JSONMember(key: "profiles", value: .object([
                JSONMember(key: "開發", value: .object([
                    JSONMember(key: "trees", value: .object([])),
                    JSONMember(key: "spaceTrees", value: nested(spaceTrees)),
                ])),
            ])),
        ])),
    ])
}

/// 一台 uuid 為 A 的螢幕（index 1）。
///
/// **四個欄位缺一不可**：`Displays.frame` 少一個就回 nil，而 `SpaceLayout` 對
/// 「讀不到 frame」的下場是整個角色走「螢幕沒接上」——那會讓每一條護欄測試
/// 一起變成恆真（什麼都不做也叫「沒排到後面的角色」）。
let spcDisplays = JSONValue.array([
    .object([
        JSONMember(key: "uuid", value: .string("A")),
        JSONMember(key: "index", value: .number("1")),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "x", value: .number("0")),
            JSONMember(key: "y", value: .number("0")),
            JSONMember(key: "w", value: .number("3456.5")),
            JSONMember(key: "h", value: .number("2234.0")),
        ])),
    ]),
])

/// `spcDisplays` 那台螢幕的可視區，`server.calls` 的斷言拿它算期望矩形。
let spcCanvas = Rect(originX: 0, originY: 0, width: 3456.5, height: 2234)

/// 一台帶完整 frame 的螢幕。就地建 `displays` 的測試用它，免得漏掉 `x`／`y`
/// 而讓那個角色靜默走進「螢幕沒接上」。
func spcDisplay(uuid: String, index: Int,
                width: String = "3456.5", height: String = "2234.0") -> JSONValue
{
    .object([
        JSONMember(key: "uuid", value: .string(uuid)),
        JSONMember(key: "index", value: .number(String(index))),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "x", value: .number("0")),
            JSONMember(key: "y", value: .number("0")),
            JSONMember(key: "w", value: .number(width)),
            JSONMember(key: "h", value: .number(height)),
        ])),
    ])
}

func spcSpace(_ index: Int, display: Int, uuid: String, visible: Bool) -> JSONValue {
    .object([
        JSONMember(key: "display", value: .number(String(display))),
        JSONMember(key: "index", value: .number(String(index))),
        JSONMember(key: "uuid", value: .string(uuid)),
        JSONMember(key: "is-visible", value: .bool(visible)),
    ])
}

/// display 1 上兩個 space，可見的是 index 2（uuid `U-1`）——**刻意不是第一個**，
/// 這樣「拿第一個」的實作分得出來。
let spcSpaces = JSONValue.array([
    spcSpace(1, display: 1, uuid: "U-0", visible: false),
    spcSpace(2, display: 1, uuid: "U-1", visible: true),
])

/// 迴圈要用到的三份回應：規則比對掃全部視窗、位置查詢問單一視窗。
func spcStub(_ yabai: FakeYabai, displays: JSONValue = spcDisplays,
             spaces: JSONValue = spcSpaces, extraWindows: [JSONValue] = [])
{
    yabai.stubFixed(.displays, displays)
    yabai.stubFixed(.spaces, spaces)
    yabai.stubFixed(.windows, .array([
        .object([
            JSONMember(key: "app", value: .string("Ghostty")),
            JSONMember(key: "id", value: .number("7")),
        ]),
    ] + extraWindows))
    yabai.stubFixed(.window("7"), .object([
        JSONMember(key: "id", value: .number("7")),
        JSONMember(key: "display", value: .number("1")),
        JSONMember(key: "space", value: .number("2")),
        JSONMember(key: "is-minimized", value: .bool(false)),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "w", value: .number("100")),
            JSONMember(key: "h", value: .number("50")),
            JSONMember(key: "x", value: .number("0")),
            JSONMember(key: "y", value: .number("0")),
        ])),
    ]))
}

/// 與 `spcConfig` 同形，但那條規則是 **url-contains**（`fallback` 版由呼叫端指定）。
///
/// `--space` 的 Safari 閘門只有在「樹引用到 url 類規則」且「那個 space 上真的有
/// Safari 視窗」時才付那 1.94 秒，所以驗它需要一份 url 規則的設定。
func spcURLConfig(asFallback: Bool = false) -> JSONValue {
    var match: [JSONMember] = [
        JSONMember(key: "label", value: .string("Code")),
    ]
    if asFallback {
        match.append(JSONMember(key: "match",
                                value: .array([.string("app"), .string("Ghostty")])))
        match.append(JSONMember(key: "fallback",
                                value: .array([.string("url-contains"), .string("example.com")])))
    } else {
        match.append(JSONMember(key: "match",
                                value: .array([.string("url-contains"), .string("example.com")])))
    }
    return .object([
        JSONMember(key: "windows", value: .array([.object(match)])),
        JSONMember(key: "home", value: .object([
            JSONMember(key: "desc", value: .string("家")),
            JSONMember(key: "displays", value: .object([JSONMember(key: "main", value: .string("A"))])),
            JSONMember(key: "profiles", value: .object([
                JSONMember(key: "開發", value: .object([
                    JSONMember(key: "trees", value: .object([])),
                    JSONMember(key: "spaceTrees", value: .object([
                        JSONMember(key: "main", value: .object([
                            JSONMember(key: "U-1", value: leaf("Code")),
                        ])),
                    ])),
                ])),
            ])),
        ])),
    ])
}

/// 那個 space 上有沒有 Safari 視窗——閘門的第二個條件。
func spcStubSpaceWindows(_ yabai: FakeYabai, space: String, safari: Bool) {
    var windows: [JSONValue] = [
        .object([
            JSONMember(key: "app", value: .string("Ghostty")),
            JSONMember(key: "id", value: .number("7")),
        ]),
    ]
    if safari {
        windows.append(.object([
            JSONMember(key: "app", value: .string("Safari")),
            JSONMember(key: "id", value: .number("8")),
        ]))
    }
    yabai.stubFixed(.windowsOnSpace(space), .array(windows))
}

/// display 1 上兩個 space，**兩個都不可見**——用來踩「螢幕在但抓不到可見的 space」。
///
/// 真實世界踩得到：`yabai -m query --spaces` 失敗（回空）或那台螢幕正在被系統
/// 切換的瞬間。fixture 直接把 `is-visible` 都設成 false 是最短的重現。
let spcNoVisibleSpaces = JSONValue.array([
    spcSpace(1, display: 1, uuid: "U-0", visible: false),
    spcSpace(2, display: 1, uuid: "U-1", visible: false),
])

/// 兩台螢幕：A（index 1）有可見的 space，B（index 3）**接著但一個 space 都沒有**。
///
/// 「螢幕沒接上」與「螢幕在但抓不到可見的 space」是兩個不同的分支，而分辨它們需要
/// 一台**查得到 index、卻在 spaces 裡沒有任何一筆**的螢幕。只有一台螢幕的 fixture
/// 沒有辦法同時踩到那個分支又留一個角色在後面。
let spcTwoDisplays = JSONValue.array([
    .object([
        JSONMember(key: "uuid", value: .string("A")),
        JSONMember(key: "index", value: .number("1")),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "x", value: .number("0")),
            JSONMember(key: "y", value: .number("0")),
            JSONMember(key: "w", value: .number("3456.5")),
            JSONMember(key: "h", value: .number("2234.0")),
        ])),
    ]),
    .object([
        JSONMember(key: "uuid", value: .string("B")),
        JSONMember(key: "index", value: .number("3")),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "x", value: .number("3456.5")),
            JSONMember(key: "y", value: .number("0")),
            JSONMember(key: "w", value: .number("1000")),
            JSONMember(key: "h", value: .number("800")),
        ])),
    ]),
])

// MARK: - 接線

//
// 從 `SpaceLayoutTests.swift` 搬過來（2026-09-07）：那個檔加上 `--launch`
// 的兩個 port 之後是 402 行，過了 swiftlint 的 `file_length`（400）。

struct SpaceScene {
    let run: (String) -> SpaceLayout.Outcome
    /// 同一個 subject 的 `.probe` 模式。
    let probe: (String) -> SpaceLayout.Outcome
    /// 同一個 subject 的 `--all`：每一棵有樹的 space，不只可見的那一個。
    let runAll: (String) -> SpaceLayout.Outcome
    let yabai: FakeYabai
    let server: FakeWindowServer
    let reporter: FakeReporter
    let safari: FakeSafari
    let files: FakeFileStore
    /// `--launch` 那兩個 port。**不論 `launch` 是不是 true 都建**：nil 那條要驗的
    /// 是「一次都沒被問過」，而那需要一個真的存在、只是沒被接上的紀錄本。
    let apps: FakeAppQuery
    let launcher: FakeAppLauncher
}

/// `launch` 是 false 就回 nil——`SpaceLayout` 靠那個 nil 決定「連 `isRunning` 都不問」。
///
/// 抽成一支函式而不是寫在 `spaceHarness` 裡：那支的 body 已經在 swiftlint 的
/// `function_body_length`（50）邊上，而那條規則不准調（`.swiftlint.yml` 的檔頭）。
private func spacePresence(launch: Bool, apps: FakeAppQuery, launcher: FakeAppLauncher,
                           reporter: FakeReporter) -> AppPresence?
{
    guard launch else { return nil }
    return AppPresence(apps: apps, launcher: launcher,
                       clock: FakeClock(), reporter: reporter)
}

/// `state` 是狀態檔的**內容**（nil ＝那個檔不存在）。頂端 inset 的校準讀它也寫它，
/// 所以它是這幾條的輸入之一。
func spaceHarness(config value: JSONValue = spcConfig(),
                  extraWindows: [JSONValue] = [],
                  safariOnSpace: Bool? = nil,
                  spaces: JSONValue = spcSpaces,
                  displays: JSONValue = spcDisplays,
                  state: String? = nil,
                  launch: Bool = false,
                  running: [String: Bool] = [:]) -> SpaceScene
{
    let apps = FakeAppQuery()
    for (app, value) in running {
        apps.stubFixed(app, value)
    }
    let launcher = FakeAppLauncher()
    let yabai = FakeYabai()
    let server = FakeWindowServer()
    let reporter = FakeReporter()
    let safari = FakeSafari(dump: "")
    spcStub(yabai, displays: displays, spaces: spaces, extraWindows: extraWindows)
    if let safariOnSpace {
        spcStubSpaceWindows(yabai, space: "2", safari: safariOnSpace)
    }
    var stored = [spcLayoutPath: spcLayoutText]
    if let state {
        stored[spcStatePath] = state
    }
    let files = FakeFileStore(files: stored)

    let subject = SpaceLayout(
        yabai: yabai, server: server, safari: safari, clock: FakeClock(),
        files: files,
        layoutPath: spcLayoutPath, statePath: spcStatePath,
        parse: { text in
            if text == spcLayoutText {
                return value
            }
            if let number = Int(text) {
                return .number(String(number))
            }
            throw JSONParseError.truncated
        },
        renderRaw: { json in
            switch json {
            case let .string(text): text
            case let .number(literal): literal
            case let .bool(flag): flag ? "true" : "false"
            case .null: "null"
            case .array, .object: "<container>"
            }
        },
        reporter: reporter,
        presence: spacePresence(launch: launch, apps: apps,
                                launcher: launcher, reporter: reporter)
    )
    // `run` 是套用、`probe` 是只辨識。兩個都給出來，因為「probe 一個會改變狀態的
    // 命令都不下」這件事只有拿同一個 harness 兩邊各跑一次才驗得出來。
    return SpaceScene(run: { subject.run(want: $0, mode: .apply, scope: .visible) },
                      probe: { subject.run(want: $0, mode: .probe, scope: .visible) },
                      runAll: { subject.run(want: $0, mode: .apply, scope: .all) },
                      yabai: yabai, server: server, reporter: reporter,
                      safari: safari, files: files,
                      apps: apps, launcher: launcher)
}
