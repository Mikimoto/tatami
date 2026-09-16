import Testing
import WorkmodeCore
import WorkmodeDomain

// `--save` 的 fixture 與 harness。**與測試分檔的理由是 lint**：
// 那個檔加完 `--all` 那兩條之後是 401 行（`file_length` 上限 400）。
// 名字帶 `save` 前綴是因為這個 target 裡 `Scene`／`layoutPath` 都撞名。

/// `otherSpaces` 是「這個 profile 底下**已經存過**的其他 space」。它們的樹在這一輪
/// 不會被重新量（只有目前可見的那個量得準），所以 `--save` 要說出來有幾個沒動。
func config(profiles: [String] = ["開發"],
            catalog: [(String, String)] = [("Code", "Ghostty")],
            otherSpaces: [String] = [],
            // 非空 ＝ 每個 profile 自己帶一份 `windows`。那一份**整塊取代**共用層與
            // 地點層（`LayoutQuery.swift:115`），所以它會是新規則唯一放得進去的地方
            // ——共用層那份對這個 profile 一個字都不算數。
            profileCatalog: [(String, String)] = []) -> JSONValue
{
    var entries: [JSONMember] = []
    for name in profiles {
        var fields = [JSONMember(key: "trees", value: .object([
            JSONMember(key: "main", value: leaf("Code")),
        ]))]
        if !profileCatalog.isEmpty {
            fields.append(JSONMember(key: "windows", value: catalogRules(profileCatalog)))
        }
        if !otherSpaces.isEmpty {
            fields.append(JSONMember(key: "spaceTrees", value: .object([
                JSONMember(key: "main", value: .object(otherSpaces.map {
                    JSONMember(key: $0, value: leaf("Code"))
                })),
            ])))
        }
        entries.append(JSONMember(key: name, value: .object(fields)))
    }
    return .object([
        JSONMember(key: "windows", value: catalogRules(catalog)),
        JSONMember(key: "home", value: .object([
            JSONMember(key: "desc", value: .string("家")),
            JSONMember(key: "displays", value: .object([
                JSONMember(key: "main", value: .string("HOME-UUID")),
            ])),
            JSONMember(key: "profiles", value: .object(entries)),
            JSONMember(key: "default", value: .string(profiles[0])),
        ])),
    ])
}

/// 一份 `windows` 清單，每條都是 `["app", <app>]` 的 catch-all。
private func catalogRules(_ catalog: [(String, String)]) -> JSONValue {
    .array(catalog.map { label, app in
        .object([
            JSONMember(key: "label", value: .string(label)),
            JSONMember(key: "match", value: .array([.string("app"), .string(app)])),
        ])
    })
}

let oneDisplay = JSONValue.array([
    .object([
        JSONMember(key: "uuid", value: .string("HOME-UUID")),
        JSONMember(key: "index", value: .number("1")),
    ]),
])

/// **`uuid` 不是裝飾**：存的是 `spaceTrees[角色][space uuid]`，沒有它這個角色
/// 就走「抓不到可見的 space」那條，整組測試一個字都存不出來。
let oneVisibleSpace = JSONValue.array([
    .object([
        JSONMember(key: "display", value: .number("1")),
        JSONMember(key: "index", value: .number("1")),
        JSONMember(key: "uuid", value: .string("SPACE-A")),
        JSONMember(key: "is-visible", value: .bool(true)),
    ]),
])

/// 一個受管理的視窗。`space_rects` 會濾掉浮動與最小化的，所以三個旗標都要有。
func window(id: String, app: String, title: String,
            originX: Int, width: Int) -> JSONValue
{
    .object([
        JSONMember(key: "id", value: .number(id)),
        JSONMember(key: "app", value: .string(app)),
        JSONMember(key: "title", value: .string(title)),
        JSONMember(key: "is-floating", value: .bool(false)),
        JSONMember(key: "is-minimized", value: .bool(false)),
        JSONMember(key: "is-visible", value: .bool(true)),
        JSONMember(key: "frame", value: .object([
            JSONMember(key: "x", value: .number(String(originX))),
            JSONMember(key: "y", value: .number("0")),
            JSONMember(key: "w", value: .number(String(width))),
            JSONMember(key: "h", value: .number("100")),
        ])),
    ])
}

struct SaveScene {
    let run: (String) -> SaveLayout.Outcome
    let runAll: (String) -> SaveLayout.Outcome
    let runAutomatic: (String, Bool) -> SaveLayout.Outcome
    let files: FakeFileStore
    let reporter: FakeReporter
    let terminal: FakeTerminal
    /// 交給 `format` 的那份合併結果。`files.writes` 只看得到 `"<formatted>"`
    /// ——規則放在清單的第幾個位置，那個字串一個字都沒說。
    let merged: MergedSpy
}

