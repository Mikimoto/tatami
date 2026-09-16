import Testing
import WorkmodeEditorModel

@Suite("拖放的酬載")
struct DragPayloadTests {
    @Test func roundTrips() {
        let cases: [DragPayload] = [
            .label(0), .label(12),
            .pane(roleIndex: 0, tabIndex: 0, slots: []),
            .pane(roleIndex: 3, tabIndex: 2, slots: [1, 0, 1]),
        ]
        for payload in cases {
            #expect(DragPayload(text: payload.text) == payload)
        }
    }

    /// 兩種來源的字首不同，落點才分得出來。
    @Test func theTwoKindsDoNotCollide() {
        #expect(DragPayload(text: DragPayload.label(1).text) != .pane(roleIndex: 1, tabIndex: 0, slots: []))
    }

    /// 解不出來一律 nil：UI 據此整個忽略那次放下。
    @Test func garbageIsRefused() {
        // 四段的那幾筆（`P:x:0:`／`P:0:x:`／`P:0:0:1,x`）才踩得到欄位解析；
        // 三段的那幾筆驗的是 arity。兩種都要有。
        for text in ["", "L", "L:", "L:x", "P:0", "P:0:1,0",
                     "P:x:0:", "P:0:x:", "P:0:0:1,x", "X:0", "L:0:0"]
        {
            #expect(DragPayload(text: text) == nil, "\(text) 應該解不出來")
        }
    }

    /// slot 只有 0 與 1（`PaneNode` 的 split 恰好兩個 children，C5）。
    ///
    /// **這些字串必須是四段的**。2026-08-23 之前它們寫成 `"P:0:2"`（三段），
    /// 在 arity 那一關就被擋，**永遠走不到 slot 檢查**——實測拿掉
    /// `allSatisfy({ $0 == 0 || $0 == 1 })` 這條測試照樣全綠。
    @Test func slotsOutsideZeroAndOneAreRefused() {
        #expect(DragPayload(text: "P:0:0:2") == nil)
        #expect(DragPayload(text: "P:0:0:-1") == nil)
        #expect(DragPayload(text: "P:0:0:1,2") == nil)
        // 正控制：同樣四段、slot 合法的解得出來，證明上面三條不是被 arity 擋掉的。
        #expect(DragPayload(text: "P:0:0:1,0")
            == .pane(roleIndex: 0, tabIndex: 0, slots: [1, 0]))
    }

    /// 三個非負整數欄位各自要擋負數。同上——四段才踩得到。
    @Test func negativeIndexesAreRefused() {
        #expect(DragPayload(text: "P:-1:0:") == nil)
        #expect(DragPayload(text: "P:0:-1:") == nil)
        #expect(DragPayload(text: "L:-1") == nil)
        // 正控制。
        #expect(DragPayload(text: "P:0:0:") == .pane(roleIndex: 0, tabIndex: 0, slots: []))
    }
}

/// `tabIndex` 分得出「同一個角色的不同分頁」。少了它，從 space 分頁拖出來的窗格
/// 會被當成「目前可見」那棵樹的窗格處理——刪的是另一個版面，而畫面上零訊號。
@Test func twoTabsOfTheSameRoleAreDifferentPayloads() {
    let visible = DragPayload.pane(roleIndex: 0, tabIndex: 0, slots: [1])
    let space = DragPayload.pane(roleIndex: 0, tabIndex: 1, slots: [1])
    #expect(visible.text != space.text)
    #expect(DragPayload(text: space.text) == space)
}

/// 舊格式（三段）現在解不出來。這不是相容性問題——payload 只活在一次拖放之內，
/// 而解不出來的下場是 UI 整個忽略那次放下，比解成別的分頁安全。
@Test func theOldThreePartPaneFormatIsRefused() {
    #expect(DragPayload(text: "P:0:1,0") == nil)
}
