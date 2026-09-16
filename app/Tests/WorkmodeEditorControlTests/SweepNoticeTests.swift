import Testing
import WorkmodeEditorModel

// `sweepNotice` 是 internal——`@testable import` 才看得到它，
// 它也是為了測一支不對外的純函式才用 `@testable`。
@testable import WorkmodeEditorControl

@Suite("刪規則連帶掃掉窗格時要出聲")
struct SweepNoticeTests {
    /// 空清單不出聲。刪一條沒人用的規則不該多跳一個對話框。
    @Test func nothingRemovedMeansNothingSaid() {
        #expect(EditorController.sweepNotice([]) == nil)
    }

    /// 出聲要講**幾個**與**在哪**，兩者都是使用者無法從畫面推出來的
    /// ——被掃掉的窗格散在他沒有打開的 profile 與分頁上。
    @Test func theNoticeNamesTheCountAndThePlaces() throws {
        let text = try #require(EditorController.sweepNotice([
            SweptPane(location: "office", profile: "開發", role: "main",
                      space: nil, slots: [1]),
            SweptPane(location: "office", profile: "開發", role: "second",
                      space: "S-編碼", slots: []),
        ]))
        #expect(text.contains("2"))
        #expect(text.contains("office"))
        #expect(text.contains("開發"))
        #expect(text.contains("main"))
        // 分頁的 uuid 要在，不然使用者會以為那是 `trees` 那一棵
        // （`workmode` 套的那半，編輯器碰不到但掃除照樣要掃）。
        #expect(text.contains("S-編碼"))
        // ⌘Z 要講，因為這個動作有損。
        #expect(text.contains("⌘Z"))
    }
}
