import Testing
import WorkmodeDomain
import WorkmodeEditorModel

@Suite("挑一個現在開著的視窗")
struct WindowChoiceTests {
    /// dump 每行是 `<window_id>\t<url>\t<tab title>\t<is-current>`。
    /// 191 有兩個分頁而當前的是第二個；206 一個分頁；777 在 dump 裡但 yabai 沒列。
    private let dump = """
    191\thttps://github.com/x\tGitHub\t0
    191\thttps://chat.google.com/a?b\tChat (工作)\t1
    206\thttps://example.com/\tExample\t1
    777\thttps://ghost.example\t幽靈\t1
    """

    private let windows = [
        LiveWindow(id: "191", app: "Safari", title: "Chat"),
        LiveWindow(id: "206", app: "Safari", title: "Example"),
        LiveWindow(id: "310", app: "Zed", title: "workmode.swift"),
    ]

    /// dump 裡有那個 id 就補上**當前分頁**的網址與標題，不是第一個分頁。
    @Test func theCurrentTabWinsNotTheFirstOne() {
        let choices = WindowChoice.merge(windows, dump: dump)
        let safari = choices.first { $0.id == "191" }
        #expect(safari?.tabURL == "https://chat.google.com/a?b")
        #expect(safari?.tabTitle == "Chat (工作)")
    }

    /// dump 裡沒有的視窗，兩個欄位都是 nil——那正是「這個視窗只能用 app 條件」
    /// 的判準。
    @Test func aWindowWithNoTabsHasNoURL() {
        let choices = WindowChoice.merge(windows, dump: dump)
        let zed = choices.first { $0.id == "310" }
        #expect(zed?.tabURL == nil)
        #expect(zed?.tabTitle == nil)
    }

    /// **以 yabai 那份為準**：dump 有而 yabai 沒列的視窗不出現。規則配的是 yabai
    /// 管理的視窗，列一個它不管的只會讓使用者建出一條永遠不生效的規則。
    @Test func yabaiDecidesWhoIsOnTheList() {
        let choices = WindowChoice.merge(windows, dump: dump)
        #expect(choices.count == 3)
        #expect(choices.contains { $0.id == "777" } == false)
    }

    /// id 的比對兩邊都先正規化成整數。dump 是 osascript 印的、yabai 那份走
    /// `JQPrint.interpolate`，兩邊都是十進位整數，但**萬一**有一邊多了小數點
    /// （awk 的 strnum 比較容忍 `191` 對 `191.0`），字面比對就會靜默失配——
    /// 症狀是「Safari 視窗沒有網址可選」，而畫面上看不出為什麼。
    @Test func idsAreComparedAsNumbersWhenBothSidesAreNumbers() {
        let choices = WindowChoice.merge(
            [LiveWindow(id: "191.0", app: "Safari", title: "Chat")], dump: dump
        )
        #expect(choices.first?.tabURL == "https://chat.google.com/a?b")
    }

    /// 順序照 yabai 那份，不重排。
    @Test func theOrderComesFromYabai() {
        let choices = WindowChoice.merge(windows, dump: dump)
        #expect(choices.map(\.id) == ["191", "206", "310"])
    }

    /// 沒有分頁資訊的視窗只能用 `app`。**判準是 `tabURL == nil` 而不是 app 名稱**：
    /// 那三種條件全部走分頁 dump，dump 裡沒有這個 id 就永遠配不到。
    @Test func aWindowWithoutTabsOffersOnlyTheAppCondition() {
        let zed = WindowChoice(id: "310", app: "Zed", title: "workmode.swift",
                               tabURL: nil, tabTitle: nil)
        let conditions = zed.conditions
        #expect(conditions.count == 1)
        #expect(conditions.first?.kind == .app)
        #expect(conditions.first?.value == "Zed")
    }

    /// **名字叫 Safari 但不在 dump 裡的視窗照樣只有一條。** 這一條釘住判準是
    /// 「有沒有分頁」而不是「叫什麼名字」——硬編 app 名稱的實作在這裡會回四條。
    @Test func theNameSafariAloneDoesNotUnlockTheTabConditions() {
        let ghost = WindowChoice(id: "999", app: "Safari", title: "沒有分頁",
                                 tabURL: nil, tabTitle: nil)
        #expect(ghost.conditions.count == 1)
    }

    /// 有分頁的視窗給四條，四個值逐一比對。
    @Test func aWindowWithTabsOffersAllFour() {
        let safari = WindowChoice(id: "191", app: "Safari", title: "Chat",
                                  tabURL: "https://chat.google.com/a?b",
                                  tabTitle: "Chat (工作)")
        let byKind = Dictionary(uniqueKeysWithValues:
            safari.conditions.map { ($0.kind, $0.value) })
        #expect(byKind.count == 4)
        #expect(byKind[.app] == "Safari")
        #expect(byKind[.urlExact] == "https://chat.google.com/a?b")
        // url-contains 給 host：使用者現有的 `chat.google.com` 就是這個形狀。
        #expect(byKind[.urlContains] == "chat.google.com")
        // title-regex 的值是 regex，括號要跳脫，否則它會被當成 group。
        #expect(byKind[.titleRegex] == "Chat \\(工作\\)")
    }

    /// host 取到第一個 `/`、`?` 或 `#` 為止。
    @Test func theHostStopsAtTheFirstDelimiter() {
        #expect(WindowChoice.host(of: "https://a.example/x/y") == "a.example")
        #expect(WindowChoice.host(of: "https://b.example?q=1") == "b.example")
        #expect(WindowChoice.host(of: "https://c.example#frag") == "c.example")
        #expect(WindowChoice.host(of: "https://d.example") == "d.example")
    }

    /// 取不出 host 就退回完整網址。**退回而不是少給一個選項**：一個少一條的
    /// 挑選器與「這個視窗不支援 url-contains」在畫面上分不出來。
    @Test func aURLWithoutASchemeFallsBackToItself() {
        #expect(WindowChoice.host(of: "not a url") == "not a url")
    }
}
