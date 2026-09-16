import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

@Suite("畫布的編輯動作")
struct TreeEditTests {
    private func path(_ slots: [Int], role: String = "main") -> PanePath {
        PanePath(location: "office", profile: "開發", role: role, space: "S-1", slots: slots)
    }

    private func palette(_ index: Int) throws -> LabelChoice {
        try fixtureDocument().paletteLabels(location: "office", profile: "開發")[index]
    }

    /// 往左半放：新葉在 children[0]，原本那個節點退到 [1]，axis 是 vertical。
    /// 逐點斷言，不比整段排版文字（那擋不住「保持大小不變」的突變）。
    @Test func droppingLeadingSplitsVerticallyWithTheLabelFirst() throws {
        let after = try fixtureDocument()
            .placing(palette(2), at: path([0]), zone: .leading)
        #expect(after.node(at: path([0]))?["axis"] == .string("vertical"))
        #expect(JSONPath.get(after.root, path([0]).steps + [.key("children"), .index(0),
                                                            .key("window")]) == .string("乙"))
        #expect(JSONPath.get(after.root, path([0, 1]).steps + [.key("note")])
            == .string("自訂鍵"))
        #expect(JSONPath.get(after.root, path([0, 1]).steps + [.key("ratio")])
            == .number("0.750"))
    }

    /// 往下半放：原本那個節點留在 children[0]，新葉在 [1]，axis 是 horizontal。
    ///
    /// **放的是「乙」而不是「甲」，那是這條測試有沒有牙齒的關鍵。** 原本寫成
    /// `palette(0)`（甲）而目標那一格本來就是 `{"window": "甲"}`，於是兩個 slot 的
    /// window 都是「甲」——把 `[leaf, existing]` 與 `[existing, leaf]` 對調之後這條
    /// **照樣全綠**（2026-08-20 實測）。斷言只看得到「有一個甲」而看不到「誰在前」。
    @Test func droppingBottomSplitsHorizontallyWithTheLabelSecond() throws {
        let after = try fixtureDocument()
            .placing(palette(2), at: path([0]), zone: .bottom)
        #expect(after.node(at: path([0]))?["axis"] == .string("horizontal"))
        #expect(JSONPath.get(after.root, path([0, 0]).steps + [.key("window")])
            == .string("甲"))
        #expect(JSONPath.get(after.root, path([0, 1]).steps + [.key("window")])
            == .string("乙"))
        // 原本那個葉整個退到 [0]，字面值與不認得的鍵一起帶過去。
        #expect(JSONPath.get(after.root, path([0, 0]).steps + [.key("ratio")])
            == .number("0.750"))
        #expect(JSONPath.get(after.root, path([0, 0]).steps + [.key("note")])
            == .string("自訂鍵"))
    }

    /// 正中間換掉一個葉的 window：`ratio` 與 `note` 都留著。整列重建的實作在這條紅。
    @Test func droppingCentreKeepsRatioAndUnknownKeys() throws {
        let after = try fixtureDocument()
            .placing(palette(2), at: path([0]), zone: .center)
        #expect(after.node(at: path([0])) == .object([
            JSONMember(key: "window", value: .string("乙")),
            JSONMember(key: "ratio", value: .number("0.750")),
            JSONMember(key: "note", value: .string("自訂鍵")),
        ]))
    }

    /// **數字 label 寫進去還是數字**（C3）。這一條是 `LabelChoice` 那條突變的第二道網。
    @Test func aNumericLabelStaysNumeric() throws {
        let after = try fixtureDocument()
            .placing(palette(1), at: path([0]), zone: .center)
        #expect(JSONPath.get(after.root, path([0]).steps + [.key("window")]) == .number("7"))
    }

    /// 空的一格（有 display、沒有 tree）：直接放上去**不分割**。
    /// 分割會留一個空的兄弟，而 `{}` 過不了 validate（C2）。
    @Test func droppingOnAVacantRoleJustPlacesTheLeaf() throws {
        let after = try fixtureDocument()
            .placing(palette(0), at: path([], role: "second"), zone: .leading)
        #expect(after.node(at: path([], role: "second"))
            == .object([JSONMember(key: "window", value: .string("甲"))]))
    }

    /// 放上去之後整份檔案仍然過得了 validate——⌘S 的第一道閘門就是它。
    @Test func theResultStillValidates() throws {
        let after = try fixtureDocument()
            .placing(palette(2), at: path([0]), zone: .leading)
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 分割節點的正中間不給換：那會把整個子樹靜默刪掉。UI 到不了這個分支
    /// （分割節點的面積整個被 children 蓋住），與 `canInsertRule` 的 false 分支同一個處境。
    @Test func centreOnASplitChangesNothing() throws {
        let before = try fixtureDocument()
        let after = try before.placing(palette(0), at: path([1]), zone: .center)
        #expect(text(of: after) == text(of: before))
    }

    /// **實測（2026-08-20）**：`trees` 這個鍵本身存在時，`JSONPath.set` 對走不通的
    /// 最後一段是「新的鍵接在尾端」，所以放到一個沒定義過的角色會**成功建出來**，
    /// 不是被拒絕。畫布本來就到不了這裡（`canvasRoles` 只列 display ∪ trees 的角色），
    /// 所以不加守衛——多一道只是多一個沒有輸入踩得到的分支（phase 2a 犯過同一種錯）。
    @Test func anUnknownRoleIsCreated() throws {
        let before = try fixtureDocument()
        let after = try before.placing(palette(0), at: path([], role: "沒有這個角色"),
                                       zone: .leading)
        #expect(text(of: after) != text(of: before))
        #expect(after.node(at: path([], role: "沒有這個角色"))
            == .object([JSONMember(key: "window", value: .string("甲"))]))
    }

    /// 拖走一個葉:父節點塌掉,兄弟頂上來。斷言是「根變成原本那個內部分割」,
    /// 不是「少了一個節點」——後者對「刪錯邊」的突變沒有鑑別力。
    @Test func deletingALeafPromotesItsSibling() throws {
        let before = try fixtureDocument()
        let sibling = before.node(at: path([1]))
        let after = before.deletingPane(at: path([0]))
        #expect(after.node(at: path([])) == sibling)
    }

    @Test func deletingTheOtherSidePromotesTheFirst() throws {
        let before = try fixtureDocument()
        let sibling = before.node(at: path([0]))
        let after = before.deletingPane(at: path([1]))
        #expect(after.node(at: path([])) == sibling)
        // 頂上來的是帶 ratio 與 note 的那個葉,字面值一起帶過來。
        #expect(JSONPath.get(after.root, path([]).steps + [.key("ratio")])
            == .number("0.750"))
    }

    /// 拖走根:**刪掉那個 space 的鍵**,不是留 `{}`(C2)。
    @Test func deletingTheRootRemovesTheRoleKey() throws {
        let after = try fixtureDocument().deletingPane(at: path([]))
        #expect(after.node(at: path([])) == nil)
        // 角色那一層還在(它是一個空物件),但那個 space 的鍵沒了。
        #expect(after.spaceTreeNames(location: "office", profile: "開發",
                                     role: "main") == [])
        #expect(after.spaceTreeRoles(location: "office", profile: "開發")
            == ["main", "third"])
        #expect(LayoutValidator.validate(after.root).isEmpty)
    }

    /// 拖分割線:值寫進**第一個 child**(C1),字面值與 `--save` 同形(C7)。
    @Test func draggingTheDividerWritesTheFirstChildsRatio() throws {
        let after = try fixtureDocument().settingRatio(at: path([]), to: 0.6234)
        #expect(JSONPath.get(after.root, path([0]).steps + [.key("ratio")])
            == .number("0.62"))
        // 沒有把 ratio 也寫到第二個 child 上(那裡讀不到,只會製造垃圾)。
        #expect(JSONPath.get(after.root, path([1]).steps + [.key("ratio")]) == nil)
    }

    /// 夾到 0.05…0.95,與 `CanvasView.dividerFraction` 讀的時候同一組邊界:
    /// 寫得進去卻讀不回來的值會讓畫面與檔案永久不一致。
    @Test func theRatioIsClamped() throws {
        let low = try fixtureDocument().settingRatio(at: path([]), to: -3)
        let high = try fixtureDocument().settingRatio(at: path([]), to: 42)
        #expect(JSONPath.get(low.root, path([0]).steps + [.key("ratio")])
            == .number("0.05"))
        #expect(JSONPath.get(high.root, path([0]).steps + [.key("ratio")])
            == .number("0.95"))
    }

    /// **第一個 child 是分割節點的那條線存不住 ratio**(C1)。`third` 就是那個形狀。
    @Test func aDividerWhoseFirstChildIsASplitCannotHoldARatio() throws {
        let before = try fixtureDocument()
        #expect(before.canSetRatio(at: path([], role: "third")) == false)
        #expect(before.canSetRatio(at: path([])) == true)
        let after = before.settingRatio(at: path([], role: "third"), to: 0.7)
        #expect(text(of: after) == text(of: before))
    }

    /// 非有限的比例整個不改,不要寫出 `null`(`RectTree.stamp` 那側會,因為 jq 印不出
    /// NaN;編輯器有更好的選擇)。
    @Test func aNonFiniteRatioChangesNothing() throws {
        let before = try fixtureDocument()
        #expect(text(of: before.settingRatio(at: path([]), to: .nan)) == text(of: before))
    }

    @Test func flippingSwapsTheAxis() throws {
        let after = try fixtureDocument().flippingAxis(at: path([]))
        #expect(after.node(at: path([]))?["axis"] == .string("horizontal"))
        let back = after.flippingAxis(at: path([]))
        #expect(back.node(at: path([]))?["axis"] == .string("vertical"))
    }

    /// 認不得的 axis 翻成 `vertical`(C6)。拒絕的話那個檔在編輯器裡就修不好,
    /// 而修好它正是使用者開編輯器的理由。
    @Test func flippingRepairsAnUnrecognisedAxis() throws {
        let after = try brokenAxisDocument()
            .flippingAxis(at: PanePath(location: "office", profile: "開發",
                                       role: "main", space: "S-1", slots: []))
        #expect(JSONPath.get(after.root,
                             [.key("office"), .key("profiles"), .key("開發"),
                              .key("spaceTrees"), .key("main"), .key("S-1"), .key("axis")])
                == .string("vertical"))
    }

    /// 葉上的 `axis`(`window` 與 `axis` 並存)不給翻:`window` 優先
    /// (`PaneNode.swift:49`、`LayoutValidator.swift:272`),那個 axis 在畫布上
    /// 根本沒被畫出來,翻它等於改一個使用者看不見的東西。
    ///
    /// **2026-08-20 實測**:拿掉 `flippingAxis` 裡 `!members.contains(where: { $0.key ==
    /// "window" })` 那道守衛,這條測試**仍然全綠**——fixture 裡 `path([0])` 那個葉
    /// (`{"window": "甲", "ratio": 0.750, "note": "自訂鍵"}`)沒有 `axis` 鍵,所以拿掉
    /// window 那道守衛之後 `members.first(where: { $0.key == "axis" })` 仍然回 nil、
    /// 還是回原文件。這份 fixture 目前沒有一個「`window` 與 `axis` 並存」的節點,
    /// 所以沒有輸入踩得到那道守衛。守衛留著是為了 phase 2c(那時葉可能真的帶 axis)。
    @Test func flippingALeafChangesNothing() throws {
        let before = try fixtureDocument()
        #expect(text(of: before.flippingAxis(at: path([0]))) == text(of: before))
    }

    /// 「未指定」有兩種，只有一種刪得掉。**這一條的鑑別力在兩個答案不同**
    /// ——寫成 `true` 或 `false` 的實作都會有一半紅。
    @Test func onlyOneKindOfVacantPaneCanBeDeleted() throws {
        let document = try fixtureDocument()
        // `second` 有 display 沒有 tree：`trees.second` 這個鍵不存在。
        #expect(document.canDeletePane(at: path([], role: "second")) == false)
        // `main` 底下的葉當然刪得掉。
        #expect(document.canDeletePane(at: path([0])) == true)
    }

    /// 刪不掉的那一種真的刪不掉——`deletingPane` 回原文件不變。
    /// 這一條與上面那條是互補的：上面驗守衛的答案，這一條驗那個答案是對的。
    @Test func deletingAPaneThatIsNotThereChangesNothing() throws {
        let before = try fixtureDocument()
        #expect(before.deletingPane(at: path([], role: "second")) == before)
    }
}
