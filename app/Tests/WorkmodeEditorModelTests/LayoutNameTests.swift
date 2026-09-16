import Testing
import WorkmodeDomain
import WorkmodeEditorModel

@Suite("名稱合法性")
struct LayoutNameTests {
    @Test func acceptsAnOrdinaryName() {
        #expect(LayoutName.rejection(for: "開發", existing: ["會議"], what: "profile") == nil)
    }

    /// 四種拒絕各有不同的訊息——它會直接進 `lastRejection` 的 alert，
    /// 寫成同一句話等於沒告訴使用者要改什麼。
    @Test func refusesTheFourBadShapes() {
        let cases = ["", "auto", "有 空白", "會議"]
        var messages: [String] = []
        for name in cases {
            let rejection = LayoutName.rejection(for: name, existing: ["會議"],
                                                 what: "profile")
            #expect(rejection != nil, "\(name) 應該被拒")
            messages.append(rejection ?? "")
        }
        #expect(Set(messages).count == 4)
    }

    /// **全形空白 U+3000 也算空白**，因為 validator 是這樣認的。自己寫
    /// `contains(" ")` 的實作在這一條紅——而它放行的名字會讓 ⌘S 被擋，
    /// 畫面上那個名字看起來完全正常。
    @Test func fullWidthSpaceCountsAsWhitespace() {
        #expect(LayoutName.rejection(for: "有\u{3000}空白", existing: [],
                                     what: "地點") != nil)
        #expect(LayoutName.rejection(for: "有\u{00A0}空白", existing: [],
                                     what: "地點") != nil)
    }

    /// 改名成自己不算撞名。
    @Test func aNameDoesNotCollideWithItself() {
        #expect(LayoutName.rejection(for: "會議", existing: ["開發"], what: "profile") == nil)
    }

    /// 對照組：這份 fixture 本身要過得了 validate。後面每個「改完仍然合法」的
    /// 斷言都建立在它上面，它自己不合法的話那些斷言證明不了任何事。
    @Test func theFixtureItselfValidates() throws {
        try #expect(LayoutValidator.validate(settingsDocument().root).isEmpty)
    }
}
