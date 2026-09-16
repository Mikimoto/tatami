import Testing
import WorkmodeDomain

/// Safari 只有一個分頁 → 那個網址是穩定的身分。
@Test func aSafariWindowWithOneTabGetsItsURL() {
    let dump = "594\thttps://meet.google.com/abc\tMeet\t1\n146\thttps://a.example\tA\t1\n146\thttps://b.example\tB\t0"
    let named = AutoWindowName.derive(id: "594", app: "Safari", dump: dump,
                                      taken: [], existingAppRules: [])
    #expect(named?.label == "Safari")
    #expect(named?.rule == JSONValue.object([
        JSONMember(key: "label", value: .string("Safari")),
        JSONMember(key: "match", value: .array([.string("url-contains"),
                                                .string("https://meet.google.com/abc")])),
    ]))
}

/// **對照組**：同一支對多分頁的視窗要回 nil。少了它，「一律用網址」與正確的
/// 實作分不出來——而「一律用網址」正是這個功能最危險的失效（切一次分頁就死）。
@Test func aSafariWindowWithManyTabsHasNoStableIdentity() {
    let dump = "146\thttps://a.example\tA\t1\n146\thttps://b.example\tB\t0"
    #expect(AutoWindowName.derive(id: "146", app: "Safari", dump: dump,
                                  taken: [], existingAppRules: ["Safari"]) == nil)
}

/// 非 Safari 且該 app 還沒有 catch-all → 用 app 名。
@Test func anAppWithoutACatchAllGetsOne() {
    let named = AutoWindowName.derive(id: "7", app: "Tower", dump: "",
                                      taken: [], existingAppRules: ["Safari"])
    #expect(named?.label == "Tower")
    #expect(named?.rule == JSONValue.object([
        JSONMember(key: "label", value: .string("Tower")),
        JSONMember(key: "match", value: .array([.string("app"), .string("Tower")])),
    ]))
}

/// 該 app 已經有 catch-all 了，而這個視窗不是 Safari 單分頁 → 推不出身分。
/// 硬推一條 `["app", X]` 會是第二條永遠搶不到視窗的死規則。
@Test func aSecondWindowOfAnAppThatAlreadyHasACatchAllIsRefused() {
    #expect(AutoWindowName.derive(id: "8", app: "Tower", dump: "",
                                  taken: [], existingAppRules: ["Tower"]) == nil)
}

/// 這個功能存在的理由本身：使用者有三個 Safari 視窗而只有兩條認得出 Safari 的
/// 規則，所以第三個視窗來的時候 `existingAppRules` **必定**含 `Safari`。
/// 單分頁那條分支排在 catch-all 那道守衛之前，把守衛挪到前面就會讓這一條轉紅
/// ——而那個實作在使用者真正的情境上等於什麼都沒修。
@Test func aSingleTabSafariWindowStillWinsWhenSafariAlreadyHasACatchAll() {
    let dump = "312\thttps://mail.example/inbox\tInbox\t1"
    let named = AutoWindowName.derive(id: "312", app: "Safari", dump: dump,
                                      taken: ["Safari"], existingAppRules: ["Safari"])
    #expect(named?.label == "Safari 2")
    #expect(named?.rule == JSONValue.object([
        JSONMember(key: "label", value: .string("Safari 2")),
        JSONMember(key: "match", value: .array([.string("url-contains"),
                                                .string("https://mail.example/inbox")])),
    ]))
}

/// 恰好一個分頁**不保證**拿得到網址，兩種都餵一次：dump 裡沒有那一列標成當前分頁
/// （`currentTabURL` 回 nil），以及標了但網址欄是空的（回空字串）。兩種都退回
/// app 那條——少了這一條，那兩道守衛沒有任何輸入踩得到。
@Test func aSingleTabSafariWindowWithoutAUsableURLFallsBackToTheApp() {
    let appRule = JSONValue.object([
        JSONMember(key: "label", value: .string("Safari")),
        JSONMember(key: "match", value: .array([.string("app"), .string("Safari")])),
    ])
    let noCurrentTab = AutoWindowName.derive(id: "42", app: "Safari",
                                             dump: "42\thttps://a.example\tA\t0",
                                             taken: [], existingAppRules: [])
    #expect(noCurrentTab?.rule == appRule)
    let emptyURL = AutoWindowName.derive(id: "42", app: "Safari", dump: "42\t\tA\t1",
                                         taken: [], existingAppRules: [])
    #expect(emptyURL?.rule == appRule)
}

/// label 撞名時挑第一個沒用過的，不是最大加一（與 `HotkeyDocument.nextZoneName`
/// 同一條規則）。`Safari 3` 已經被用掉而 `Safari 2` 沒有，所以答案是 `Safari 2`
/// ——最大加一會給 `Safari 4` 並在中間留一個永遠補不回來的洞。
@Test func theLabelSkipsTheNamesAlreadyTaken() {
    let dump = "594\thttps://meet.google.com/abc\tMeet\t1"
    let named = AutoWindowName.derive(id: "594", app: "Safari", dump: dump,
                                      taken: ["Safari", "Safari 3"], existingAppRules: [])
    #expect(named?.label == "Safari 2")
}
