import Testing
import WorkmodeCore
import WorkmodeDomain

// `switch_setting` 的驗收重點不是文法解析，是**訊息先累積不印**（workmode.sh:953-955）：
// 任何一半失敗都會 return 而不寫檔，此時若已經印過「已固定用地點 X」就是在說謊。
// 所以每條失敗路徑都要同時斷言兩件事：那句話沒出現，而且 `writes` 是空的。

private let layoutPath = "/x/layout.json"
private let statePath = "/x/.tatami-state"
private let layoutText = "<layout>"

/// office 有兩個 profile、home 只有一個——「profile 要對照處理完地點之後生效的地點
/// 驗證」那條只有在兩個地點的 profile 清單不同時才驗得到。
private let config = JSONValue.object([
    JSONMember(key: "windows", value: .array([])),
    JSONMember(key: "office", value: .object([
        JSONMember(key: "desc", value: .string("公司")),
        JSONMember(key: "displays", value: .object([
            JSONMember(key: "main", value: .string("OFFICE-UUID")),
        ])),
        JSONMember(key: "profiles", value: .object([
            JSONMember(key: "開發", value: profileBody),
            JSONMember(key: "休閒", value: profileBody),
        ])),
    ])),
    JSONMember(key: "home", value: .object([
        JSONMember(key: "desc", value: .string("家")),
        JSONMember(key: "displays", value: .object([
            JSONMember(key: "main", value: .string("HOME-UUID")),
        ])),
        JSONMember(key: "profiles", value: .object([
            JSONMember(key: "開發", value: profileBody),
        ])),
    ])),
])

/// `validate_layout` 要求每個 profile 都有 `trees`——空物件過不了（實測
/// `workmode validate` 回「缺 trees」）。這個 fixture 的樹不會被走到，
/// 但它必須存在，否則 `load_layout` 會在這些測試碰到 switch 的邏輯之前就失敗。
private let profileBody = JSONValue.object([
    JSONMember(key: "trees", value: .object([])),
])

/// `state_set` 的產物：固定的註解行 ＋ 每筆 `key=value` 各自帶一個換行。
///
/// 測試自己把那個 header 抄成字面字串會變成「抄了兩次同一份東西」，所以從
/// `StateFile.set` 生成——反過來說，這個 helper 驗的是**編排寫進去的是哪些鍵值**，
/// 而那些鍵值的**排版**由 `StateFileTests` 對 bash 差分過。
private func stateText(_ entries: String...) -> String {
    var out = ""
    for entry in entries {
        let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
        out = StateFile.set(out, key: parts[0], value: parts.count > 1 ? parts[1] : "")
    }
    if entries.isEmpty {
        out = StateFile.set("", key: "x", value: "")
    }
    // 與產品碼同一個 `$(…)`：寫進去的是被剝掉結尾換行的那份，adapter 才補回一個。
    while out.hasSuffix("\n") {
        out.removeLast()
    }
    return out
}

/// 接上的螢幕決定 `detect_location` 會選哪個地點。
private func displays(uuid: String) -> JSONValue {
    .array([.object([
        JSONMember(key: "uuid", value: .string(uuid)),
        JSONMember(key: "index", value: .number("1")),
    ])])
}

private struct Scene {
    let run: (String) -> SwitchSetting.Outcome
    let files: FakeFileStore
    let reporter: FakeReporter
    let picker: FakePicker
}

private func harness(state: String = "", connected: String = "HOME-UUID",
                     unwritable: Bool = false,
                     choices: [String?] = []) -> Scene
{
    let yabai = FakeYabai()
    yabai.stubFixed(.displays, displays(uuid: connected))
    let reporter = FakeReporter()

    var seed: [String: String] = [layoutPath: layoutText]
    if !state.isEmpty {
        seed[statePath] = state
    }
    let files = FakeFileStore(files: seed)
    if unwritable {
        files.unwritablePaths = [statePath]
    }

    let picker = FakePicker(choices: choices)
    let subject = SwitchSetting(
        yabai: yabai, files: files, picker: picker,
        layoutPath: layoutPath, statePath: statePath,
        parse: { text in
            if text == layoutText {
                return config
            }
            throw JSONParseError.truncated
        },
        renderRaw: { json in
            if case let .string(text) = json {
                return text
            }
            if case let .number(literal) = json {
                return literal
            }
            return ""
        },
        reporter: reporter
    )
    return Scene(run: { subject.run(argument: $0) },
                 files: files, reporter: reporter, picker: picker)
}

