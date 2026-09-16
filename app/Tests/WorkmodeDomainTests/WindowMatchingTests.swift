import Testing
@testable import WorkmodeDomain

// 視窗比對的三支。斷言分三類：
//   1. tests/test_workmode.sh 既有的 23 條（15 + 5 + 3，每條都標了它翻譯自哪一行）
//   2. 2026-08-14 拿本機的 awk 20200816 對 scripts/workmode.sh 實跑挖出來的方言
//      邊界——`\b` 是 backspace、`a|` 是語法錯誤、`{` 有時是量詞有時是字面字元、
//      pattern 裡的 NUL 等於字串結尾，這些從程式碼一條都讀不出來
//   3. 兩處**刻意不對齊**的分歧，見檔尾的 knownDivergence… 那組
//
// 這一份全部在位元組上工作。用 Character 會有三個地方靜默改行為：NFC 與 NFD 的
// 同一個字在 bash 相等而在 Swift 的 String 不相等、`\r\n` 在 Swift 是一個
// Character、awk 的 `.` 吃的是一個位元組。

// MARK: - 語料（與 tests/test_workmode.sh 逐字相同）

/// test_workmode.sh:61
private let dumpSlash = "180\thttps://github.com/example-org/\texample-org"

/// test_workmode.sh:66-69。實機觀察到的失效狀態：Chat 視窗的兩個分頁標題都跳成
/// 「專案甲」，沒有任何一個顯示「專案乙組」。
private let dumpDrifted = [
    "170\thttps://example.com\t無關視窗",
    "162\thttps://chat.google.com/app/chat/CHATROOM0001\tDCF 專案甲 - Chat",
    "162\thttps://chat.google.com/app/chat/CHATROOM0002\tDCF 專案甲 - Chat",
].joined(separator: "\n")

/// test_workmode.sh:479-481
private let dumpMeta = ["300\thttps://x\ta.b", "301\thttps://x\taXb"].joined(separator: "\n")

/// test_workmode.sh:667-670。第一筆刻意是同一個視窗的非當前分頁：否則
/// 「取當前那個」與「取第一個」分不出來。
private let dump4 = [
    "191\thttps://github.com/example-org\texample-org\t0",
    "191\thttps://example.com/now\t現在這頁\t1",
    "192\thttps://other\t其他\t1",
].joined(separator: "\n")

/// test_workmode.sh:628-631。兩個 key 都是中文且值不同——換成 awk 實作時，
/// 至少一條會拿到別人的 id。
private let idmap = ["工作瀏覽\t161", "終端機\t115", "Chat\t162"].joined(separator: "\n")

// MARK: - find_windows：既有的 15 條（test_workmode.sh:458-483）

@Test func urlExactHitsTheOneWindowThatHasTheOrgHomepage() throws {
    // test_workmode.sh:458
    #expect(try joined("url-exact", "https://github.com/example-org", dump) == "161 ")
}

@Test func urlContainsHitsTheChatWindowByDomain() throws {
    // test_workmode.sh:459
    #expect(try joined("url-contains", "chat.google.com", dump) == "162 ")
}

@Test func titleRegexHitsTheChatWindowByTitle() throws {
    // test_workmode.sh:460
    #expect(try joined("title-regex", "專案乙組 - Chat", dump) == "162 ")
}

@Test func urlContainsReturnsEveryCandidateNotJustTheFirst() throws {
    // test_workmode.sh:461。子字串比對會命中三個視窗，呼叫端要看到全部才能
    // 做「先到先得」的認領，以及在誤中多個時把候選印出來。
    #expect(try joined("url-contains", "github.com/example-org", dump) == "161 162 163 ")
}

@Test func urlExactMissesCleanly() throws {
    // test_workmode.sh:462
    #expect(try joined("url-exact", "https://no.such", dump) == "")
}

@Test func appKindDoesNotConsumeTheTabDump() throws {
    // test_workmode.sh:463。分頁清單只涵蓋 Safari，其他 app 要從 yabai query 取。
    #expect(try joined("app", "Ghostty", dump) == "")
}

@Test func appKindIsNotAnError() throws {
    // test_workmode.sh:464（rc=0）。nil 就是「這個類型不由我處理」，
    // 與「命中零個」是兩回事——後者是空陣列。
    #expect(try found("app", "Ghostty", dump) == nil)
}

