import Testing
import WorkmodeDomain

// `--save` 這一輪新加的規則落在哪裡。
//
// 這一組是唯一驗得到落點的地方，而它需要 `MergedSpy`：`Outcome` 兩種落點都是
// `.written`，事件也一模一樣，`files.writes` 只看得到 `"<formatted>"`。
// 那正是這個缺陷活這麼久的原因——「加了卻永遠不生效」與「加對了」在每一個
// 既有的觀測面上都相同。

/// 兩個 Safari 視窗、只有一條認得 Safari 的規則：第一個被那條 catch-all 認走，
/// 第二個沒有名字。這就是使用者回報的形狀。
private let twoSafaris = [window(id: "7", app: "Safari", title: "Meet",
                                 originX: 0, width: 100),
                          window(id: "8", app: "Safari", title: "Inbox",
                                 originX: 200, width: 100)]

/// 兩個都**恰好一個分頁**，所以兩個都推得出穩定身分（`AutoWindowName`）。
private let bothSingleTab = "7\thttps://meet.google.com/abc\tMeet\t1\n"
    + "8\thttps://mail.example/inbox\tInbox\t1"

/// 共用層 ＋ 一條 Safari catch-all。`Code` 那條不能少：`config()` 的每個 profile
/// 都帶著一棵 `trees.main = leaf("Code")`，而 `LayoutValidator` 會檢查它。
private let sharedCatalog = [("Code", "Ghostty"), ("Safari", "Safari")]

/// 自動那條路推出來的規則，插在它要贏的那條 catch-all **前面**。
///
/// 生效清單是 `shared + local` 且 `RuleResolution` 先到先得，所以接在後面的話
/// `["app", "Safari"]` 會先把那個視窗認走，新規則拿到 `ruleCandidatesAllClaimed`
/// ——設定檔看起來多了一條規則，而畫面上那一格永遠是空的。
@Test func aRuleInventedForAWindowLandsInFrontOfTheCatchAll() {
    let scene = harness(config: config(catalog: sharedCatalog),
                        windows: twoSafaris, hasTTY: false, safariDump: bothSingleTab)
    #expect(scene.runAutomatic("新", true) == .written(path: saveLayoutPath))
    #expect(scene.merged.labels(at: ["windows"]) == ["Code", "Safari 2", "Safari"])
    // **對照組**：沒有同時被接到地點層尾端。少了它，「插進共用層」與
    // 「插進共用層而且又接了一份」分不出來，而後者是兩條同名規則、
    // `LayoutValidator` 的重複 label 檢查會擋下下一次存檔。
    #expect(scene.merged.labels(at: ["home", "windows"]) == [])
}

/// **終端機那條路一起修好了。** `askForNames` 產生的規則本來也是接在尾端，
/// 所以使用者親手打了名字，那個視窗照樣被 catch-all 搶走——同一個缺陷。
@Test func aRuleTheUserNamedLandsInFrontOfTheCatchAllToo() {
    let scene = harness(config: config(catalog: sharedCatalog),
                        windows: twoSafaris, answers: ["工作"], safariDump: bothSingleTab)
    #expect(scene.run("新") == .written(path: saveLayoutPath))
    #expect(scene.merged.labels(at: ["windows"]) == ["Code", "工作", "Safari"])
}

/// profile 自己有 `windows` 時它整塊取代共用層與地點層（`LayoutQuery.swift:115`），
/// 所以新規則要插進**那一份**。
///
/// fixture 在共用層也放了一條 Safari catch-all：插錯地方的話規則落進一份沒有人讀的
/// 陣列，樹引用的 label 於是不在生效清單裡，`LayoutValidator` 把整次存檔擋成
/// `.rejected`——所以 `.written` 本身就是這條測試一半的鑑別力。
@Test func aRuleGoesIntoTheProfilesOwnWindowsWhenItHasThem() {
    let scene = harness(config: config(catalog: [("Code", "Ghostty"),
                                                 ("共用Safari", "Safari")],
                                       profileCatalog: sharedCatalog),
                        windows: twoSafaris, hasTTY: false, safariDump: bothSingleTab)
    #expect(scene.runAutomatic("開發", true) == .written(path: saveLayoutPath))
    #expect(scene.merged.labels(at: ["home", "profiles", "開發", "windows"])
        == ["Code", "Safari 2", "Safari"])
    #expect(scene.merged.labels(at: ["windows"]) == ["Code", "共用Safari"])
}

/// 同一次存檔裡第二條規則要看得見第一條**已經插進去了**。
///
/// `seat` 逐條餵上一條的結果；每次都餵原始 `config` 的話最後一條的結果會把前面幾條
/// 整個蓋掉，而它回傳的 `remaining` 仍然說每一條都放好了——於是第一條規則消失，
/// 樹卻還引用著它的 label。這條測試 2026-09-10 由突變加上去：那個宣稱原本寫在
/// `seat` 的註解裡而沒有任何測試在守它（改成餵 `config` 全套 1313 條零轉紅）。
///
/// 三個 Safari 視窗、一條 `["app", "Safari"]`：catch-all 認走一個，剩下兩個都是
/// **恰好一個分頁**所以都推得出網址規則，兩條都要贏同一條 catch-all。
@Test func theSecondPlacedRuleDoesNotWipeOutTheFirst() {
    let third = window(id: "9", app: "Safari", title: "Docs", originX: 400, width: 100)
    let scene = harness(config: config(catalog: sharedCatalog),
                        windows: twoSafaris + [third], hasTTY: false,
                        safariDump: bothSingleTab + "\n9\thttps://docs.example/x\tDocs\t1")
    #expect(scene.runAutomatic("新", true) == .written(path: saveLayoutPath))
    #expect(scene.merged.labels(at: ["windows"])
        == ["Code", "Safari 2", "Safari 3", "Safari"])
}

/// **對照組**：沒有那個 app 的 catch-all 就照舊接到落點尾端，不是硬插到最前面。
/// 少了它，「一律插在第一個位置」與正確的實作分不出來，而那會讓一條新規則
/// 搶走別條規則本來認得的視窗。
@Test func withoutACatchAllTheNewRuleStillGoesToTheEnd() {
    let scene = harness(config: config(catalog: [("Code", "Ghostty")]),
                        windows: [window(id: "7", app: "Zed", title: "t",
                                         originX: 0, width: 100)],
                        hasTTY: false)
    #expect(scene.runAutomatic("新", true) == .written(path: saveLayoutPath))
    #expect(scene.merged.labels(at: ["windows"]) == ["Code"])
    #expect(scene.merged.labels(at: ["home", "windows"]) == ["Zed"])
}
