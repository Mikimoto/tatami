import Testing
import WorkmodeEditorModel

// `templateVacancyNotice` 與 `templateTooSmallNotice` 是 internal，
// 先例是 `SweepNoticeTests.swift`。
@testable import WorkmodeEditorControl

@Suite("套版面模板時要出聲")
struct TemplateNoticeTests {
    /// 全部填滿就不出聲。多一個「一切正常」的對話框只會讓下一則被忽略。
    @Test func aFullTemplateSaysNothing() {
        #expect(EditorController.templateVacancyNotice(.grid4, vacant: 0) == nil)
    }

    /// 有空格一定要講，**而且要講 ⌘S 會被擋**：空的 `{}` 在
    /// `LayoutValidator.splitNodeChecks` 報「節點既沒有 window 也沒有 axis」，
    /// 使用者不會自己把「存不了檔」連到「剛才按的那顆按鈕」。
    @Test func vacantSlotsWarnAboutTheSaveGate() throws {
        let text = try #require(EditorController.templateVacancyNotice(.grid4, vacant: 2))
        #expect(text.contains("田字"))
        #expect(text.contains("2"))
        #expect(text.contains("⌘S"))
    }

    /// 放不下要講**現在幾個**與**放得下幾個**，兩個數字都要有：
    /// 只講其中一個的話使用者不知道要移掉幾個。
    @Test func tooSmallNamesBothNumbers() {
        let text = EditorController.templateTooSmallNotice(.split2Vertical, windows: 4)
        #expect(text.contains("4"))
        #expect(text.contains("2"))
        #expect(text.contains("左右二分"))
    }
}
