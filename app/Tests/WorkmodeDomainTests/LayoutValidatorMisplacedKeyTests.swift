import Testing
@testable import WorkmodeDomain

// `spaceTrees` 放地點層的後果是**靜默無效**：`--space` 永遠查不到樹，設定看起來
// 寫好了而功能就是不動，沒有任何訊息。
//
// `spaces` 這個鍵 2026-08-30 整個廢止（uuid 直接當索引），所以它不再有「放對層」
// 這回事——兩層都擋，訊息是同一句。
//
// 既有的先例是 `LayoutValidator.swift` 那條「trees 不能放在地點層」。

@Test func spaceTreesBelongsInAProfileNotInTheLocation() {
    let config = obj([("home", healthyLocation(extra: [("spaceTrees", .object([]))]))])
    #expect(LayoutValidator.validate(config) == [
        .structural("home：spaceTrees 不能放在地點層，要搬進 profiles.<名稱>.spaceTrees"),
    ])
}

/// `spaces` 2026-08-30 廢止，所以 profile 層那個不再是「放錯層」而是「不該存在」。
/// 兩層擋的是同一件事、報的也是同一句話。
@Test func aProfileLevelSpacesKeyIsRejectedToo() {
    let profile = obj([("trees", .object([])), ("spaces", .object([]))])
    let config = obj([("home", locationWith(profile: "P", profile))])
    #expect(LayoutValidator.validate(config) == [
        .structural("home.P：spaces 已經不用了——space 版面改用 space uuid 當索引，"
            + "把 spaceTrees 的鍵從名字換成 uuid 再刪掉這個鍵"),
    ])
}

/// 順序：地點層那條排在既有的 `trees` 那條之後。兩個都放錯時使用者一次看到兩條。
@Test func bothMisplacedTreeKeysAreReportedInDeclarationOrder() {
    let config = obj([("home", healthyLocation(extra: [("trees", .object([])),
                                                       ("spaceTrees", .object([]))]))])
    #expect(LayoutValidator.validate(config) == [
        .structural("home：trees 不能放在地點層，要搬進 profiles.<名稱>.trees"),
        .structural("home：spaceTrees 不能放在地點層，要搬進 profiles.<名稱>.spaceTrees"),
    ])
}
