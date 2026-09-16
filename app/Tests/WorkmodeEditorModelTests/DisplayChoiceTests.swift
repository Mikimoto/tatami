import Testing
import WorkmodeDomain
@testable import WorkmodeEditorModel

/// fixture 照 2026-08-21 實測那三台：index 是 **1、3、2**（yabai 回的順序不是
/// index 序，也沒排序過），其中中間那台在 `names` 裡缺席——那是「macOS 查不到
/// 名稱」的形態。另外多一筆只有 macOS 認得的螢幕，用來驗合併是以 yabai 為準。
private let builtIn = "55555555-5555-4555-8555-555555555555"
private let benq = "11111111-1111-4111-8111-111111111111"
private let nameless = "22222222-2222-4222-8222-222222222222"
private let macOSOnly = "00000000-0000-0000-0000-0000DEADBEEF"

private func yabaiDisplays() -> [Display] {
    [Display(uuid: builtIn, index: 1),
     Display(uuid: nameless, index: 3),
     Display(uuid: benq, index: 2)]
}

private func macOSNames() -> [String: (name: String, size: String)] {
    [builtIn: (name: "Built-in Retina Display", size: "1728×1117"),
     benq: (name: "BenQ MA320U", size: "3008×1692"),
     macOSOnly: (name: "不在 yabai 清單裡的螢幕", size: "800×600")]
}

/// 以 yabai 那份為準：macOS 多出來的不進清單。
/// 具體的差異值是 `macOSOnly` 這個 uuid——從 `names` 出發的實作會把它列出來。
@Test func extraScreensMacOSKnowsAboutAreNotListed() {
    let choices = DisplayChoice.merge(yabaiDisplays(), names: macOSNames())
    #expect(!choices.contains { $0.uuid == macOSOnly })
    #expect(choices.count == 3)
}

/// yabai 有而 macOS 查不到名稱的，仍然在清單裡，只是 name/size 是 nil。
/// **這條是這組的重點**：拿掉「仍然列出來」的行為，使用者就選不到那台螢幕了，
/// 而畫面上看不出少了什麼。差異值是 index 3 那一台在不在。
@Test func aScreenWithNoNameIsStillOffered() {
    let choices = DisplayChoice.merge(yabaiDisplays(), names: macOSNames())
    let missing = choices.first { $0.uuid == nameless }
    #expect(missing != nil)
    #expect(missing?.index == 3)
    #expect(missing?.name == nil)
    #expect(missing?.size == nil)
}

/// 順序照 yabai 那份。差異值是 index 序列 `[1, 3, 2]`——照 index 排過的實作
/// 會回 `[1, 2, 3]`。（照 uuid 排恰好與來源同序，這條分不出那一種。）
@Test func theOrderFollowsYabai() {
    let choices = DisplayChoice.merge(yabaiDisplays(), names: macOSNames())
    #expect(choices.map(\.index) == [1, 3, 2])
}

/// 名稱與尺寸真的接上去了，而且是**照 uuid 查**不是照位置：BenQ 在 yabai 那份排
/// 第三、在 `names` 裡排第二，照位置接會把它接成「不在 yabai 清單裡的螢幕」。
@Test func namesAndSizesAreAttached() {
    let choices = DisplayChoice.merge(yabaiDisplays(), names: macOSNames())
    #expect(choices.first?.name == "Built-in Retina Display")
    #expect(choices.first?.size == "1728×1117")
    #expect(choices.last?.name == "BenQ MA320U")
    #expect(choices.last?.size == "3008×1692")
}
