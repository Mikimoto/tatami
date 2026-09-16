import Testing
import WorkmodeCore
import WorkmodeDomain

// `save_layout` 是整個移植裡**唯一會覆寫使用者設定檔**的東西，所以這一組的形狀是：
// 每一條不成功的路徑都同時斷言「事件對了」與 `files.writes.isEmpty`。
// 只驗事件的話，一個在錯誤路徑上照樣寫檔的 bug 會完全沒有訊號。

let saveLayoutPath = "/x/layout.json"
let saveStatePath = "/x/.tatami-state"
let saveLayoutText = "<layout>"

// MARK: - 寫檔之前的每一道關卡

/// workmode.sh:1070。這個守衛在**最前面**：沒有 tty 時互動不是失敗而是無聲卡住。
@Test func refusesWithoutAControllingTerminalBeforeReadingAnything() {
    let scene = harness(hasTTY: false)

    #expect(scene.run("") == .needsTerminal)
    #expect(scene.reporter.events == [.saveNeedsTerminal])
    #expect(scene.terminal.readCount == 0)
    #expect(scene.files.writes.isEmpty)
}

/// workmode.sh:1094。`auto` 是 --switch 的保留字，擋在問名字**之前**——
/// 不擋的話使用者會先被問完一輪，最後才在驗證那步被打回票。
@Test func rejectsTheReservedProfileNameBeforeAskingAnything() {
    let scene = harness()

    #expect(scene.run("auto") == .rejected)
    #expect(scene.reporter.events == [.saveProfileNameReserved])
    #expect(scene.terminal.readCount == 0)
    #expect(scene.files.writes.isEmpty)
}

/// workmode.sh:1095。同樣擋在問名字之前。
@Test func rejectsAProfileNameWithWhitespaceBeforeAskingAnything() {
    let scene = harness()

    #expect(scene.run("有 空白") == .rejected)
    #expect(scene.reporter.events == [.saveProfileNameHasSpace(profile: "有 空白")])
    #expect(scene.terminal.readCount == 0)
    #expect(scene.files.writes.isEmpty)
}

/// workmode.sh:1144。畫面上沒有可以存的東西。
@Test func rejectsWhenNoWindowOnAnyScreenCanBeStored() {
    let scene = harness(windows: [])

    #expect(scene.run("新的") == .rejected)
    #expect(scene.reporter.events.contains(.saveNothingToStore))
    #expect(scene.files.writes.isEmpty)
}

/// workmode.sh:1132。space 不可見時**沿用舊設定**而不是失敗——不可見 space 的
/// frame 停在上次套用的值，拿它存等於把舊資料當成現況寫回去。
@Test func keepsTheOldTreeForARoleWhoseSpaceIsNotVisible() {
    let invisible = JSONValue.array([
        .object([
            JSONMember(key: "display", value: .number("1")),
            JSONMember(key: "index", value: .number("1")),
            JSONMember(key: "is-visible", value: .bool(false)),
        ]),
    ])
    let scene = harness(spaces: invisible)

    #expect(scene.run("新的") == .rejected)
    #expect(scene.reporter.events.contains(.saveRoleHasNoVisibleSpace(role: "main")))
    #expect(scene.files.writes.isEmpty)
}

/// workmode.sh:1118。接上但沒宣告在這個地點的螢幕：講出來，不要靜默略過。
@Test func namesAConnectedScreenThatTheLocationDoesNotDeclare() {
    let two = JSONValue.array([
        .object([
            JSONMember(key: "uuid", value: .string("HOME-UUID")),
            JSONMember(key: "index", value: .number("1")),
        ]),
        .object([
            JSONMember(key: "uuid", value: .string("陌生的")),
            JSONMember(key: "index", value: .number("2")),
        ]),
    ])
    let scene = harness(answers: ["-"], displays: two)

    _ = scene.run("新的")
    #expect(scene.reporter.events.contains(.saveDisplayNotInLayout(uuid: "陌生的")))
    #expect(!scene.reporter.events.contains(.saveDisplayNotInLayout(uuid: "HOME-UUID")))
}

