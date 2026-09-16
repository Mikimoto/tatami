import Testing
import WorkmodeCore
import WorkmodeDomain

// FrameLayout：葉矩形 → moveToSpace → setFrame → 比對。斷言打在 fake 的呼叫紀錄與事件，
// 回傳值在「什麼都沒做」與「做對了」都一樣。

private let screen = FrameLayout.Canvas(
    frame: Rect(originX: 0, originY: 0, width: 1000, height: 500), rawTop: 0
)
private let twoLeaves = JSONValue.object([
    JSONMember(key: "axis", value: .string("vertical")),
    JSONMember(key: "children", value: .array([
        .object([JSONMember(key: "window", value: .string("A")),
                 JSONMember(key: "ratio", value: .number("0.75"))]),
        .object([JSONMember(key: "window", value: .string("B")),
                 JSONMember(key: "ratio", value: .number("0.25"))]),
    ])),
])
/// `resolve_rules` 的輸出：每行 `<label>\t<id>`。
private let map = "A\t7\nB\t8\n"

/// 四個東西一組（swiftlint 的 `large_tuple` 上限是 2，所以不能用 tuple）。
private struct Scene {
    let subject: FrameLayout
    let yabai: FakeYabai
    let server: FakeWindowServer
    let reporter: FakeReporter
}

private func harness() -> Scene {
    let yabai = FakeYabai(), server = FakeWindowServer(), reporter = FakeReporter()
    return Scene(subject: FrameLayout(yabai: yabai, server: server, reporter: reporter),
                 yabai: yabai, server: server, reporter: reporter)
}

/// 每個葉：先搬到那個 space，再設 frame。鑑別值：兩個 frame 是 750／250 寬。
@Test func eachLeafIsMovedThenFramed() {
    let scene = harness()
    #expect(scene.subject.layout(space: "2", tree: twoLeaves, in: screen, map: map) != nil)
    #expect(scene.yabai.commandArgv == [["window", "7", "--space", "2"], ["window", "8", "--space", "2"]])
    #expect(scene.server.calls == [
        .init(window: "7", frame: Rect(originX: 0, originY: 0, width: 750, height: 500)),
        .init(window: "8", frame: Rect(originX: 750, originY: 0, width: 250, height: 500)),
    ])
    #expect(scene.reporter.events.isEmpty)
}

/// app 夾了 frame → 說出來，帶要求的與實際的。
@Test func aClampedFrameIsReported() {
    let scene = harness()
    let clamped = Rect(originX: 0, originY: 0, width: 750, height: 465)
    scene.server.actual["7"] = clamped
    _ = scene.subject.layout(space: "2", tree: twoLeaves, in: screen, map: map)
    #expect(scene.reporter.events == [.space(.frameRejected(
        label: "A", wanted: Rect(originX: 0, originY: 0, width: 750, height: 500), actual: clamped
    ))])
}

/// 差在 1pt 以內不算拒絕：AX 回來的座標常有半點的誤差。鑑別值：0.5。
@Test func halfAPointOfDriftIsNotARejection() {
    let scene = harness()
    scene.server.actual["7"] = Rect(originX: 0.5, originY: 0, width: 750, height: 500)
    _ = scene.subject.layout(space: "2", tree: twoLeaves, in: screen, map: map)
    #expect(scene.reporter.events.isEmpty)
}

/// 一個視窗設不下去不擋下一個：B 照樣被設。actual 是 nil。
@Test func anUnresponsiveWindowDoesNotStopTheRest() {
    let scene = harness()
    scene.server.failing = ["7"]
    _ = scene.subject.layout(space: "2", tree: twoLeaves, in: screen, map: map)
    #expect(scene.server.calls.map(\.window) == ["7", "8"])
    #expect(scene.reporter.events == [.space(.frameRejected(
        label: "A", wanted: Rect(originX: 0, originY: 0, width: 750, height: 500), actual: nil
    ))])
}

/// 樹壞掉回 false 且一個命令都不下——呼叫端拿它去發 spaceHasNoTree。
@Test func aMalformedTreeDoesNothing() {
    let scene = harness()
    #expect(scene.subject.layout(space: "2", tree: .object([]), in: screen, map: map) == nil)
    #expect(scene.yabai.commandArgv.isEmpty)
    #expect(scene.server.calls.isEmpty)
}