@Test func unknownKindIsAnError() throws {
    // test_workmode.sh:465（rc=2）。呼叫端要能區分「沒命中」與「設定寫錯」。
    #expect(throws: WindowMatchError.unknownKind("bogus-type")) {
        try found("bogus-type", "x", dump)
    }
}

@Test func urlExactToleratesOneTrailingSlash() throws {
    // test_workmode.sh:469
    #expect(try joined("url-exact", "https://github.com/example-org", dumpSlash) == "180 ")
}

@Test func domainStillFindsTheWindowWhenTitlesDrift() throws {
    // test_workmode.sh:470
    #expect(try joined("url-contains", "chat.google.com", dumpDrifted) == "162 ")
}

@Test func titleAloneCannotFindTheWindowWhenTitlesDrift() throws {
    // test_workmode.sh:471。這正是那條規則改用網域的原因。
    #expect(try joined("title-regex", "專案乙組 - Chat", dumpDrifted) == "")
}

@Test func theFallbackAlternationRecognisesTheDriftedTitle() throws {
    // test_workmode.sh:472。原本寫成「專案甲組」少一個字，永遠不中。
    #expect(try joined("title-regex", "專案乙組 - Chat|專案甲 - Chat", dumpDrifted) == "162 ")
}

@Test func urlContainsReturnsEmptyWhenThereIsNoChatTab() throws {
    // test_workmode.sh:473
    #expect(try joined("url-contains", "chat.google.com", dumpSlash) == "")
}

@Test func titleRegexDoesNotHitSomeOtherWindowWhenTheTitleIsAbsent() throws {
    // test_workmode.sh:474
    #expect(try joined("title-regex", "不會出現的字串", dump) == "")
}

@Test func escapedPatternMatchesLiterally() throws {
    // test_workmode.sh:482-483。`escape_ere 'a.b'` 產生 `a\.b`；這條在改用
    // ENVIRON 之前會回 "300 301 "，因為 awk -v 會把反斜線吃掉、點又成了萬用字元。
    #expect(try joined("title-regex", "a\\.b", dumpMeta) == "300 ")
}

// MARK: - id_for_label：既有的 5 條（test_workmode.sh:633-642）

@Test func multibyteLabelTakesItsOwnID() {
    // test_workmode.sh:633-634
    #expect(WindowMatching.idForLabel("終端機", in: idmap) == "115")
}

@Test func theOtherMultibyteLabelDoesNotInheritThePreviousID() {
    // test_workmode.sh:635-636。awk 版對這兩個 label 都會回兩行。
    #expect(WindowMatching.idForLabel("工作瀏覽", in: idmap) == "161")
}

@Test func asciiLabelWorksToo() {
    // test_workmode.sh:637-638
    #expect(WindowMatching.idForLabel("Chat", in: idmap) == "162")
}

@Test func missingLabelIsAFailure() {
    // test_workmode.sh:639-640（rc=1）
    #expect(WindowMatching.idForLabel("沒這個", in: idmap) == nil)
}

@Test func missingLabelPrintsNothing() {
    // test_workmode.sh:641-642（stdout 不得有內容）。與上一條是同一次呼叫的兩個
    // 面向：rc 與 stdout。nil 同時代表兩者，但拆成兩條才對得回 bash 的兩條。
    let value = WindowMatching.idForLabel("沒這個", in: idmap)
    #expect((value ?? "").isEmpty)
}

// MARK: - current_tab_url：既有的 3 條（test_workmode.sh:672-674）

@Test func takesTheCurrentTabNotTheFirstTab() {
    // test_workmode.sh:672
    #expect(WindowMatching.currentTabURL(window: "191", dump: dump4) == "https://example.com/now")
}

@Test func eachWindowTakesItsOwnCurrentTab() {
    // test_workmode.sh:673
    #expect(WindowMatching.currentTabURL(window: "192", dump: dump4) == "https://other")
}

@Test func unknownWindowHasNoURL() {
    // test_workmode.sh:674
    #expect(WindowMatching.currentTabURL(window: "999", dump: dump4) == nil)
}