// MARK: - 問名字

/// `-` ＝ 不存這個視窗。全部都 `-` 的話沒有任何有名字的視窗，於是不寫檔。
@Test func skippingEveryWindowLeavesNothingToStore() {
    let scene = harness(answers: ["-"])

    #expect(scene.run("新的") == .rejected)
    #expect(scene.reporter.events.contains(.saveRoleHasNoNamedWindow(role: "main")))
    #expect(scene.reporter.events.contains(.saveNoTreeStored))
    #expect(scene.files.writes.isEmpty)
}

/// 空的回答 ＝ 用 app 名當 label（提示字裡的 `Enter=%s`）。
@Test func anEmptyAnswerTakesTheAppNameAsTheLabel() {
    let scene = harness(answers: [""])

    #expect(scene.run("新的") == .written(path: saveLayoutPath))
    #expect(scene.reporter.events.contains(.saveLabelPrompt(app: "Zed")))
    #expect(scene.files.writes.map(\.path) == [saveLayoutPath])
}

/// workmode.sh:1167。label 不能含 tab（總表是 TSV），而且**重問**而不是放棄。
@Test func asksAgainWhenTheLabelContainsATab() {
    let scene = harness(answers: ["a\tb", "好名字"])

    #expect(scene.run("新的") == .written(path: saveLayoutPath))
    #expect(scene.reporter.events.contains(.saveLabelHasTab))
    #expect(scene.terminal.readCount == 2)
}

/// workmode.sh:1171。名字撞到總表裡既有的，也是重問。
@Test func asksAgainWhenTheLabelIsAlreadyTaken() {
    let scene = harness(answers: ["Code", "另一個"])

    #expect(scene.run("新的") == .written(path: saveLayoutPath))
    #expect(scene.reporter.events.contains(.saveLabelTaken(label: "Code")))
    #expect(scene.terminal.readCount == 2)
}

/// 同一輪裡兩個視窗取同一個名字：第二個要被擋下來，不能只擋既有總表。
@Test func asksAgainWhenTheLabelWasJustUsedInThisSameRun() {
    let two = [window(id: "7", app: "Zed", title: "左", originX: 0, width: 100),
               window(id: "8", app: "Neovide", title: "右", originX: 100, width: 100)]
    let scene = harness(windows: two, answers: ["同名", "同名", "不同名"])

    _ = scene.run("新的")
    #expect(scene.reporter.events.contains(.saveLabelTaken(label: "同名")))
}

/// workmode.sh:1180-1183。同一個 app 有多個視窗時規則退到標題逐字比對，
/// 而那件事要講出來——標題一變就認不出來。
@Test func warnsThatATitleRuleIsExactWhenOneAppHasSeveralWindows() {
    let two = [window(id: "7", app: "Zed", title: "左", originX: 0, width: 100),
               window(id: "8", app: "Zed", title: "右", originX: 100, width: 100)]
    let scene = harness(windows: two, answers: ["甲", "乙"])

    _ = scene.run("新的")
    #expect(scene.reporter.events.contains(.saveTitleRuleIsExact(pattern: "左")))
    #expect(scene.reporter.events.contains(.saveTitleRuleIsExact(pattern: "右")))
}

// MARK: - 覆寫確認

/// workmode.sh:1232-1241。profile 已存在時要問，而「不」是 **rc=0**，不是失敗。
@Test func askingBeforeOverwritingAnExistingProfileAndTakingNoForAnAnswer() {
    let scene = harness(answers: ["新視窗", "n"])

    #expect(scene.run("開發") == .cancelled)
    #expect(scene.reporter.events.contains(.saveOverwritePrompt(profile: "開發")))
    #expect(scene.reporter.events.contains(.saveCancelled))
    #expect(scene.files.writes.isEmpty)
}

