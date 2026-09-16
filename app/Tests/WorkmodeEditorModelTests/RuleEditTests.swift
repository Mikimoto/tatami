import Foundation
import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

/// 共用層兩條、`office` 地點層一條，順序刻意與位元組排序相反（`Z` 在 `A` 前）。
///
/// `開發` 只有 `trees` 而沒有 `windows`：這份檔跑 `LayoutValidator.validate` 是
/// **零問題**，`addingTwiceGivesTwoDistinctLabelsThatValidate` 整條靠這一點——
/// 底子就有問題的話，那條測不出新增規則有沒有撞名。
private let sample = """
{"windows":[{"label":"Z","match":["app","ZZ"]},\
{"label":"A","match":["url-contains","aa"],"fallback":["title-regex","x|y"]}],\
"office":{"desc":"辦","displays":{"main":"M"},\
"windows":[{"label":"郵件","match":["app","Mail"]}],\
"profiles":{"開發":{"trees":{}}}}}
"""

private func doc() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(sample))
}

/// 參數不叫 `d`／`i`：swiftlint 的 `identifier_name` 要求識別字至少 3 個字元。
private func rule(_ layout: LayoutDocument, _ scope: RuleScope, _ slot: Int) -> RuleRow? {
    layout.allRules.first { $0.scope == scope && $0.index == slot }?.row
}

@Test func settingAFieldChangesOnlyThatField() throws {
    let after = try doc().settingRuleField(.shared, index: 0, field: .matchValue, to: "新值")
    #expect(rule(after, .shared, 0)?.matchValue == "新值")
    #expect(rule(after, .shared, 0)?.label == "Z")
    #expect(rule(after, .shared, 0)?.matchKind == "app")
    // 別層完全沒動
    #expect(rule(after, .location("office"), 0)?.label == "郵件")
}

/// 編輯不得順手重排、也不得把別處的字面值改寫。
@Test func editingKeepsEverythingElseByteIdentical() throws {
    let before = try doc()
    let after = before.settingRuleField(.shared, index: 0, field: .label, to: "Z2")
    let expected = JSONWriter.format(before.root)
        .replacingOccurrences(of: "\"Z\"", with: "\"Z2\"")
    #expect(JSONWriter.format(after.root) == expected)
}

/// **`RuleRow` 是有損投影，所以「整列重建」這個寫法必須有東西擋著。**
/// `editingKeepsEverythingElseByteIdentical` 擋不住它——上面那份 fixture 的每一列
/// 都剛好只有 `label`／`match`／`fallback` 且順序相同，整列重建印出來逐位元組一樣
/// （2026-08-19 實測：那個突變全綠）。這一列多了一個投影不認得的鍵與一個非字串的
/// 值，兩者都是重建會靜默吃掉的東西。
@Test func editingDoesNotSwallowKeysTheProjectionCannotSee() throws {
    let root = try JSONParser.parse(
        #"{"windows":[{"label":"Z","備註":"別動我","match":["app","ZZ"],"優先":7}]}"#
    )
    let after = LayoutDocument(root: root)
        .settingRuleField(.shared, index: 0, field: .label, to: "Z2")
    let expected = JSONWriter.format(root)
        .replacingOccurrences(of: "\"Z\"", with: "\"Z2\"")
    #expect(JSONWriter.format(after.root) == expected)
}

/// 地點層與 profile 層都定位得到。
@Test func aLocationLayerRuleIsAddressable() throws {
    let after = try doc().settingRuleField(.location("office"), index: 0,
                                           field: .matchValue, to: "Outlook")
    #expect(rule(after, .location("office"), 0)?.matchValue == "Outlook")
    #expect(rule(after, .shared, 0)?.label == "Z")
}

@Test func addingAndRemovingFallback() throws {
    let added = try doc().addingFallback(.shared, index: 0)
    #expect(rule(added, .shared, 0)?.fallbackKind != nil)
    let removed = added.removingFallback(.shared, index: 0)
    #expect(rule(removed, .shared, 0)?.fallbackKind == nil)
    #expect(rule(removed, .shared, 0)?.fallbackValue == nil)
}

/// 順序有意義：前面的規則先認領視窗，所以搬動必須真的搬。
@Test func movingARuleReorders() throws {
    let after = try doc().movingRule(.shared, from: 1, to: 0)
    #expect(rule(after, .shared, 0)?.label == "A")
    #expect(rule(after, .shared, 1)?.label == "Z")
}