// MARK: - 文法

/// workmode.sh:948-951。只打一個斜線：兩半都空。
@Test func rejectsAnArgumentThatNamesNeitherHalf() {
    let scene = harness()

    #expect(scene.run("/") == .rejected)
    #expect(scene.reporter.events == [.switchArgumentEmpty(argument: "/")])
    #expect(scene.files.writes.isEmpty)
}

/// `${arg%%/*}` 與 `${arg#*/}` 切的是**第一個**斜線，所以 `home/a/b` 的 profile
/// 是 `a/b`（而不是 `b`），於是走 profile 不存在那條。
@Test func splitsOnTheFirstSlashSoALaterSlashStaysInTheProfileName() {
    let scene = harness()

    #expect(scene.run("home/a/b") == .rejected)
    #expect(scene.reporter.events.contains(.switchProfileUnknown(want: "a/b", location: "home",
                                                                 available: "開發")))
    #expect(scene.files.writes.isEmpty)
}

// MARK: - 地點

@Test func pinsAKnownLocation() {
    let scene = harness()

    #expect(scene.run("office") == .updated)
    #expect(scene.files.writes.map(\.contents) == [stateText("location=office")])
    #expect(scene.reporter.events == [.locationPinned(location: "office"),
                                      .switchHintShown])
}

/// workmode.sh:961。`auto` 清掉覆寫，而那句話裡內嵌的 `detect_location` 是在
/// **組訊息時**跑的。
@Test func clearingTheOverrideNamesWhatDetectionWouldPickInstead() {
    let scene = harness(state: "location=office\n")

    #expect(scene.run("auto") == .updated)
    #expect(scene.reporter.events.contains(.locationOverrideCleared(detected: "home")))
}

/// 偵測不出來時那句話裡是字面的「認不出來」，不是空字串。
@Test func clearingTheOverrideSaysSoWhenDetectionCannotName一個地點() {
    let scene = harness(state: "location=office\n", connected: "陌生的螢幕")

    #expect(scene.run("auto") == .updated)
    #expect(scene.reporter.events.contains(.locationOverrideCleared(detected: "認不出來")))
}

@Test func rejectsAnUnknownLocationWithoutTouchingTheStateFile() {
    let scene = harness()

    #expect(scene.run("辦公室") == .rejected)
    #expect(scene.reporter.events == [.switchLocationUnknown(location: "辦公室",
                                                             available: "office home")])
    #expect(scene.files.writes.isEmpty)
}

// MARK: - profile 對照的是「處理完地點之後」的地點

/// 同一個指令裡改地點又指定 profile：`休閒` 只存在於 office，所以這條只有在
/// profile 拿**新**地點去驗證時才會過。
@Test func validatesTheProfileAgainstTheLocationTheSameCommandJustSet() {
    let scene = harness()

    #expect(scene.run("office/休閒") == .updated)
    #expect(scene.reporter.events == [.locationPinned(location: "office"),
                                      .profilePinned(location: "office", profile: "休閒"),
                                      .switchHintShown])
    #expect(scene.files.writes.map(\.contents) == [stateText("location=office", "profile.office=休閒")])
}

/// 反面：同一個 profile 名字在舊地點（home）底下不存在，所以若拿舊地點驗就會被拒。
/// 上一條與這一條合起來才排除「其實根本沒驗」。
@Test func rejectsAProfileThatTheNewLocationDoesNotHave() {
    let scene = harness(state: "location=office\n")

    #expect(scene.run("home/休閒") == .rejected)
    #expect(scene.reporter.events.contains(.switchProfileUnknown(want: "休閒", location: "home",
                                                                 available: "開發")))
    #expect(scene.files.writes.isEmpty)
}

@Test func clearsTheProfileMemoryForTheActiveLocation() {
    let scene = harness(state: "profile.home=開發\n")

    #expect(scene.run("/auto") == .updated)
    #expect(scene.reporter.events == [.profileMemoryCleared(location: "home"),
                                      .switchHintShown])
    #expect(scene.files.writes.map(\.contents) == [stateText()])
}

