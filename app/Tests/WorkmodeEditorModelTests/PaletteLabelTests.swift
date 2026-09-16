import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

@Suite("可拖的 label 是生效的那一份")
struct PaletteLabelTests {
    /// 沒有自己 windows 的 profile：最外層接上地點層，順序照來源。
    @Test func mergesSharedThenLocation() throws {
        let choices = try fixtureDocument().paletteLabels(location: "office", profile: "開發")
        #expect(choices.map(\.display) == ["甲", "7", "乙"])
    }

    /// **數字 label 帶的是數字**。這一條是 C3 的守衛：拿掉它，把 `value` 換成
    /// `.string(display)` 的實作照樣讓上面那條全綠，而存檔會被 validator 擋下。
    @Test func keepsTheJSONValueNotTheDisplayString() throws {
        let choices = try fixtureDocument().paletteLabels(location: "office", profile: "開發")
        #expect(choices[1].value == .number("7"))
        #expect(choices[1].value != .string("7"))
    }

    /// 自己有 windows 的 profile：**整塊取代**，共用層與地點層都不算。
    @Test func profileWindowsReplaceInsteadOfAppend() throws {
        let choices = try fixtureDocument().paletteLabels(location: "office", profile: "會議")
        #expect(choices.map(\.display) == ["丙"])
    }

    /// 地點不存在：回空清單而不是崩。編輯器要開得起壞檔。
    @Test func unknownLocationIsEmpty() throws {
        #expect(try fixtureDocument().paletteLabels(location: "沒有", profile: "開發").isEmpty)
    }
}
