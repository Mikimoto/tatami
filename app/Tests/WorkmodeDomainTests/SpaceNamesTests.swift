import Testing
import WorkmodeDomain

// `spaceTrees[角色][space-uuid]` 的查表。名字那一層 2026-08-30 拿掉了——
// `spaces` 這個鍵不存在了，uuid 直接當索引。

private let spaceTrees = JSONValue.object([
    JSONMember(key: "main", value: .object([
        JSONMember(key: "U-1", value: .object([
            JSONMember(key: "window", value: .string("Code")),
        ])),
        JSONMember(key: "U-2", value: .object([
            JSONMember(key: "window", value: .string("Chat")),
        ])),
    ])),
])

@Test func anExistingUUIDFindsItsTree() {
    let tree = SpaceNames.tree(role: "main", uuid: "U-2", in: spaceTrees)
    #expect(tree?["window"] == .string("Chat"))
}

/// **第二棵樹是這條的鑑別力**：只有一棵的話「拿第一個」與「查對的那個」同值。
@Test func theFirstTreeIsNotTheAnswerForEveryUUID() {
    #expect(SpaceNames.tree(role: "main", uuid: "U-1", in: spaceTrees)?["window"]
        == .string("Code"))
    #expect(SpaceNames.tree(role: "main", uuid: "U-2", in: spaceTrees)?["window"]
        == .string("Chat"))
}

@Test func anUnknownUUIDHasNoTree() {
    #expect(SpaceNames.tree(role: "main", uuid: "U-9", in: spaceTrees) == nil)
}

@Test func anUnknownRoleHasNoTree() {
    #expect(SpaceNames.tree(role: "DELL", uuid: "U-1", in: spaceTrees) == nil)
}

/// 非物件的節點（設定手寫壞掉）不是 crash，是「這個螢幕什麼都不做」。
@Test func aNonObjectSpaceTreesHasNoTree() {
    #expect(SpaceNames.tree(role: "main", uuid: "U-1", in: .string("壞掉")) == nil)
    #expect(SpaceNames.tree(role: "main", uuid: "U-1", in: .null) == nil)
}

/// **兩個角色是這條的鑑別力**：只有一個的話「第一個角色的數量」與「全部相加」同值。
@Test func spaceCountAddsUpEveryRole() {
    let twoRoles = JSONValue.object([
        JSONMember(key: "main", value: .object([
            JSONMember(key: "U-1", value: .object([
                JSONMember(key: "window", value: .string("Code")),
            ])),
            JSONMember(key: "U-2", value: .object([
                JSONMember(key: "window", value: .string("Chat")),
            ])),
        ])),
        JSONMember(key: "ASUS", value: .object([
            JSONMember(key: "U-3", value: .object([
                JSONMember(key: "window", value: .string("Safari")),
            ])),
        ])),
    ])
    #expect(SpaceNames.spaceCount(in: twoRoles) == 3)
}

/// 沒有 `spaceTrees` 這個鍵時呼叫端傳的是 `.null`。回 0 而不是 crash：
/// 一個還沒畫過任何東西的 profile 是合法狀態。
@Test func aMissingSpaceTreesCountsAsNothing() {
    #expect(SpaceNames.spaceCount(in: .null) == 0)
}

/// 角色底下不是物件（設定手改壞了）就當那個角色沒有樹，不是整份回 0
/// ——與 `tree(role:uuid:)` 對缺層回 nil 是同一個立場。
@Test func aBrokenRoleIsSkippedButItsSiblingsStillCount() {
    let halfBroken = JSONValue.object([
        JSONMember(key: "main", value: .string("糟糕")),
        JSONMember(key: "ASUS", value: .object([
            JSONMember(key: "U-3", value: .object([
                JSONMember(key: "window", value: .string("Safari")),
            ])),
        ])),
    ])
    #expect(SpaceNames.spaceCount(in: halfBroken) == 1)
}
