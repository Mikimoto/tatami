import Testing
@testable import WorkmodeEditorModel

// 分頁列上的 space 清單：yabai 那份、濾到這個角色的螢幕、再標出「哪些已經有樹」。

/// **每台螢幕的 space 數量刻意不同**（1→3 筆、2→1 筆、3→2 筆），順序也是亂的，
/// 而且同一台螢幕的 index 不連續。
///
/// 下面的斷言比的是**完整的 uuid 清單**，所以數量相同其實也分得出「濾錯台」——
/// 數量不同買到的是讀報告的人一眼看得出差別，以及萬一有人把斷言鬆成 `count`
/// 時它仍然有牙齒。（原本這裡寫「數量一樣就沒有鑑別力」，那對現在這幾條斷言為假，
/// 2026-08-29 由 fresh-context review 指出。）
private let live = [
    LiveSpace(uuid: "U-9", index: 9, display: 3, visible: true),
    LiveSpace(uuid: "U-2", index: 2, display: 1, visible: false),
    LiveSpace(uuid: "U-1", index: 1, display: 1, visible: true),
    LiveSpace(uuid: "U-6", index: 6, display: 2, visible: true),
    LiveSpace(uuid: "U-8", index: 8, display: 3, visible: false),
    LiveSpace(uuid: "U-5", index: 5, display: 1, visible: false),
]

/// 只留這台螢幕的。別台的 space 上畫的樹**永遠不會生效**——`workmode --space`
/// 只套「這台螢幕現在可見的那個 space」，屬於別台的 uuid 一輩子不會被走到，
/// 而畫面上沒有任何訊號。
@Test func onlyTheSpacesOnThatDisplaySurvive() {
    #expect(SpaceChoice.merge(live, treed: [], onDisplay: 1).map(\.uuid) == ["U-1", "U-2", "U-5"])
}

/// 正控制：換一台螢幕要得到**不同的**子集，而且長度也不同。
@Test func aDifferentDisplayGivesADifferentSubset() {
    #expect(SpaceChoice.merge(live, treed: [], onDisplay: 2).map(\.uuid) == ["U-6"])
    #expect(SpaceChoice.merge(live, treed: [], onDisplay: 3).map(\.uuid) == ["U-8", "U-9"])
}

/// 沒有 space 的螢幕編號回空陣列——不是回全部。
@Test func anUnknownDisplayGivesNothing() {
    #expect(SpaceChoice.merge(live, treed: [], onDisplay: 99).isEmpty)
}

/// 排序照 index。yabai 回的順序是它自己的（實測不連續也沒排序過），
/// 照抄會讓清單看起來是亂的。fixture 裡 display 1 的三筆來源順序是 2、1、5。
@Test func theChoicesAreSortedByIndex() {
    #expect(SpaceChoice.merge(live, treed: [], onDisplay: 1).map(\.index) == [1, 2, 5])
}

/// 已經有樹的**標記出來，不濾掉**：分頁列要列出這台螢幕上的每一個 space，
/// 有沒有畫過只是外觀的差別。
///
/// 鑑別力在**兩個**：`U-2` 有樹、`U-1` 沒有。只斷言有樹的那一個時，
/// 「一律 true」與正確的實作分不出來。
@Test func aSpaceThatAlreadyHasATreeIsMarked() {
    let list = SpaceChoice.merge(live, treed: ["U-2"], onDisplay: 1)
    #expect(list.count == 3, "有樹的不該從清單裡消失")
    #expect(list.first { $0.uuid == "U-2" }?.hasTree == true)
    #expect(list.first { $0.uuid == "U-1" }?.hasTree == false)
}

/// 別台螢幕上的樹不會沾到這一台——`treed` 是整個角色的，而角色只對一台螢幕。
@Test func aTreeFromAnotherDisplayDoesNotLeakIn() {
    let list = SpaceChoice.merge(live, treed: ["U-6"], onDisplay: 1)
    #expect(list.allSatisfy { !$0.hasTree })
}

/// 其餘欄位原樣帶過去——`isVisible` 是使用者唯一分得出「哪個是我現在看的」的線索。
@Test func theChoiceCarriesWhatTheUserNeedsToTellThemApart() {
    let list = SpaceChoice.merge(live, treed: [], onDisplay: 1)
    #expect(list[0].index == 1)
    #expect(list[0].displayIndex == 1)
    #expect(list[0].isVisible)
    #expect(!list[1].isVisible)
}
