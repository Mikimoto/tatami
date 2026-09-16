import Foundation
import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

// 規則的 `launch` 欄位（`--launch` 要開哪個 app）。它與其他五個欄位有兩點不同：
// 檔案裡可以整個不存在，而**打成空字串是刪掉那個鍵**。
//
// 這裡不重驗「編輯不會弄壞別的鍵」——那條由 `RuleEditTests` 的
// `editingDoesNotSwallowKeysTheProjectionCannotSee` 守著整個 `settingRuleField`。

/// 共用層兩條：第一條沒有 `launch`，第二條有（而且它的 `match` 是 url 類，
/// 也就是這個欄位存在的唯一理由）。第二條另外帶一個投影看不見的 `note` 鍵。
private let launchSample = """
{"windows":[{"label":"Z","match":["app","ZZ"]},\
{"label":"A","match":["url-contains","aa"],"launch":"Safari","note":"別動我"}]}
"""

private func launchDoc() throws -> LayoutDocument {
    try LayoutDocument(root: JSONParser.parse(launchSample))
}

private func launchRow(_ layout: LayoutDocument, _ slot: Int) -> RuleRow? {
    layout.allRules.first { $0.scope == .shared && $0.index == slot }?.row
}

/// 存檔會寫出的那份文字（`JSONWriter.format` 是唯一的寫入器，jq 格式）。
private func text(_ layout: LayoutDocument) -> String {
    JSONWriter.format(layout.root)
}

// MARK: - 投影

/// 沒有那個鍵就是 nil，不是空字串。
///
/// 鑑別值就是 nil 與 `""` 的差別：表格靠它分「沒設」與「設成空的」，而後者是
/// 使用者剛把一格清掉、下一秒就會被存成「刪掉那個鍵」的中間狀態。
@Test func aRuleWithoutALaunchKeyProjectsNil() throws {
    #expect(try launchRow(launchDoc(), 0)?.launch == nil)
}

@Test func aLaunchKeyProjectsItsValue() throws {
    #expect(try launchRow(launchDoc(), 1)?.launch == "Safari")
}

/// 非字串的 `launch` 投影成它印出來的樣子，不是 nil。
///
/// 與 `fallback` 同一條理由：要修的東西不該從表格上消失。
@Test func aNonStringLaunchStillShowsUp() throws {
    let odd = try LayoutDocument(
        root: JSONParser.parse(#"{"windows":[{"label":"Z","match":["app","ZZ"],"launch":7}]}"#)
    )
    #expect(launchRow(odd, 0)?.launch == "7")
}

// MARK: - 編輯

/// 本來沒有就加上去，而且**接在該列的尾端**（`JSONWriter` 照來源鍵序輸出，
/// `JSONPath.set` 對新鍵是接尾端）。
@Test func settingLaunchOnARuleThatLacksItAddsTheKeyAtTheEnd() throws {
    let after = try launchDoc().settingRuleField(.shared, index: 0,
                                                 field: .launch, to: "Ghostty")
    #expect(launchRow(after, 0)?.launch == "Ghostty")
    // 鍵序：`launch` 出現在那一列的 `"ZZ"` 之後。比位置而不是比整段字串，
    // 因為寫入器是 jq 格式（多行縮排），而這條要驗的只有「接在尾端」。
    let written = text(after)
    let matchAt = written.range(of: "\"ZZ\"")
    let launchAt = written.range(of: "\"launch\"")
    #expect(matchAt != nil)
    #expect(launchAt != nil)
    if let matchAt, let launchAt {
        #expect(matchAt.lowerBound < launchAt.lowerBound, "launch 沒有接在尾端")
    }
}

/// 改一個已經有的值。
@Test func settingLaunchReplacesAnExistingValue() throws {
    let after = try launchDoc().settingRuleField(.shared, index: 1,
                                                 field: .launch, to: "Chrome")
    #expect(launchRow(after, 1)?.launch == "Chrome")
    // 同一列投影看不見的鍵原樣留著。
    #expect(text(after).contains("別動我"))
}

/// **打成空字串是刪掉整個鍵，不是寫 `"launch": ""`。**
///
/// 鑑別值有兩個，兩個都要：投影回 nil，**而且**位元組裡沒有 `launch` 這個字。
/// 只驗前者的話「寫 `null`」的實作照樣通過（`RuleRow` 對 `null` 會投影成 `"null"`
/// 而不是 nil——所以其實不會過，但只驗投影就沒有東西在守「檔案裡真的乾淨了」）。
@Test func clearingLaunchRemovesTheKeyEntirely() throws {
    let after = try launchDoc().settingRuleField(.shared, index: 1, field: .launch, to: "")
    #expect(launchRow(after, 1)?.launch == nil)
    #expect(!text(after).contains("launch"))
    // 同一列的其他東西一個都沒掉。
    #expect(launchRow(after, 1)?.matchValue == "aa")
    #expect(text(after).contains("別動我"))
}

/// 本來就沒有那個鍵而打成空字串 → 文件完全不變。
///
/// `JSONPath.delete` 對走不通的路徑會 throw，而 `rebuilt` 把它吞成「回原文件」。
/// 這一條在守那件事真的發生——沒有它的話，一個對不存在的鍵 throw 到外面的實作
/// 會讓編輯器當掉，而使用者只是在一個空格裡按了 Enter。
@Test func clearingALaunchThatIsNotThereChangesNothing() throws {
    let before = try launchDoc()
    #expect(before.settingRuleField(.shared, index: 0, field: .launch, to: "") == before)
}

/// 打空白（不是空字串）不算清掉——那是一個一個字元都算數的值。
///
/// 這一條標的是**刻意的**行為：`validate` 對這個欄位什麼都不查，而
/// `LaunchableApps.named` 只把**空字串**當成沒設。所以 `" "` 會被當成一個 app 名字
/// 送去 `open -a`，然後失敗並印一行。留著這個縫是因為替使用者 trim 就得決定
/// 「哪些空白算空白」（全形空白？NBSP？），而那份清單本身就是新的錯誤來源。
@Test func aLaunchOfOneSpaceIsAValueNotAClear() throws {
    let after = try launchDoc().settingRuleField(.shared, index: 0, field: .launch, to: " ")
    #expect(launchRow(after, 0)?.launch == " ")
}
