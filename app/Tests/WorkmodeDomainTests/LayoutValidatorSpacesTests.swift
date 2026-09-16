import Testing
@testable import WorkmodeDomain

// `spaces` 這個鍵 2026-08-30 廢止：`spaceTrees` 直接用 space uuid 當索引。
// validator 要**擋下**它——不擋的話舊格式會靜默失效（`spaceTrees` 用名字當鍵，
// 而 `--space` 的查表只認 uuid），而畫面上什麼都看不出來。

private func location(_ members: [JSONMember]) -> JSONValue {
    .object([
        JSONMember(key: "desc", value: .string("家")),
        JSONMember(key: "displays", value: .object([
            JSONMember(key: "main", value: .string("A")),
        ])),
        JSONMember(key: "profiles", value: .object([
            JSONMember(key: "開發", value: .object([
                JSONMember(key: "trees", value: .object([])),
            ])),
        ])),
    ] + members)
}

@Test func aLocationWithNoSpacesKeyIsFine() {
    #expect(LayoutValidator.spacesChecks(location: "home", value: location([])).isEmpty)
}

/// 舊格式：地點層有 `spaces`。
@Test func theOldSpacesKeyIsRejected() {
    let value = location([
        JSONMember(key: "spaces", value: .object([
            JSONMember(key: "main", value: .object([
                JSONMember(key: "1", value: .string("U-1")),
            ])),
        ])),
    ])
    let problems = LayoutValidator.spacesChecks(location: "home", value: value)
    #expect(problems.count == 1)
    // `LayoutProblem` 沒有 `message`，所以拆 case 拿字串（計畫寫的 `.message`
    // 這個屬性不存在，加一個只為了測試用的 accessor 不划算）。
    guard case let .structural(text)? = problems.first else {
        Issue.record("不是 structural：\(problems)")
        return
    }
    #expect(text.contains("spaces"))
    // 訊息要說得出**怎麼改**，不只說「不對」——這是使用者唯一會看到的東西。
    #expect(text.contains("uuid"))
}

/// 形狀不對也是同一句話：這個鍵不論長什麼樣都不該存在。
@Test func anOldSpacesKeyOfAnyShapeIsRejected() {
    for shape in [JSONValue.string("x"), .array([]), .null, .bool(false)] {
        let value = location([JSONMember(key: "spaces", value: shape)])
        #expect(LayoutValidator.spacesChecks(location: "home", value: value).count == 1,
                "這個形狀沒被擋：\(shape)")
    }
}
