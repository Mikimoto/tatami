import Testing
import WorkmodeCore
import WorkmodeDomain

// 這一組守的是那條回退：狀態檔寫壞了只該換掉這一次的地點來源，不該讓整支腳本停擺。

/// 兩個地點，各自有 desc 與 displays.main。
private func config(homeDesc: JSONValue = .string("家")) -> JSONValue {
    .object([
        JSONMember(key: "home", value: .object([
            JSONMember(key: "desc", value: homeDesc),
            JSONMember(key: "displays", value: .object([
                JSONMember(key: "main", value: .string("HOME-UUID")),
            ])),
        ])),
        JSONMember(key: "office", value: .object([
            JSONMember(key: "desc", value: .string("辦公室")),
            JSONMember(key: "displays", value: .object([
                JSONMember(key: "main", value: .string("OFFICE-UUID")),
            ])),
        ])),
    ])
}

/// `yabai -m query --displays` 的回應：只有 uuid 有用（`detect_location` 只取它）。
private func displays(_ uuids: [String]) -> JSONValue {
    .array(uuids.map { .object([JSONMember(key: "uuid", value: .string($0))]) })
}

@Test func takesTheStateFileOverrideWhenThatLocationExists() {
    let yabai = FakeYabai()
    let reporter = FakeReporter()

    let resolved = ActiveLocation(yabai: yabai, reporter: reporter)
        .resolve(state: "location=office\n", config: config())

    #expect(resolved == ActiveLocation.Resolved(location: "office", source: .override))
    #expect(reporter.events.isEmpty)
    // 命中覆寫時**不問 yabai**：detect 是回退，不是每次都算的東西。
    #expect(yabai.allArgv.isEmpty)
}

/// workmode.sh:568-571。覆寫指到不存在的地點 → 警告（stderr）後回退偵測。
/// 這條是這一支唯一的分支，也是 mutation 要打的地方。
@Test func warnsAndFallsBackToDetectionWhenTheOverrideIsUnknown() {
    let yabai = FakeYabai()
    yabai.stubFixed(.displays, displays(["OFFICE-UUID"]))
    let reporter = FakeReporter()

    let resolved = ActiveLocation(yabai: yabai, reporter: reporter)
        .resolve(state: "location=火星\n", config: config())

    #expect(resolved == ActiveLocation.Resolved(location: "office", source: .detect))
    #expect(reporter.events == [.stateLocationNotInLayout(location: "火星")])
    #expect(reporter.events(on: .stderr).count == 1, "這句警告必須走 stderr")
    #expect(reporter.events(on: .stdout).isEmpty)
}

/// `desc` 是空字串時 `location_desc` 印一個換行、命令替換剝成空字串、`-n` 為假——
/// 所以**存在的地點也會被判成不在 layout.json 裡**。照抄那個行為。
@Test func treatsAnEmptyDescriptionAsAnUnknownLocation() {
    let yabai = FakeYabai()
    yabai.stubFixed(.displays, displays(["HOME-UUID"]))
    let reporter = FakeReporter()

    let resolved = ActiveLocation(yabai: yabai, reporter: reporter)
        .resolve(state: "location=home\n", config: config(homeDesc: .string("")))

    #expect(resolved == ActiveLocation.Resolved(location: "home", source: .detect))
    #expect(reporter.events == [.stateLocationNotInLayout(location: "home")])
}

@Test func detectsTheLocationWhenTheStateFileHasNoOverride() {
    let yabai = FakeYabai()
    yabai.stubFixed(.displays, displays(["X", "HOME-UUID"]))
    let reporter = FakeReporter()

    let resolved = ActiveLocation(yabai: yabai, reporter: reporter)
        .resolve(state: "profile.home=影音\n", config: config())

    #expect(resolved == ActiveLocation.Resolved(location: "home", source: .detect))
    #expect(reporter.events.isEmpty)
}

/// 兩者皆無 ＝ bash 的 `return 1`。接的螢幕與任何地點的 main 都不符。
@Test func returnsNothingWhenNeitherOverrideNorDetectionYieldsALocation() {
    let yabai = FakeYabai()
    yabai.stubFixed(.displays, displays(["UNKNOWN-UUID"]))
    let reporter = FakeReporter()

    let resolved = ActiveLocation(yabai: yabai, reporter: reporter)
        .resolve(state: "", config: config())

    #expect(resolved == nil)
    #expect(reporter.events.isEmpty)
}
