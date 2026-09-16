import Testing
import WorkmodeDomain
import WorkmodeEditorModel

@Suite("版面模板")
struct PaneTemplateTests {
    /// 四個模板、四個格數。**寫死而不是從骨架算**：這一條的價值是釘住
    /// 「田字是 4 格」這件事，而骨架自己算出來的數字沒有辦法推翻它。
    @Test func eachTemplateKnowsHowManyWindowsItHolds() {
        #expect(PaneTemplate.split2Vertical.slotCount == 2)
        #expect(PaneTemplate.split2Horizontal.slotCount == 2)
        #expect(PaneTemplate.grid4.slotCount == 4)
        #expect(PaneTemplate.oneLeftTwoRight.slotCount == 3)
    }

    /// 標題會出現在按鈕上與兩句 notice 裡，所以它不能是空的，也不能重複
    /// ——重複的話「左右二分只放得下 2 個」會指不出是哪一顆按鈕。
    @Test func everyTemplateHasItsOwnTitle() {
        let titles = PaneTemplate.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == PaneTemplate.allCases.count)
    }

    private func path(_ role: String = "main") -> PanePath {
        PanePath(location: "office", profile: "開發", role: role, space: "S-1", slots: [])
    }

    private func window(_ document: LayoutDocument, _ slots: [Int]) -> JSONValue? {
        JSONPath.get(document.root, path().steps
            + slots.flatMap { [JSONPath.Step.key("children"), .index($0)] }
            + [.key("window")])
    }

    /// 依畫面順序（深度優先、先 children[0]）。
    @Test func leavesComeOutInReadingOrder() throws {
        let leaves = try fixtureDocument().windowLeaves(at: path())
        #expect(leaves.count == 3)
        #expect(leaves.first?["window"] == .string("甲"))
        #expect(leaves.last?["window"] == .string("乙"))
    }

    /// 3 個視窗套田字：前三格照順序，第四格空的。
    ///
    /// **斷言的是誰站在哪一格**，不是「有幾個葉」——後者對「把 first 與 second
    /// 的求值順序對調」完全沒有鑑別力（數量不變，只是每個人站錯位置）。
    @Test func aGridKeepsTheWindowsInOrderAndLeavesTheRestVacant() throws {
        let after = try fixtureDocument().applyingTemplate(.grid4, at: path())
        #expect(after.node(at: path())?["axis"] == .string("horizontal"))
        #expect(window(after, [0, 0]) == .string("甲"))
        #expect(window(after, [0, 1]) == .number("7"))
        #expect(window(after, [1, 0]) == .string("乙"))
        // 第四格是空物件：沒有 window 也沒有 axis。
        #expect(JSONPath.get(after.root, path().steps
                + [.key("children"), .index(1), .key("children"), .index(1)])
            == .object([]))
    }

    /// 搬的是**整個葉**不是只有 label：`ratio` 的字面值與使用者自己加的鍵都要活著。
    /// 只搬 `window` 值的話 `0.750` 會消失，而那是使用者調過的比例。
    @Test func aTemplateCarriesTheWholeLeafNotJustTheLabel() throws {
        let after = try fixtureDocument().applyingTemplate(.grid4, at: path())
        let leaf = path().steps + [.key("children"), .index(0),
                                   .key("children"), .index(0)]
        #expect(JSONPath.get(after.root, leaf + [.key("ratio")]) == .number("0.750"))
        #expect(JSONPath.get(after.root, leaf + [.key("note")]) == .string("自訂鍵"))
    }

    /// 放不下就整個拒絕。**斷言的是「回傳的文件與輸入相等」**，不是格數——
    /// 截斷式的實作會產生一棵合法的樹（2 格、少了一個視窗），數格數看不出來。
    @Test func aTemplateTooSmallChangesNothing() throws {
        let before = try fixtureDocument()
        #expect(before.applyingTemplate(.split2Vertical, at: path()) == before)
    }

    /// 剛好放得下就沒有空格。
    @Test func threeWindowsFitOneLeftTwoRightExactly() throws {
        let after = try fixtureDocument().applyingTemplate(.oneLeftTwoRight, at: path())
        #expect(window(after, [0]) == .string("甲"))
        #expect(window(after, [1, 0]) == .number("7"))
        #expect(window(after, [1, 1]) == .string("乙"))
    }

    /// 空的樹套模板：整個骨架都是空格。`會議` 的 `spaceTrees` 是 `{}`，所以
    /// `main` 與 `S-1` 兩個鍵都不存在——走的是 `setCreatingMissingObjects` 那條
    /// （少了它，還沒畫過的分頁上第一次套模板什麼都不會發生）。
    @Test func anEmptyTreeGetsAnEmptySkeleton() throws {
        let target = PanePath(location: "office", profile: "會議", role: "main",
                              space: "S-1", slots: [])
        let after = try fixtureDocument().applyingTemplate(.split2Vertical, at: target)
        #expect(after.node(at: target)?["axis"] == .string("vertical"))
        #expect(after.windowLeaves(at: target).isEmpty)
    }
}
