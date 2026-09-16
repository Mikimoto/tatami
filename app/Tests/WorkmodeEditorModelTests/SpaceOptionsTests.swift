import Testing
@testable import WorkmodeEditorModel

// 分頁列空掉有四個成因，而它們在畫面上長得一模一樣。這個型別存在的理由就是把
// 它們分開——與 `spaceStatusText`（`YabaircSpaceEdit.swift`）對「清單是空的」與
// 「這個編號不存在」同一條：不分辨的話會誣賴使用者的設定。

/// 有清單的時候不出聲——多一句話在正常路徑上只是雜訊。
@Test func aReadyListHasNothingToExplain() {
    let choice = SpaceChoice(uuid: "U-1", index: 1, displayIndex: 1,
                             isVisible: true, hasTree: false)
    #expect(SpaceOptions.ready([choice]).note == nil)
    #expect(SpaceOptions.ready([]).note == nil)
}

/// 三種「沒有清單」各說各的，而且**三句都不一樣**——共用一句的話，
/// 「還沒指定螢幕」與「螢幕沒接上」會叫使用者去修錯的地方。
@Test func eachEmptyReasonSaysSomethingDifferent() {
    let notes = [
        SpaceOptions.yabaiUnavailable.note,
        SpaceOptions.noDisplayAssigned.note,
        SpaceOptions.displayNotConnected.note,
    ]
    #expect(notes.allSatisfy { $0 != nil && !($0 ?? "").isEmpty })
    #expect(Set(notes.compactMap(\.self)).count == 3, "三種成因共用了同一句話")
}

/// 句子要講得出**是哪一種**，不是「查不到」了事。這裡釘關鍵詞而不是整句，
/// 措辭之後還會調；關鍵詞消失就代表那句話不再指向那個成因。
@Test func theNotesNameTheThingThatIsMissing() {
    #expect(SpaceOptions.yabaiUnavailable.note?.contains("yabai") == true)
    #expect(SpaceOptions.noDisplayAssigned.note?.contains("還沒指定螢幕") == true)
    #expect(SpaceOptions.displayNotConnected.note?.contains("沒接上") == true)
}

/// `ready` 帶得動清單本身。
@Test func readyCarriesTheChoices() {
    let choice = SpaceChoice(uuid: "U-1", index: 1, displayIndex: 1,
                             isVisible: true, hasTree: false)
    guard case let .ready(list) = SpaceOptions.ready([choice]) else {
        Issue.record("不是 ready"); return
    }
    #expect(list.map(\.uuid) == ["U-1"])
}