@Test func deletingARuleShiftsTheRest() throws {
    let after = try doc().deletingRule(.shared, index: 0)
    #expect(after.allRules.filter { $0.scope == .shared }.count == 1)
    #expect(rule(after, .shared, 0)?.label == "A")
}

/// 連按兩次新增不能撞名——`validate` 對 label 重複是 rc=1，而它算的是**合併後**的
/// 集合（實測：共用層一條 A 加地點層一條 A 就紅）。撞名的話使用者按第二次新增、
/// 存檔被擋，而畫面上看不出為什麼。
@Test func addingTwiceGivesTwoDistinctLabelsThatValidate() throws {
    let after = try doc().insertingRule(.shared).insertingRule(.shared)
    let labels = after.allRules.filter { $0.scope == .shared }.map(\.row.label)
    #expect(Set(labels).count == labels.count)
    // 實際跑出來的兩個名字也釘住，否則「不重複」可以靠一個隨機字串滿足。
    #expect(labels == ["Z", "A", "新規則", "新規則 2"])
    #expect(LayoutValidator.validate(after.root).isEmpty)
}

/// 預設 label 也不能撞上**別層**的：validate 算的是合併後的集合。
@Test func theDefaultLabelDodgesOtherLayersToo() throws {
    let taken = """
    {"windows":[{"label":"新規則","match":["app","A"]}],\
    "office":{"desc":"辦","displays":{"main":"M"},\
    "windows":[{"label":"新規則 2","match":["app","B"]}],\
    "profiles":{"開發":{"trees":{}}}}}
    """
    let after = try LayoutDocument(root: JSONParser.parse(taken)).insertingRule(.shared)
    #expect(rule(after, .shared, 1)?.label == "新規則 3")
    #expect(LayoutValidator.validate(after.root).isEmpty)
}

@Test func insertingAppendsToThatLayerOnly() throws {
    let after = try doc().insertingRule(.location("office"))
    #expect(after.allRules.filter { $0.scope == .location("office") }.count == 2)
    #expect(after.allRules.filter { $0.scope == .shared }.count == 2)
}

/// 新增出來的那條必須是**能用**的形狀：`match` 是兩元素、類型是真的類型
/// （未知類型 validate 不擋，那是留給使用者的陷阱），而 `fallback` 這個鍵不存在
/// ——`nil` 與空字串在檔案裡是兩件事。
@Test func anInsertedRuleIsShapedLikeARealOne() throws {
    let after = try doc().insertingRule(.shared)
    #expect(rule(after, .shared, 2)?.matchKind == "app")
    #expect(rule(after, .shared, 2)?.matchValue == "")
    #expect(rule(after, .shared, 2)?.fallbackKind == nil)
    #expect(rule(after, .shared, 0)?.label == "Z")
}

