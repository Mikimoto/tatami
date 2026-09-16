import Testing
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain

// `--json` **沒有差分基準**（bash 沒有這個表面），所以驗法不是比對 bash，而是
// 對每個事件釘一條 schema 斷言。這一輪只要求最小形狀：kind 加上那個事件的欄位。

/// 套版迴圈剩下的那一組（還原）。與下面兩條分開只是因為單一函式塞不下，
/// 分界跟著 WorkmodeEvent 的分組走。
///
/// 2026-09-07 隨 `ApplyLayout`／`TreeLayout`／`StrangerExile` 退役，這裡原本還有
/// 放逐那三句、`layout_tree` 那七句、以及 `ratioMeasured` 三種 note 的 schema
/// 斷言。那 18 個事件現在一個發送者都沒有。
@Test func rendersTheLayoutLoopEvents() {
    let renderer = JSONEventRenderer()

    #expect(renderer.render(.minimizedWindowRestored(label: "Chat"))
        == #"{"kind":"minimizedWindowRestored","label":"Chat"}"# + "\n")
    #expect(renderer.render(.minimizedWindowRestoreFailed(label: "Chat"))
        == #"{"kind":"minimizedWindowRestoreFailed","label":"Chat"}"# + "\n")
    // 角色跳過那一句。`role` 是使用者取的鍵名，原樣進 JSON。
    #expect(renderer.render(.treeRoleHasNoDisplay(role: "external"))
        == #"{"kind":"treeRoleHasNoDisplay","role":"external"}"# + "\n")
}

/// `report_rules` 與 `resolve_rules`。
@Test func rendersTheRuleEvents() {
    let renderer = JSONEventRenderer()

    // report_rules
    #expect(renderer.render(.noRulesResolved)
        == #"{"kind":"noRulesResolved"}"# + "\n")
    // 八個欄位一律是字串。這一行的來源是 jq 的插值，而 `2.50` 與 `0007` 都是
    // 實際會出現的形狀——寫成 JSON 的數字會讓消費端拿到 2.5 與 7。
    #expect(renderer.render(.ruleWindowPositionReported(
        label: "Chat", id: "2.50", display: "1", space: "0007",
        frame: ReportedFrame(width: "1878", height: "1000",
                             originX: "0", originY: "25")
    ))
        == #"{"display":"1","height":"1000","id":"2.50","kind":"ruleWindowPositionReported","#
        + #""label":"Chat","space":"0007","width":"1878","x":"0","y":"25"}"# + "\n")

    // resolve_rules。候選是陣列而不是 human 版那串接好的文字。
    #expect(renderer.render(.ruleMatchedMultipleWindows(
        label: "Site", count: 2, candidates: ["7", "9"]
    ))
        == #"{"candidates":["7","9"],"count":2,"kind":"ruleMatchedMultipleWindows","#
        + #""label":"Site"}"# + "\n")
    #expect(renderer.render(.ruleCandidatesAllClaimed(label: "Site"))
        == #"{"kind":"ruleCandidatesAllClaimed","label":"Site"}"# + "\n")
    #expect(renderer.render(.ruleWindowNotFound(
        label: "Site", matchType: "url-exact", matchValue: "https://a.example/"
    ))
        == #"{"kind":"ruleWindowNotFound","label":"Site","matchType":"url-exact","#
        + #""matchValue":"https://a.example/"}"# + "\n")
}

/// 迴圈以外：讀設定、認地點、等 app 起來。
@Test func rendersTheSessionEvents() {
    let renderer = JSONEventRenderer()

    // load_layout／active_location
    #expect(renderer.render(.layoutFileMissing(path: "/x/scripts/layout.json"))
        == #"{"kind":"layoutFileMissing","path":"/x/scripts/layout.json"}"# + "\n")
    #expect(renderer.render(.stateLocationNotInLayout(location: "火星"))
        == #"{"kind":"stateLocationNotInLayout","location":"火星"}"# + "\n")

    // ensure_app。秒數是數字：人看的那版才有那個 `s`。
    #expect(renderer.render(.appNotRunning(app: "Chat"))
        == #"{"app":"Chat","kind":"appNotRunning"}"# + "\n")
    #expect(renderer.render(.appLaunchFailed(app: "Chat"))
        == #"{"app":"Chat","kind":"appLaunchFailed"}"# + "\n")
    #expect(renderer.render(.appLaunched(app: "Chat", waitedSeconds: 3))
        == #"{"app":"Chat","kind":"appLaunched","waitedSeconds":3}"# + "\n")
    #expect(renderer.render(.appLaunchTimedOut(app: "Chat", seconds: 10))
        == #"{"app":"Chat","kind":"appLaunchTimedOut","seconds":10}"# + "\n")
}

/// label 是使用者取的名字，可能含引號與反斜線。人看的那版原樣印（bash 也是），
/// JSON 這版必須跳脫，否則吐出來的不是合法 JSON。
@Test func escapesLabelsThatWouldBreakTheJSONLine() {
    let line = JSONEventRenderer().render(.minimizedWindowRestored(label: #"a"b\c"#))

    #expect(line == #"{"kind":"minimizedWindowRestored","label":"a\"b\\c"}"# + "\n")
}

/// `frameRejected` 的兩個 Rect 都要出現在 JSON 裡；設不下去時 `actual` 是 null
/// （`Optional.map` 的結果經 `as Any` 進 `JSONSerialization` 會變 NSNull）。
@Test func rendersFrameRejectedWithBothRectsAndNullWhenUnset() {
    let renderer = JSONEventRenderer()
    let wanted = Rect(originX: 0, originY: 0, width: 100, height: 50)
    // `.sortedKeys`：actual 排第一，wanted 裡是 h/w/x/y。整數值的 Double 印成整數。
    #expect(renderer.render(.space(.frameRejected(label: "A", wanted: wanted, actual: nil)))
        == #"{"actual":null,"kind":"frameRejected","label":"A","wanted":{"h":50,"w":100,"x":0,"y":0}}"# + "\n")
    let clamped = Rect(originX: 0, originY: 0, width: 100, height: 40)
    #expect(renderer.render(.space(.frameRejected(label: "A", wanted: wanted, actual: clamped)))
        == #"{"actual":{"h":40,"w":100,"x":0,"y":0},"kind":"frameRejected","label":"A","#
        + #""wanted":{"h":50,"w":100,"x":0,"y":0}}"# + "\n")
}
