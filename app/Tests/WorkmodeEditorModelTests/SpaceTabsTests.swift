import Testing
import WorkmodeDomain
@testable import WorkmodeEditorModel

// 分頁列 = **yabai 現在查得到的 space** ∪ `spaceTrees` 已經有的 uuid。
// 兩邊都要：只看 yabai 的話，被 macOS 刪掉的 space 留下的樹會從畫面上消失而檔案裡
// 還在（`validate` 照樣檢查它、照樣擋 ⌘S）；只看 `spaceTrees` 的話，還沒畫過的
// space 就沒有分頁可以拖東西進去。

private let doc = LayoutDocument(root: .object([
    JSONMember(key: "home", value: .object([
        JSONMember(key: "profiles", value: .object([
            JSONMember(key: "開發", value: .object([
                JSONMember(key: "spaceTrees", value: .object([
                    JSONMember(key: "main", value: .object([
                        JSONMember(key: "U-1", value: .object([
                            JSONMember(key: "window", value: .string("Code")),
                        ])),
                        JSONMember(key: "U-孤兒", value: .object([
                            JSONMember(key: "window", value: .string("Chat")),
                        ])),
                    ])),
                ])),
            ])),
        ])),
    ])),
]))

private func live(_ pairs: [(String, Int)]) -> [LiveSpace] {
    pairs.map { LiveSpace(uuid: $0.0, index: $0.1, display: 1, visible: false) }
}

/// yabai 有的照 yabai 的順序，有沒有樹都列。
@Test func everyLiveSpaceGetsATab() {
    let tabs = doc.spaceTabs(location: "home", profile: "開發", role: "main",
                             live: live([("U-1", 1), ("U-2", 2)]))
    #expect(tabs.map(\.space) == ["U-1", "U-2", "U-孤兒"])
    #expect(tabs.map(\.index) == [1, 2, nil])
    #expect(tabs.map(\.hasTree) == [true, false, true])
}

/// **孤兒接在後面。** `spaceTrees` 裡有、yabai 查不到的 uuid ＝ 那個 space 被 macOS
/// 刪掉了。不列出來等於在畫面上把那棵樹刪掉，而檔案裡還在。
/// 鑑別力：拿掉「∪ spaceTrees」那半，這條的 `U-孤兒` 就不見了。
@Test func anOrphanTreeStillGetsATab() {
    let tabs = doc.spaceTabs(location: "home", profile: "開發", role: "main",
                             live: live([("U-1", 1)]))
    #expect(tabs.map(\.space) == ["U-1", "U-孤兒"])
    // index 是 nil ＝ yabai 查不到它，UI 據此標橘字。
    #expect(tabs.last?.index == nil)
}

/// 沒接上 yabai：只剩 `spaceTrees` 已有的，全部是孤兒形狀。
@Test func withNoLiveSpacesOnlyTheStoredTreesShow() {
    let tabs = doc.spaceTabs(location: "home", profile: "開發", role: "main", live: [])
    #expect(tabs.map(\.space) == ["U-1", "U-孤兒"])
    #expect(tabs.allSatisfy { $0.index == nil })
}

/// 這個角色一棵樹都沒有，但 yabai 有 space → 照樣列，畫布是空的。
@Test func aRoleWithNoTreesStillListsLiveSpaces() {
    let tabs = doc.spaceTabs(location: "home", profile: "開發", role: "DELL",
                             live: live([("U-9", 6)]))
    #expect(tabs.map(\.space) == ["U-9"])
    #expect(tabs.first?.hasTree == false)
}

/// 那一頁的樹走的是 `spaceTrees`，而不是 `trees`——後者仍然存在（`workmode`
/// 那條路徑套的），拿它當退路就是「編到了別的版面」。
@Test func theTreeForATabComesFromSpaceTrees() {
    let node = doc.tree(location: "home", profile: "開發", role: "main", space: "U-孤兒")
    #expect(node == .window(label: "Chat", ratio: nil))
    #expect(doc.tree(location: "home", profile: "開發", role: "main", space: "沒有這個")
        == .empty)
}