/// **畸形的列要修得好，不是編不動。** `match` 不是兩元素陣列時，設欄位要把它
/// 正規化成兩元素——那正是使用者開編輯器要做的事。
@Test func editingRepairsAMalformedMatch() throws {
    let broken = try LayoutDocument(
        root: JSONParser.parse(#"{"windows":[{"label":"B","match":7}]}"#)
    )
    let after = broken.settingRuleField(.shared, index: 0, field: .matchKind, to: "app")
    #expect(rule(after, .shared, 0)?.matchKind == "app")
    #expect(rule(after, .shared, 0)?.matchValue == "")

    // **只漏一格時不得連帶洗掉取得到的那一格。** 上面那組驗不到這件事——`7` 兩格都
    // 取不到，所以「保留取得到的」與「永遠回兩個空字串」給它同一個答案。2026-08-20
    // 實測：把 `twoElements` 改成永遠回 `["", ""]`，全套 728 條**零紅**。
    let short = try LayoutDocument(
        root: JSONParser.parse(#"{"windows":[{"label":"B","match":["app"]}]}"#)
    )
    let repaired = short.settingRuleField(.shared, index: 0, field: .matchValue, to: "V")
    #expect(rule(repaired, .shared, 0)?.matchKind == "app")
    #expect(rule(repaired, .shared, 0)?.matchValue == "V")

    // 反方向：正規化的目標**就是兩元素**，所以三元素以上會被截掉尾巴。這條把那個
    // 行為釘住，`settingPairSlot` 的註解才有東西撐著（產品路徑只讀 `.match[0]`
    // 與 `.match[1]`，出處 `LayoutQuery.swift:129-130`）。
    let long = try LayoutDocument(
        root: JSONParser.parse(#"{"windows":[{"label":"B","match":["app","X","額外"]}]}"#)
    )
    let cut = long.settingRuleField(.shared, index: 0, field: .matchValue, to: "Y")
    #expect(JSONPath.get(cut.root, [.key("windows"), .index(0), .key("match")])
        == .array([.string("app"), .string("Y")]))
}

/// 「這一層收不收得下新規則」的判斷在 Model 不在 view：UI 那層零測試，而條件寫錯的
/// 症狀是「按鈕永遠可按但按了沒反應」或「永遠不能按」，畫面上分不出來。
///
/// `開發` 只有 `trees`：回 false 而不是代為建一個 `windows`——profile 層一旦有那個鍵，
/// 共用層與地點層就整組被取代（實測見 `RuleScope`），一個「新增規則」按鈕不該有那種後果。
@Test func canInsertRuleFollowsWhetherThatLayerHasAWindowsArray() throws {
    let layout = try doc()
    #expect(layout.canInsertRule(.shared))
    #expect(layout.canInsertRule(.location("office")))
    #expect(!layout.canInsertRule(.profile(location: "office", profile: "開發")))
    #expect(!layout.canInsertRule(.location("沒這個地點")))
}

/// 兩支必須同進退。`insertingRule` 對收不下的層回原文件不變（零訊號），所以 UI 拿
/// `canInsertRule` 當按鈕的啟用條件——兩邊各寫一份條件遲早漂移，而漂移的症狀正是
/// 那個零訊號。這條把兩支綁在一起：能按的層就真的多一列，不能按的層就真的沒動。
@Test func insertingAgreesWithCanInsertRule() throws {
    let layout = try doc()
    let scopes: [RuleScope] = [.shared, .location("office"),
                               .profile(location: "office", profile: "開發"),
                               .location("沒這個地點")]
    for scope in scopes {
        let changed = layout.insertingRule(scope) != layout
        #expect(changed == layout.canInsertRule(scope), "\(scope) 兩支不一致")
    }
}

/// 路徑走不通就回原文件不變。投影與文件不同步是 bug，但編輯器當掉更糟：
/// 使用者剛打的字會連整個 session 一起沒了。六個動作都要吞。
@Test func anUnreachablePathLeavesTheDocumentAlone() throws {
    let before = try doc()
    #expect(before.settingRuleField(.shared, index: 9, field: .label, to: "X") == before)
    #expect(before.settingRuleField(.shared, index: 9, field: .matchKind, to: "app") == before)
    #expect(before.settingRuleField(.location("沒這個地點"), index: 0,
                                    field: .label, to: "X") == before)
    #expect(before.addingFallback(.shared, index: 9) == before)
    #expect(before.removingFallback(.shared, index: 9) == before)
    #expect(before.movingRule(.shared, from: 9, to: 0) == before)
    #expect(before.deletingRule(.shared, index: 9) == before)
    #expect(before.insertingRule(.location("沒這個地點")) == before)
}

/// 值有進去，形狀與手動新增那條一樣（只有 `label` 與 `match` 兩個鍵）。
@Test func insertingWithValuesWritesBothHalvesOfTheMatch() throws {
    let after = try doc().insertingRule(.shared, label: "Zed",
                                        match: ("app", "Zed"))
    let last = try #require(rule(after, .shared, 2))
    #expect(last.label == "Zed")
    #expect(last.matchKind == "app")
    #expect(last.matchValue == "Zed")
    // **不給 `fallback` 鍵**：`nil` 與空字串在檔案裡是兩件事，多給一個空的
    // 等於替使用者決定這條規則有 fallback。
    #expect(last.fallbackKind == nil)
}

/// label 撞名就遞增。`validate` 對重複 label 回 rc=1，而且算的是**合併後的
/// 生效集合**——同一個 app 建第二條規則一定撞。
/// 這份 fixture 的共用層本來就有一條 label 是 `Z`。
@Test func aTakenLabelGetsANumberAfterIt() throws {
    let after = try doc().insertingRule(.shared, label: "Z",
                                        match: ("app", "ZZ"))
    #expect(rule(after, .shared, 2)?.label == "Z 2")
}

/// 沒帶值的那支行為一個字都沒變——它現在是帶值那支的特例。
@Test func theBareInsertStillMakesAnEmptyAppRule() throws {
    let after = try doc().insertingRule(.shared)
    let last = try #require(rule(after, .shared, 2))
    #expect(last.label == "新規則")
    #expect(last.matchKind == "app")
    #expect(last.matchValue == "")
}
