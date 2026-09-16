import Foundation
import Testing
@testable import WorkmodeWire

// 前面幾支測試用的都是挑過的 fixture，證明的是各條規則個別成立。
// 這支改用 `examples/layout.json`——那是使用者真實設定的副本（`jq .` 產出），
// 有註解排版、真實的鍵序與巢狀深度，fixture 守邊界、它守常見路徑，兩種都要有。
//
// 2026-09-15 之前這裡讀的是 `scripts/layout.json`，也就是**使用者正在跑的那份**。
// 設定搬到 `~/.config/tatami` 之後 repo 裡沒有那個檔了；改指 repo 內的副本之後
// 這條在任何 checkout、任何機器上都跑得起來（之前在 detached worktree 裡跑不動）。

/// 從 `#filePath` 往上爬到 repo 根目錄。
///
/// 不用工作目錄：`swift test` 的 cwd 不保證是 package 根目錄，
/// 而 `#filePath` 在編譯期就釘死了這支檔案的絕對位置。
private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // app/Tests/WorkmodeWireTests/
        .deletingLastPathComponent() // app/Tests/
        .deletingLastPathComponent() // app/
        .deletingLastPathComponent() // repo 根目錄
}

/// parse → format → 加結尾換行，必須與原檔逐位元組相同。
///
/// `format()` 不含結尾換行（見它的 doc），而 `jq .` 寫出來的檔尾有一個，所以這裡補上。
/// 這條紅了先跑 `diff <(jq . examples/layout.json) examples/layout.json`：
/// 有輸出代表檔案已經不是 jq 格式（被手改過），那不是這層的問題。
@Test func realLayoutJSONRoundTripsByteForByte() throws {
    let url = repoRoot().appendingPathComponent("examples/layout.json")
    let original = try String(contentsOf: url, encoding: .utf8)

    // 沒有這條的話，路徑算錯會退化成「兩個空字串相等」的假綠。
    #expect(original.count > 100, "讀到的檔案太小，路徑大概算錯了：\(url.path)")

    let reformatted = try JSONWriter.format(JSONParser.parse(original)) + "\n"
    #expect(reformatted == original)
}

/// 最外層鍵序不能被 parse 洗掉：`windows` 是共用的視窗總表，刻意排第一個。
@Test func realLayoutJSONKeepsTopLevelKeyOrder() throws {
    let url = repoRoot().appendingPathComponent("examples/layout.json")
    let original = try String(contentsOf: url, encoding: .utf8)
    #expect(original.count > 100, "讀到的檔案太小，路徑大概算錯了：\(url.path)")

    guard case let .object(members) = try JSONParser.parse(original) else {
        Issue.record("layout.json 的最外層不是物件")
        return
    }
    #expect(members.first?.key == "windows")
    #expect(members.count >= 2)
}
