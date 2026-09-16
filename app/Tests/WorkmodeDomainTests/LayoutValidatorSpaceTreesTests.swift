import Testing
@testable import WorkmodeDomain

// profile 層的 `spaceTrees`（角色 → {space 名字: 一棵樹}）。樹本身的規則與 `trees`
// 共用 `treeChecks`，所以這裡只驗「有走到」與「路徑前綴指得出是哪個 space」，
// 不重驗樹的每一條——重驗會變成兩份會漂移的規格。

private let twoLabels = windowList([.string("A"), .string("B")])

private func withSpaceTrees(_ spaceTrees: JSONValue) -> JSONValue {
    obj([("home", locationWith(profile: "P",
                               obj([("trees", .object([])),
                                    ("spaceTrees", spaceTrees)]),
                               windows: twoLabels))])
}

private func split(axis: String) -> JSONValue {
    obj([("axis", .string(axis)),
         ("children", .array([obj([("window", .string("A"))]),
                              obj([("window", .string("B"))])]))])
}

@Test func aWellFormedSpaceTreeIsSilent() {
    let config = withSpaceTrees(obj([("main", obj([("編碼", split(axis: "vertical"))]))]))
    #expect(LayoutValidator.validate(config).isEmpty)
}

/// 路徑前綴必須指得出是哪個角色的哪個 space，否則使用者看不出要去改哪裡。
@Test func aBadAxisInsideASpaceTreeNamesTheSpace() {
    let config = withSpaceTrees(obj([("main", obj([("編碼", split(axis: "diagonal"))]))]))
    #expect(LayoutValidator.validate(config) == [
        .structural("home.P.spaceTrees.main.編碼：axis「diagonal」不是 vertical 或 horizontal"),
    ])
}

/// 用的是**生效的** label 清單，不是另外算一份。兩份漂移的症狀是「拖進去、存檔被擋、
/// 而畫面上兩個名字一模一樣」。
@Test func aSpaceTreeCannotReferenceALabelThatDoesNotExist() {
    let config = withSpaceTrees(obj([("main", obj([("編碼", obj([("window", .string("不存在"))]))]))]))
    #expect(LayoutValidator.validate(config) == [
        .structural("home.P.spaceTrees.main.編碼：window「不存在」不在生效的 windows 清單裡"),
    ])
}

@Test func spaceTreesMustBeAnObject() {
    #expect(LayoutValidator.validate(withSpaceTrees(.string("不是物件"))) == [
        .structural("home.P：spaceTrees 要是物件（角色 → {space uuid: 樹}）"),
    ])
}

@Test func aSpaceTreeRoleMustMapToAnObject() {
    let config = withSpaceTrees(obj([("main", .array([]))]))
    #expect(LayoutValidator.validate(config) == [
        .structural("home.P.spaceTrees.main：要是物件（space uuid → 樹）"),
    ])
}

/// 順序：`trees` 的問題排在 `spaceTrees` 之前。同一份設定兩邊都錯時，使用者是照
/// 這個順序一條一條修的。這條也是唯一分得出兩者先後的 fixture。
@Test func treeProblemsComeBeforeSpaceTreeOnes() {
    let profile = obj([("trees", obj([("main", split(axis: "diagonal"))])),
                       ("spaceTrees", obj([("main", obj([("編碼", split(axis: "斜"))]))]))])
    let config = obj([("home", locationWith(profile: "P", profile, windows: twoLabels))])
    #expect(LayoutValidator.validate(config) == [
        .structural("home.P.trees.main：axis「diagonal」不是 vertical 或 horizontal"),
        .structural("home.P.spaceTrees.main.編碼：axis「斜」不是 vertical 或 horizontal"),
    ])
}

/// 護欄：今天所有的設定都沒有這個鍵。
@Test func theSpaceTreesKeyIsOptional() {
    #expect(LayoutValidator.validate(obj([("home", locationWith(profile: "P", okProfile))])).isEmpty)
}

// MARK: - space uuid 這個鍵本身

// 這兩種鍵永遠配不到任何 space（`--space` 比的是當下可見那個的 uuid），所以掛在
// 它們底下的樹是死設定，而症狀是「那個 space 我畫過，切過去卻什麼都沒發生」。
// 實際踩到過：`office.開發.spaceTrees` 底下 `main` 與 `ASUS` 各有一個 `""`。

/// 空字串的鍵要被擋下，而訊息要指得出是哪個角色。
@Test func anEmptySpaceUuidIsRejected() {
    let config = withSpaceTrees(obj([("main", obj([("", split(axis: "vertical"))]))]))
    #expect(LayoutValidator.validate(config) == [
        .structural("home.P.spaceTrees.main：space uuid 不能是空的或含空白（「」）——"
            + "這棵樹永遠不會被套用，因為查表比的是當下可見那個 space 的 uuid"),
    ])
}

/// 全形空白（U+3000）也要擋。
///
/// **鑑別值就是這個字元**：寫 `key.contains(" ")` 的實作放行它（回空陣列），
/// 而走 validator 自己那支 `containsWhitespace` 的擋得下來。原始碼寫的是
/// `\u{3000}` escape 而不是那個字元本身——它在編輯器裡看不見。
@Test func aSpaceUuidMadeOfFullWidthSpaceIsRejected() {
    let key = "\u{3000}"
    let config = withSpaceTrees(obj([("main", obj([(key, split(axis: "vertical"))]))]))
    #expect(LayoutValidator.validate(config).count == 1)
}

/// 鍵壞掉之後，**那一棵樹自己的問題**還是要報出來。
///
/// 鑑別值是 **2**：寫成「報了鍵的問題就 `continue`」的實作回 1。
/// 而那個突變要打得到，壞掉的 axis 必須掛在**同一個 entry**（也就是空鍵）底下
/// ——放在旁邊那個健康的 uuid 底下的話，`continue` 只跳過空鍵那一輪，
/// 另一輪照跑，兩種實作都回 2（2026-09-07 實測，那是這條測試的第一版，
/// 它對這個突變完全沒有鑑別力）。
@Test func aRejectedSpaceKeyStillReportsItsOwnTree() {
    let config = withSpaceTrees(obj([("main", obj([("", split(axis: "diagonal"))]))]))
    let problems = LayoutValidator.validate(config)
    #expect(problems.count == 2, "\(problems)")
    #expect(problems.last == .structural(
        "home.P.spaceTrees.main.：axis「diagonal」不是 vertical 或 horizontal"
    ))
}

/// 真的 uuid（以及既有測試用的中文名字）不受影響——這一條是對照組。
@Test func aPlausibleSpaceUuidIsSilent() {
    let config = withSpaceTrees(obj([
        ("main", obj([("66666666-6666-4666-8666-666666666666", split(axis: "vertical"))])),
    ]))
    #expect(LayoutValidator.validate(config).isEmpty)
}
