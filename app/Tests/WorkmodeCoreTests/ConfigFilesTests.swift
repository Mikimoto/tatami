import Testing
import WorkmodeCore
import WorkmodeDomain

// `load_layout` 與 `read_state` 的分別是這一組要守的東西：同樣是「檔案不在」，
// 前者是硬失敗（半套用一個爛佈局比什麼都不做更糟），後者是正常狀態（還沒有人設過覆寫）。

private let layoutPath = "/somewhere/layout.json"
private let statePath = "/somewhere/.tatami-state"

/// 一份**通得過** `validate_layout` 的最小設定：desc 非空字串、displays.main 有、
/// 而且最外層有 windows（否則會被判缺 `home.windows`）。
private let goodLayoutText =
    #"{"windows":[],"home":{"desc":"家","displays":{"main":"A"},"profiles":{"開發":{"trees":{}}}}}"#

private func goodConfig() -> JSONValue {
    .object([
        JSONMember(key: "windows", value: .array([])),
        JSONMember(key: "home", value: .object([
            JSONMember(key: "desc", value: .string("家")),
            JSONMember(key: "displays", value: .object([
                JSONMember(key: "main", value: .string("A")),
            ])),
            // profiles 不能是空的（workmode.sh:78），而 profile 必須有 trees（:88）。
            JSONMember(key: "profiles", value: .object([
                JSONMember(key: "開發", value: .object([
                    JSONMember(key: "trees", value: .object([])),
                ])),
            ])),
        ])),
    ])
}

/// 解析的接縫：Core 不許 import Wire，所以 loader 收一個解析函式。測試餵的是
/// 對照表而不是真的 parser——這裡要驗的是編排（誰先誰後、失敗怎麼收），
/// 而真 parser 的行為由 WorkmodeWireTests 守。
private func parser(_ table: [String: JSONValue]) -> (String) throws -> JSONValue {
    { text in
        guard let value = table[text] else { throw JSONParseError.truncated }
        return value
    }
}

private func loader(_ files: FakeFileStore, _ reporter: FakeReporter,
                    parse: @escaping (String) throws -> JSONValue
                        = parser([goodLayoutText: goodConfig()])) -> LayoutLoader
{
    LayoutLoader(files: files, path: layoutPath, parse: parse, reporter: reporter)
}

// MARK: - load_layout

/// workmode.sh:108-110。訊息走 **stderr**（那支函式的 stdout 是它的回傳值）。
@Test func reportsToStderrAndFailsWhenTheLayoutFileIsAbsent() {
    let files = FakeFileStore()
    let reporter = FakeReporter()

    #expect(throws: LayoutLoadFailure.missing(path: layoutPath)) {
        try loader(files, reporter).load()
    }
    #expect(reporter.events == [.layoutFileMissing(path: layoutPath)])
    #expect(reporter.events(on: .stdout).isEmpty)
}

/// workmode.sh:113-114。驗證不過就失敗，而**這裡不發任何事件**：那三段文字是
/// `validate_layout` 印的，它們的唯一一份格式在 `workmode validate` 那條路上。
@Test func failsWithTheProblemListWhenValidationRejectsTheConfig() throws {
    // desc 是空字串 → `home.desc（要非空字串）`。
    let text = #"{"windows":[],"home":{"desc":"","displays":{"main":"A"}}}"#
    let config = JSONValue.object([
        JSONMember(key: "windows", value: .array([])),
        JSONMember(key: "home", value: .object([
            JSONMember(key: "desc", value: .string("")),
            JSONMember(key: "displays", value: .object([
                JSONMember(key: "main", value: .string("A")),
            ])),
        ])),
    ])
    let files = FakeFileStore(files: [layoutPath: text])
    let reporter = FakeReporter()

    let problems = LayoutValidator.validate(config)
    #expect(!problems.isEmpty, "fixture 選錯了：這份設定其實通得過驗證")
    #expect(throws: LayoutLoadFailure.invalid(problems: problems)) {
        try loader(files, reporter, parse: parser([text: config])).load()
    }
    #expect(reporter.events.isEmpty)
}

/// 成功路徑：回的是**原文**，而且沒有結尾換行（`json=$(cat …)` 已經剝掉檔尾換行，
/// `printf '%s'` 也不補一個）。
@Test func returnsTheRawTextWithoutATrailingNewline() throws {
    let files = FakeFileStore(files: [layoutPath: goodLayoutText])
    let reporter = FakeReporter()

    let loaded = try loader(files, reporter).load()

    #expect(loaded.text == goodLayoutText)
    #expect(!loaded.text.hasSuffix("\n"))
    #expect(loaded.config == goodConfig())
    #expect(reporter.events.isEmpty)
}

/// 檔案有一個換行結尾時（真實的 layout.json 就是這樣）也不能把它帶回來：
/// `$(cat …)` 剝掉的是**全部**尾端換行。
@Test func stripsTheTrailingNewlineTheWayCommandSubstitutionDoes() throws {
    let onDisk = goodLayoutText + "\n"
    let files = FakeFileStore(files: [layoutPath: onDisk])
    let reporter = FakeReporter()

    let loaded = try loader(files, reporter,
                            parse: parser([goodLayoutText: goodConfig()])).load()

    #expect(loaded.text == goodLayoutText)
}

/// workmode.sh:36 的 `jq empty` 失敗。與驗證失敗分開回報：呼叫端印的訊息不同。
@Test func failsWhenTheTextIsNotParsableJSON() {
    let files = FakeFileStore(files: [layoutPath: "not json"])
    let reporter = FakeReporter()

    #expect(throws: LayoutLoadFailure.unparsable(path: layoutPath)) {
        try loader(files, reporter, parse: parser([:])).load()
    }
    #expect(reporter.events.isEmpty)
}

/// 存在但讀不動。bash 那側會靜默通過（cat 失敗 → 空字串 → `jq empty` rc=0），
/// 那是既有的 bug，這裡刻意不複製它——與 `validate` 的兩條已知分歧同一個判斷。
@Test func failsWhenTheFileExistsButCannotBeRead() {
    let files = FakeFileStore(files: [layoutPath: goodLayoutText])
    files.unreadablePaths = [layoutPath]
    let reporter = FakeReporter()

    #expect(throws: LayoutLoadFailure.unreadable(path: layoutPath)) {
        try loader(files, reporter).load()
    }
    #expect(reporter.events.isEmpty)
}

// MARK: - read_state

/// workmode.sh:548。不存在回空字串，**不是**錯誤、也不印任何東西。
@Test func readsAnEmptyStringWhenTheStateFileIsAbsent() {
    let reader = StateReader(files: FakeFileStore(), path: statePath)

    #expect(reader.read() == "")
}

/// 存在就原樣回來（結尾換行留著：`cat` 不剝，剝掉的是命令替換，而狀態檔的
/// 解析靠 `StateFile`，它自己處理空行）。
@Test func readsTheStateFileVerbatim() {
    let content = "location=home\nprofile.home=影音\n"
    let reader = StateReader(files: FakeFileStore(files: [statePath: content]),
                             path: statePath)

    #expect(reader.read() == content)
}

/// 讀不動也是空字串：bash 的 `||` 接的是整個 `[ -f ] && cat`，cat 非零同樣落到
/// `printf ''`。這條與 load_layout 那條的反應相反，正是兩支函式刻意不同的地方。
@Test func readsAnEmptyStringWhenTheStateFileCannotBeRead() {
    let files = FakeFileStore(files: [statePath: "location=home\n"])
    files.unreadablePaths = [statePath]

    #expect(StateReader(files: files, path: statePath).read() == "")
}
