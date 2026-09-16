import Testing
import WorkmodeEditorControl
import WorkmodeEditorModel

// 四種「沒有清單」各走各的路。這一層的價值就是分辨，所以四條都要在。

private let layout = """
{"home":{"desc":"家","displays":{"main":"UUID-A","DELL":"UUID-B","ASUS":""},\
"profiles":{"開發":{"trees":{"main":{"window":"Zed"}}}}}}
"""

private let liveDisplays = [
    DisplayChoice(uuid: "UUID-A", index: 1, name: "CHIMEI", size: nil),
    DisplayChoice(uuid: "UUID-B", index: 2, name: "DELL", size: nil),
]

private let liveSpaces = [
    LiveSpace(uuid: "S-1", index: 1, display: 1, visible: true),
    LiveSpace(uuid: "S-2", index: 2, display: 1, visible: false),
    LiveSpace(uuid: "S-7", index: 7, display: 2, visible: true),
]

private func makeController(displays: (() -> [DisplayChoice])?,
                            spaces: (() -> [LiveSpace])?) throws -> EditorController
{
    let controller = EditorController(files: ReadOnlyStore(text: layout + "\n"),
                                      layoutPath: "/tmp/space-lookup-test.json",
                                      displays: displays,
                                      spaces: spaces)
    try controller.load()
    return controller
}

/// 正常路徑：角色的 uuid 對到 display 1，就只拿得到 display 1 的兩個。
@Test func aWiredRoleGetsItsOwnDisplaysSpaces() throws {
    let controller = try makeController(displays: { liveDisplays }, spaces: { liveSpaces })
    let options = controller.spaceOptions(displayUUID: "UUID-A", treed: [])
    guard case let .ready(list) = options else {
        Issue.record("不是 ready：\(options)"); return
    }
    #expect(list.map(\.uuid) == ["S-1", "S-2"])
}

/// 正控制：換一個角色要拿到別的清單，長度也不同。
@Test func anotherRoleGetsAnotherDisplay() throws {
    let controller = try makeController(displays: { liveDisplays }, spaces: { liveSpaces })
    guard case let .ready(list) = controller.spaceOptions(displayUUID: "UUID-B", treed: []) else {
        Issue.record("不是 ready"); return
    }
    #expect(list.map(\.uuid) == ["S-7"])
}

/// 沒接上 yabai：兩個 closure 都是 nil。**不能說「螢幕沒接上」**，我們根本沒問到。
@Test func withoutYabaiWeSayWeCouldNotAsk() throws {
    let controller = try makeController(displays: nil, spaces: nil)
    #expect(controller.spaceOptions(displayUUID: "UUID-A", treed: []) == .yabaiUnavailable)
}

/// **空字串的 uuid 是「還沒指定」不是「沒接上」。** 新增地點時 `main` 的 uuid 就是
/// 空的，判成「螢幕沒接上」會叫使用者去插一條根本還沒選好的線。
@Test func anEmptyUUIDMeansNoDisplayHasBeenChosen() throws {
    let controller = try makeController(displays: { liveDisplays }, spaces: { liveSpaces })
    #expect(controller.spaceOptions(displayUUID: "", treed: []) == .noDisplayAssigned)
    #expect(controller.spaceOptions(displayUUID: nil, treed: []) == .noDisplayAssigned)
}

/// 有 uuid 但不在現場清單裡：那台真的沒接上（例如在家編 office 的角色）。
@Test func aUUIDThatIsNotPluggedInSaysSo() throws {
    let controller = try makeController(displays: { liveDisplays }, spaces: { liveSpaces })
    #expect(controller.spaceOptions(displayUUID: "UUID-GONE", treed: []) == .displayNotConnected)
}

/// 已經有樹的仍然標記得到——過濾沒有把 `treed` 那條路徑吃掉。
///
/// 鑑別力在**兩個**：`S-2` 有樹、`S-1` 沒有。只斷言有樹的那一個時，
/// 「一律 true」與正確的實作分不出來。
@Test func theHasTreeMarkerStillComesThrough() throws {
    let controller = try makeController(displays: { liveDisplays }, spaces: { liveSpaces })
    guard case let .ready(list) = controller.spaceOptions(displayUUID: "UUID-A",
                                                          treed: ["S-2"])
    else {
        Issue.record("不是 ready"); return
    }
    #expect(list.first { $0.uuid == "S-2" }?.hasTree == true)
    #expect(list.first { $0.uuid == "S-1" }?.hasTree == false)
}