/// 只有 `y`／`Y` 算同意；其餘（含直接 Enter）都是取消。
@Test func onlyYMeansYes() {
    for answer in ["Y", "y"] {
        let scene = harness(answers: ["新視窗", answer])
        #expect(scene.run("開發") == .written(path: saveLayoutPath))
        #expect(scene.files.writes.count == 1)
    }
    for answer in ["yes", "", "是"] {
        let scene = harness(answers: ["新視窗", answer])
        #expect(scene.run("開發") == .cancelled)
        #expect(scene.files.writes.isEmpty)
    }
}

/// 新的 profile 不問——沒有東西會被蓋掉。
@Test func doesNotAskWhenTheProfileIsNew() {
    let scene = harness(answers: ["新視窗"])

    #expect(scene.run("全新的") == .written(path: saveLayoutPath))
    #expect(!scene.reporter.events.contains(where: {
        if case .save(.writing(.saveOverwritePrompt)) = $0 {
            return true
        }
        return false
    }))
    #expect(scene.files.writes.count == 1)
}

// MARK: - 寫檔

/// 走的必須是**原子**那條（暫存檔換上去），不是直接覆寫：中途失敗不能留下半份設定。
@Test func writesThroughTheAtomicPathSoAHalfWrittenConfigCannotSurvive() {
    let scene = harness(answers: ["新視窗"])

    #expect(scene.run("全新的") == .written(path: saveLayoutPath))
    #expect(scene.files.writes.map(\.atomic) == [true])
    #expect(scene.reporter.events.contains(.saveWritten(path: saveLayoutPath)))
}

/// **沒動的 space 要講出來。** `--save` 只量得準目前可見的那幾個：不可見的 space
/// 上，yabai 更新樹但不套 frame（實測 2026-08-30），而這支是量 frame 再反推成樹。
/// 不說的話使用者會以為整個 profile 都存了。
///
/// 這一輪寫的是 `main` 底下的 `SPACE-A`（fixture 裡唯一可見的那個），所以 `SPACE-B`
/// 與 `SPACE-C` 沒動＝ 2。
@Test func saysHowManySpacesItDidNotTouch() {
    let scene = harness(config: config(otherSpaces: ["SPACE-B", "SPACE-C"]),
                        answers: ["新視窗", "y"])

    #expect(scene.run("開發") == .written(path: saveLayoutPath))
    #expect(scene.reporter.events.contains(.saveSkippedInvisibleSpaces(count: 2)))
}

/// **沒有東西沒動就不必說。** count 為 0 時不發——每次存檔都印一句「另外 0 個」
/// 是雜訊，而雜訊會讓真的有東西沒動的那次被略過。
@Test func staysQuietWhenEverySpaceWasTouched() {
    let scene = harness(answers: ["新視窗"])

    #expect(scene.run("全新的") == .written(path: saveLayoutPath))
    #expect(!scene.reporter.events.contains(where: {
        if case .save(.writing(.saveSkippedInvisibleSpaces)) = $0 {
            return true
        }
        return false
    }))
}

/// 同一個 uuid 再存一次不算「沒動」——它就是這一輪重新量的那個。
/// 少了這條，把 `untouchedSpaceCount` 寫成「舊的有幾個」也會過上面那兩條。
@Test func theSpaceItJustRewroteDoesNotCountAsUntouched() {
    let scene = harness(config: config(otherSpaces: ["SPACE-A"]), answers: ["新視窗", "y"])

    #expect(scene.run("開發") == .written(path: saveLayoutPath))
    #expect(!scene.reporter.events.contains(where: {
        if case .save(.writing(.saveSkippedInvisibleSpaces)) = $0 {
            return true
        }
        return false
    }))
}

/// workmode.sh:1247-1250。寫不進去時原檔沒有動。
@Test func saysTheOriginalIsUntouchedWhenTheWriteFails() {
    let scene = harness(answers: ["新視窗"])
    scene.files.unwritablePaths = [saveLayoutPath]

    #expect(scene.run("全新的") == .rejected)
    #expect(scene.reporter.events.contains(.saveWriteFailed))
    #expect(scene.files.writes.isEmpty)
    #expect(!scene.reporter.events.contains(.saveWritten(path: saveLayoutPath)))
}