/// workmode.sh:975-978。只給 profile 而地點認不出來：不知道要記在哪裡。
@Test func refusesToRememberAProfileWhenTheLocationIsUnknown() {
    let scene = harness(connected: "陌生的螢幕")

    #expect(scene.run("/開發") == .rejected)
    #expect(scene.reporter.events.contains(.switchLocationUnresolved))
    #expect(scene.files.writes.isEmpty)
}

// MARK: - 寫檔失敗（這一組是這支函式存在的理由）

/// 寫不進去時那四句累積的訊息**一句都不能出現**——它們宣稱狀態檔已經改了。
@Test func saysNothingItCannotBackUpWhenTheStateFileCannotBeWritten() {
    let scene = harness(unwritable: true)

    #expect(scene.run("office/休閒") == .rejected)
    #expect(scene.reporter.events == [.stateFileUnwritable(path: statePath)])
    #expect(!scene.reporter.events.contains(.locationPinned(location: "office")))
    #expect(!scene.reporter.events.contains(.switchHintShown))
    #expect(scene.files.writes.isEmpty)
}

// MARK: - 選單（switch_interactive）

/// workmode.sh:1016-1020。沒有 fzf 是兩句，不是一句。
@Test func fallsBackToTheFlagSyntaxWhenThePickerIsMissing() {
    let scene = harness()
    scene.picker.isAvailable = false

    #expect(scene.run("") == .rejected)
    #expect(scene.reporter.events == [.pickerMissing,
                                      .pickerFallbackLocations(available: "office home")])
    #expect(scene.files.writes.isEmpty)
}

/// 兩段選單各自的內容：地點那段濾掉 `windows`、標出目前的地點、末尾補一行 auto。
@Test func offersEveryLocationExceptTheSharedCatalogAndMarksTheCurrentOne() {
    let scene = harness(state: "profile.home=開發\n",
                        choices: ["home\t家  ←目前", "開發\t←記住的"])

    #expect(scene.run("") == .updated)
    #expect(scene.picker.prompts.first?.prompt == "地點 > ")
    #expect(scene.picker.prompts.first?.lines == ["office\t公司",
                                                  "home\t家  ←目前",
                                                  "auto\t自動偵測（清除地點覆寫）"])
    #expect(scene.picker.prompts.last?.prompt == "profile（home） > ")
    #expect(scene.picker.prompts.last?.lines == ["開發\t←記住的",
                                                 "auto\t清除記憶，改用 default"])
}

/// workmode.sh:1035-1043。選了 auto 之後 profile 要記在**偵測出來**的地點上，
/// 所以第二段選單問的是那個地點的 profile。
@Test func remembersTheProfileAgainstTheDetectedLocationAfterChoosingAuto() {
    let scene = harness(connected: "OFFICE-UUID",
                        choices: ["auto\t自動偵測（清除地點覆寫）",
                                  "休閒\t"])

    #expect(scene.run("") == .updated)
    #expect(scene.picker.prompts.last?.prompt == "profile（office） > ")
    // 地點那半仍然是 `auto`（清掉覆寫），profile 記在 office 底下。
    #expect(scene.files.writes.map(\.contents) == [stateText("profile.office=休閒")])
}

/// 選了 auto 但偵測不出來：bash 在這裡**不問 profile**，直接 `switch_setting auto`。
@Test func skipsTheProfileMenuWhenAutoCannotBeResolved() {
    let scene = harness(
        connected: "陌生的螢幕", choices: ["auto\t自動偵測（清除地點覆寫）"]
    )

    #expect(scene.run("") == .updated)
    #expect(scene.picker.prompts.count == 1)
    #expect(scene.reporter.events.contains(.pickerLocationUnresolvedAfterAuto))
    #expect(scene.files.writes.map(\.contents) == [stateText()])
}

/// fzf 回非零＝使用者取消：什麼都不寫。
@Test func writesNothingWhenTheUserCancelsTheFirstMenu() {
    let scene = harness(choices: [nil])

    #expect(scene.run("") == .rejected)
    #expect(scene.files.writes.isEmpty)
}

@Test func writesNothingWhenTheUserCancelsTheSecondMenu() {
    let scene = harness(choices: ["home\t家", nil])

    #expect(scene.run("") == .rejected)
    #expect(scene.files.writes.isEmpty)
}
