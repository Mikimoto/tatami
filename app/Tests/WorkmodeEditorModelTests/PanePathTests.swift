import Testing
import WorkmodeDomain
@testable import WorkmodeEditorModel

// `PanePath` 是「畫布上一個窗格在哪」的五段。這裡驗的只有 `roleSteps`——所有的
// 編輯動作（`placing`／`deletingPane`／`settingRatio`／`flippingAxis`）都經過它，
// 所以那一支對了，那四支就跟著對了。

private func path(space: String = "U-1", slots: [Int] = []) -> PanePath {
    PanePath(location: "home", profile: "開發", role: "main", space: space, slots: slots)
}

/// **`roleSteps` 是整份程式碼裡唯一決定「編的是哪棵樹」的地方。**
///
/// 2026-08-30 之前 `space` 是 Optional，nil 代表 `trees.<角色>`（分頁列的第一頁
/// 「目前可見」）。那條路徑拿掉之後它是必填的——漏掉會是編譯錯誤而不是
/// 「靜默編到別的版面」。
@Test func roleStepsAlwaysGoThroughSpaceTrees() {
    #expect(path().roleSteps == [
        .key("home"), .key("profiles"), .key("開發"),
        .key("spaceTrees"), .key("main"), .key("U-1"),
    ])
}

/// 遞迴往下時 space 要跟著走，否則第二層以下會指到另一頁的樹。
@Test func walkingDownKeepsTheSpace() {
    let child = path(space: "U-2").child(0).child(1)
    #expect(child.space == "U-2")
    #expect(child.steps == [
        .key("home"), .key("profiles"), .key("開發"),
        .key("spaceTrees"), .key("main"), .key("U-2"),
        .key("children"), .index(0), .key("children"), .index(1),
    ])
}

@Test func walkingBackUpKeepsTheSpace() {
    let parent = path(space: "U-2", slots: [0, 1]).parent
    #expect(parent?.space == "U-2")
    #expect(parent?.slots == [0])
}