/// 記下最後一次要寫出去的設定。
///
/// 沒有它就沒有任何測試分得出「規則插在 catch-all 前面」與「接在它後面」：
/// 兩者的 `Outcome` 都是 `.written`，事件也一模一樣，而後者正是這一輪要修的缺陷。
final class MergedSpy {
    private(set) var last: JSONValue?

    func record(_ value: JSONValue) -> String {
        last = value
        return "<formatted>"
    }

    /// 某一份 `windows` 清單的 label，依它們在陣列裡的順序。順序就是待驗的東西
    /// （`RuleResolution` 先到先得），所以不排序也不去重。
    func labels(at path: [String]) -> [String]? {
        guard let root = last,
              case let .array(rows)? = JSONPath.get(root, path.map { .key($0) })
        else { return nil }
        return rows.map { row in
            guard case let .string(name)? = row["label"] else { return "?" }
            return name
        }
    }
}

/// `jq -r` 的最小模擬。抽出來是為了讓 `harness` 過 swiftlint 的
/// `cyclomatic_complexity`（上限 10，不准調參數）——那個 switch 自己就五個分支。
func rawTextForTests(_ json: JSONValue) -> String {
    switch json {
    case let .string(text): text
    case let .number(literal): literal
    case let .bool(flag): flag ? "true" : "false"
    case .null: "null"
    case .array, .object: "<container>"
    }
}

func harness(config value: JSONValue = config(),
             // 預設那個視窗的 app **不在**總表裡，所以它沒有名字、會被問。
             // 用 Ghostty 的話 `Code` 那條規則會先認出它，整個問名字的迴圈
             // 就一圈都不跑——這一組大半的測試都靠這個前提。
             windows: [JSONValue] = [window(id: "7", app: "Zed",
                                            title: "t", originX: 0, width: 100)],
             answers: [String] = [],
             hasTTY: Bool = true,
             displays: JSONValue = oneDisplay,
             spaces: JSONValue = oneVisibleSpace,
             // `--all` 用：space index → 那個 space 上的視窗。
             windowsBySpace: [String: [JSONValue]] = [:],
             // 自動命名那條路非要它不可：只有**恰好一個分頁**的 Safari 視窗才推得出
             // 身分（`AutoWindowName`），而分頁數就是這份 dump 裡第一欄等於該 window
             // id 的行數。預設空字串＝其餘每一條測試的行為不變。
             safariDump: String = "") -> SaveScene
{
    let yabai = FakeYabai()
    yabai.stubFixed(.displays, displays)
    yabai.stubFixed(.spaces, spaces)
    yabai.stubFixed(.windows, .array(windows))
    yabai.stubFixed(.windowsOnSpace("1"), .array(windows))
    for (index, extra) in windowsBySpace {
        yabai.stubFixed(.windowsOnSpace(index), .array(extra))
        for element in extra {
            if case let .number(id)? = element["id"] {
                yabai.stubFixed(.window(id), element)
            }
        }
    }
    for element in windows {
        if case let .number(id)? = element["id"] {
            yabai.stubFixed(.window(id), element)
        }
    }

    let files = FakeFileStore(files: [saveLayoutPath: saveLayoutText])
    let reporter = FakeReporter()
    let terminal = FakeTerminal(hasControllingTTY: hasTTY, lines: answers)
    let merged = MergedSpy()

    let subject = SaveLayout(
        yabai: yabai, safari: FakeSafari(dump: safariDump), terminal: terminal, files: files,
        layoutPath: saveLayoutPath, statePath: saveStatePath,
        parse: { text in
            if text == saveLayoutText {
                return value
            }
            throw JSONParseError.truncated
        },
        renderRaw: rawTextForTests,
        // 真正的寫入格式由 JSONWriter 對 `jq .` 差分驗過；這裡只要能分辨寫了什麼。
        format: { merged.record($0) },
        reporter: reporter
    )
    return SaveScene(run: { subject.run(want: $0, scope: .visible, interaction: .terminal) },
                     runAll: { subject.run(want: $0, scope: .all, interaction: .terminal) },
                     runAutomatic: { profile, overwrite in
                         subject.run(want: profile, scope: .all,
                                     interaction: .automatic(overwrite: overwrite))
                     },
                     files: files, reporter: reporter, terminal: terminal, merged: merged)
}
