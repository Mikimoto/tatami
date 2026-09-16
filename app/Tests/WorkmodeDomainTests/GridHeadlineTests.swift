import Testing
import WorkmodeDomain

// 抬頭是**判斷**不是排版：這個面板排的是焦點視窗，不是滑鼠底下那一個
// （`GridTarget` 走 `focusedWindow()`），而現在的面板一個字都沒說。
// 文字放 Domain 的理由與 `SpaceOptions` 的句子逐字相同：畫面那層零測試。

@Test func theHeadlineNamesTheAppAndTheGrid() {
    let text = GridHeadline.text(app: "Calendar", displayIndex: "2", columns: 6, rows: 4)
    #expect(text == "Calendar · screen 2 · 6×4")
}

/// app 名字查不到時**不要留一個空的間隔號**——那看起來像壞的。
@Test func anUnknownAppFallsBackToTheWindowItself() {
    let text = GridHeadline.text(app: "", displayIndex: "1", columns: 3, rows: 2)
    #expect(text == "焦點視窗 · screen 1 · 3×2")
}

/// 格數被夾到至少 1：`GridSelection` 對 0 是 `max(1, …)`，抬頭要說同一件事，
/// 不然畫面上寫 `0×4` 而格線畫的是 1 欄。
@Test func theHeadlineClampsTheGridLikeTheGeometryDoes() {
    #expect(GridHeadline.text(app: "Zed", displayIndex: "1", columns: 0, rows: -3)
        == "Zed · screen 1 · 1×1")
}
