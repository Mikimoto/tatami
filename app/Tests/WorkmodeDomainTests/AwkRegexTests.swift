import Testing
@testable import WorkmodeDomain

// awk 的 ERE 方言，以及位元組層比對的其他四個面向（sort -u、strnum、-v 的跳脫、
// 畸形 dump）。全部是 2026-08-14 拿本機的 awk 20200816 對 scripts/workmode.sh
// 實跑挖出來的，不是照 POSIX 規格推的。
//
// 與 WindowMatchingTests 分開，因為那邊驗的是「三支查詢函式回什麼」，這邊驗的是
// 它們底下那顆引擎的方言——`\b` 是 backspace、`a|` 是語法錯誤、`{` 有時是量詞
// 有時是字面字元、pattern 裡的 NUL 等於字串結尾。
//
// 語料與呼叫縮寫在 WindowMatchingFixtures.swift。

private func regexMatches(_ pattern: String, _ subject: String) throws -> Bool {
    try AwkRegex(pattern: pattern).matches(subject)
}

private func regexThrows(_ pattern: String) -> Bool {
    do { _ = try AwkRegex(pattern: pattern); return false } catch { return true }
}

// MARK: - awk 的 ERE 方言（全部實測，2026-08-14，awk version 20200816）

/// Swift 的 `Regex` 與 NSRegularExpression 都是 PCRE 風格，這一組就是它們與 awk
/// 分岔的地方。每一條都拿
/// `WM_PAT=… LC_ALL=C awk -v s=… 'BEGIN{ print (s ~ ENVIRON["WM_PAT"]) }'` 跑過。
@Test func awkDialectEscapesAreNotPCRE() throws {
    // \d 不是數字類，是字面的 d
    #expect(try !regexMatches("a\\db", "a5b"))
    #expect(try regexMatches("a\\db", "adb"))
    // \b 不是 word boundary，是 backspace（0x08）
    #expect(try !regexMatches("\\b", "b"))
    #expect(try regexMatches("\\b", "x\u{08}y"))
    // \+ 是字面的加號，不是量詞
    #expect(try regexMatches("a\\+b", "a+b"))
    #expect(try !regexMatches("a\\+b", "ab"))
    // \t \n \r \f \v \a 是控制字元；\ 加上不認得的字元退化成那個字元本身
    #expect(try regexMatches("\\t", "x\ty"))
    #expect(try regexMatches("\\q", "q"))
    // \101 是八進位；\8 也走同一條路（awk 收的是十進位數字再照八進位累加）
    #expect(try regexMatches("\\101", "A"))
    #expect(try regexMatches("\\8", "x\u{08}y"))
}

@Test func awkDialectHasNoPCREExtensions() throws {
    // 非捕獲群組、lookahead、非貪婪都不存在——前兩個是語法錯誤
    #expect(regexThrows("(?:a)"))
    #expect(regexThrows("(?=a)"))
    // `a*?` 不是非貪婪，是「(a*) 再套一個 ?」，所以配得上空字串
    #expect(try regexMatches("a*?", "zzz"))
    // \< \> 不是 word boundary，是字面的角括號
    #expect(try !regexMatches("\\<a", "a"))
    #expect(try regexMatches("\\<a", "<a"))
}

@Test func awkDialectRejectsEmptyBranches() throws {
    // Swift 的 Regex 收得下這四個（空分支合法），awk 一律 rc=2
    #expect(regexThrows("a|"))
    #expect(regexThrows("|a"))
    #expect(regexThrows("(a|)"))
    #expect(regexThrows("(|)"))
    // 但空的**群組**合法
    #expect(try regexMatches("()", "x"))
    #expect(try regexMatches("(())", "x"))
    #expect(try regexMatches("a()b", "ab"))
}

@Test func awkDialectQuantifierNeedsSomethingToRepeat() throws {
    #expect(regexThrows("*a"))
    #expect(regexThrows("+"))
    #expect(regexThrows("?"))
    #expect(regexThrows("(*)"))
    // 但量詞可以疊，而且 `^` 也算一個可以被重複的 primary
    #expect(try regexMatches("a**", "x"))
    #expect(try regexMatches("^*", "x"))
    #expect(try regexMatches("$*", "x"))
}

@Test func awkDialectAnchorsAreAsymmetric() throws {
    // `^` 只能當一段串接的第一個元素
    #expect(regexThrows("a^b"))
    #expect(regexThrows("(a)^b"))
    #expect(regexThrows("^^a"))
    #expect(try regexMatches("a|^b", "b")) // 分支的開頭也算開頭
    // `$` 哪裡都能放，只是放中間就永遠配不到
    #expect(try !regexMatches("$a", "a$a"))
    #expect(try !regexMatches("a$$", "a"))
    #expect(try regexMatches("a$|b", "b"))
}

@Test func awkDialectBracesAreSometimesLiteral() throws {
    // 接得出合法區間才是量詞
    #expect(try regexMatches("a{2}", "aab"))
    #expect(try !regexMatches("a{2}", "ab"))
    #expect(try regexMatches("a{2,}", "aab"))
    #expect(try regexMatches("a{1,3}", "ab"))
    // 接不出來就是字面的大括號
    #expect(try regexMatches("a{", "xa{y"))
    #expect(try regexMatches("a{,2}", "xa{,2}y"))
    #expect(try regexMatches("}", "x}y"))
    #expect(try regexMatches("{", "x{y"))
    // 但「像區間卻沒收尾」與「上下界顛倒」是錯誤
    #expect(regexThrows("{2"))
    #expect(regexThrows("a{2,1}"))
    // 沒有東西可以重複的位置上，接得出合法區間反而是錯誤
    #expect(regexThrows("{1,2}"))
}

@Test func awkDialectBrackets() throws {
    #expect(try regexMatches("[]a]", "x]y")) // 緊接的 ] 是字面的
    #expect(try regexMatches("[a-]", "-")) // 結尾的 - 是字面的
    #expect(try regexMatches("[-a]", "-"))
    #expect(try regexMatches("[\\t]", "x\ty")) // bracket 裡也做跳脫
    #expect(try regexMatches("[\\]]", "x]y"))
    #expect(try regexMatches("[[:digit:]]", "a5b"))
    #expect(try !regexMatches("[[:alpha:]]", "5"))
    #expect(regexThrows("["))
    #expect(regexThrows("[a"))
    #expect(regexThrows("[]")) // ] 被吃成字面字元，於是沒有收尾
    #expect(regexThrows("[a\\]"))
    // 認不得的類別**不是**錯誤：awk 印一行警告就繼續，那個類別什麼都不加
    #expect(try !regexMatches("[[:foo:]]", "a"))
    #expect(try regexMatches("[[:foo:]a]", "a"))
    #expect(try regexMatches("[^[:foo:]]", "a"))
}

@Test func awkDialectUnmatchedParenIsLiteralButUnmatchedOpenIsNot() throws {
    #expect(try regexMatches("a)", "a)"))
    #expect(regexThrows("(a"))
}

@Test func awkDialectMatchesBytesNotCharacters() throws {
    // `.` 吃一個位元組：三位元組的「終」要三個點
    #expect(try !regexMatches("^.$", "終"))
    #expect(try regexMatches("^...$", "終"))
    // bracket 收的也是位元組，所以 [終工] 會誤中只共用第一個位元組的字
    #expect(try regexMatches("[終工]", "工"))
    #expect(try regexMatches("[^終]", "工"))
    // 但 `.` 不吃換行也不吃 NUL
    #expect(try !regexMatches("^.$", "\n"))
}

@Test func awkDialectNULInThePatternMeansEndOfString() throws {
    // awk 的比對器跑在 C 字串上，所以 pattern 裡的 NUL 就是字串結尾。
    // 四條互相印證：`\` 與 `$` 等價、`a\` 與 `a$` 等價、NUL 之後的東西永遠配不到。
    #expect(try regexMatches("\\", "anything"))
    #expect(try regexMatches("\\", ""))
    #expect(try regexMatches("a\\", "xa"))
    #expect(try !regexMatches("a\\", "ax"))
    #expect(try !regexMatches("a\\0b", "ab"))
    #expect(try !regexMatches("\\0a", "a"))
}

@Test func awkRegexHasNoCatastrophicBacktracking() throws {
    // Thompson 模擬而不是回溯，所以這個在 PCRE 會跑到天荒地老的 pattern
    // 在這裡是線性的。它同時也是「設定檔寫壞不會把腳本掛死」的保證。
    let subject = String(repeating: "a", count: 40) + "c"
    #expect(try !regexMatches("^(a*)*b$", subject))
    #expect(try regexMatches("^(a|aa)+$", String(repeating: "a", count: 40)))
}

// MARK: - sort -u：排序且去重

@Test func candidatesAreSortedAndDeduplicated() throws {
    // 十進位字串是字典序不是數值序（bash 是 `sort -u`，實測回 10 100 2 9）
    let messy = ["10\tx\ta", "9\tx\tb", "100\tx\tc", "2\tx\td"].joined(separator: "\n")
    #expect(try joined("url-contains", "x", messy) == "10 100 2 9 ")
}

@Test func duplicateIDsCollapse() throws {
    // 同一個視窗的兩個分頁都命中時只回一次，而且順序不是來源順序。
    let repeated = ["9\tx\ta", "9\txx\tb", "7\tx\tc"].joined(separator: "\n")
    #expect(try joined("url-contains", "x", repeated) == "7 9 ")
}

// MARK: - 位元組級比對

@Test func comparisonsAreBytewiseNotCanonical() throws {
    // NFC 的 é（c3 a9）與 NFD 的 é（65 cc 81）在 bash 不相等；Swift 的
    // `String ==` 會說相等，所以這三支都不能用 String 比。
    let nfc = "\u{00e9}"
    let nfd = "e\u{0301}"
    #expect(WindowMatching.idForLabel(nfc, in: nfd + "\t1") == nil)
    #expect(WindowMatching.idForLabel(nfc, in: nfc + "\t1") == "1")
    #expect(try joined("url-exact", nfc, "9\t" + nfd + "\tt") == "")
    #expect(try joined("title-regex", nfc, "9\tu\t" + nfd) == "")
}

@Test func carriageReturnIsItsOwnByte() throws {
    // `\r\n` 在 Swift 是一個 Character。用 Character 切記錄的話，`\r` 會跟著
    // 換行一起消失，最後一欄就少一個位元組。
    let withCR = "9\thttps://x\ttitle\r"
    #expect(try joined("title-regex", "title$", withCR) == "")
    #expect(try joined("title-regex", "title\r$", withCR) == "9 ")
}

// MARK: - awk 的 strnum 比較（url-exact 與 current_tab_url 的 $1）

@Test func urlExactComparesNumericallyWhenBothSidesLookLikeNumbers() throws {
    // 兩邊都是 numeric string 時 awk 比的是**數值**：這幾條在純字串比較下全是「不中」
    #expect(try joined("url-exact", "1e3", "9\t1000\tt") == "9 ")
    #expect(try joined("url-exact", "1", "9\t1.0\tt") == "9 ")
    #expect(try joined("url-exact", "01", "9\t1\tt") == "9 ")
    #expect(try joined("url-exact", "0x10", "9\t16\tt") == "9 ")
    #expect(try joined("url-exact", "1", "9\t 1 \tt") == "9 ")
}

@Test func awkNumberRejectsPositiveInfinityAndRangeErrors() throws {
    // `r == HUGE_VAL` 那條把正無限大排除掉，所以 inf 與 Infinity 走字串比較
    #expect(try joined("url-exact", "inf", "9\tInfinity\tt") == "")
    #expect(AwkText.number(Array("inf".utf8)) == nil)
    #expect(AwkText.number(Array("Infinity".utf8)) == nil)
    // 負的只有溢位才擋，所以 -inf 仍是數值
    #expect(try joined("url-exact", "-inf", "9\t-Infinity\tt") == "9 ")
    // ERANGE：溢位與下溢都不是數值
    #expect(AwkText.number(Array("1e400".utf8)) == nil)
    #expect(AwkText.number(Array("1e-400".utf8)) == nil)
    #expect(try joined("url-exact", "1e400", "9\t2e400\tt") == "")
}

@Test func awkNumberTreatsNaNAsEqualToEverythingNumeric() throws {
    // awk 用相減的三分法，NaN 兩邊都不成立就落在「相等」。用 Swift 的 `==`
    // 會得到相反的答案。
    #expect(try joined("url-exact", "nan", "9\tNaN\tt") == "9 ")
    #expect(try joined("url-exact", "nan(x)", "9\t1\tt") == "9 ")
    #expect(AwkText.equals(Array("nan".utf8), Array("0".utf8)))
}

@Test func awkNumberNeedsTheWholeStringToBeANumber() throws {
    #expect(AwkText.number(Array("1x".utf8)) == nil)
    #expect(AwkText.number(Array("".utf8)) == nil)
    #expect(AwkText.number(Array("abc".utf8)) == nil)
    // 前後的空白可以，但收尾只放行 space／tab／LF／CR——垂直定位不算
    #expect(AwkText.number(Array(" 1 ".utf8)) != nil)
    #expect(AwkText.number(Array("1\u{0b}".utf8)) == nil)
    // 空字串不是數值，所以 "" 與 "0" 是字串比較
    #expect(try joined("url-exact", "", "9\t0\tt") == "")
}

@Test func currentTabURLComparesTheWindowIDNumericallyButTheFlagAsAString() {
    // `$1 == w` 兩邊都是 numeric string
    #expect(WindowMatching.currentTabURL(window: "191", dump: "191.0\tu\tt\t1") == "u")
    // `$4 == "1"` 的右手邊是字串常數，所以 1.0 與 " 1" 都不算當前分頁
    #expect(WindowMatching.currentTabURL(window: "191", dump: "191\tu\tt\t1.0") == nil)
    #expect(WindowMatching.currentTabURL(window: "191", dump: "191\tu\tt\t 1") == nil)
}

// MARK: - awk -v 的跳脫

@Test func urlKindsGoThroughTheAssignmentEscapes() throws {
    // url-exact／url-contains 是用 `-v` 傳值的，所以值裡的 `\\` 會塌成一個反斜線。
    // title-regex 改走 ENVIRON 就是為了躲開這件事。
    #expect(try joined("url-exact", "a\\\\b", "9\ta\\b\tt") == "9 ")
    #expect(try joined("url-contains", "a\\\\b", "9\tXa\\bY\tt") == "9 ")
    #expect(AwkText.expandAssignmentEscapes("a\\tb") == Array("a\tb".utf8))
    #expect(AwkText.expandAssignmentEscapes("a\\qb") == Array("aqb".utf8))
    #expect(AwkText.expandAssignmentEscapes("a\\101b") == Array("aAb".utf8))
    // 收尾的孤零零反斜線在 -v 是**字面的反斜線**（regex 那邊是字串結尾）
    #expect(AwkText.expandAssignmentEscapes("ab\\") == Array("ab\\".utf8))
    // \0 產生的 NUL 讓 C 字串在那裡結束
    #expect(AwkText.expandAssignmentEscapes("a\\0b") == Array("a".utf8))
}

// MARK: - 畸形 dump

@Test func anEmptyDumpIsOneEmptyRecordNotZeroRecords() throws {
    // bash 是 `printf '%s\n' "$dump" | awk`，所以尾端一定補一個換行。
    // url-exact 的空針配得上那筆空記錄的空欄位，於是印出一個空的 id。
    #expect(try found("url-exact", "", "") == [""])
    // url-contains 走的是 index()，而 awk 的外層迴圈條件是 `*p1`，
    // 所以草堆是空的時候連空針都不算命中。
    #expect(try found("url-contains", "", "") == [])
    #expect(try found("title-regex", "", "") == [""])
}

@Test func shortRecordsGiveEmptyFields() throws {
    #expect(try found("url-exact", "", "5") == ["5"])
    #expect(try joined("title-regex", "^$", ["1\ta", "2\tb\tt"].joined(separator: "\n")) == "1 ")
}

@Test func blankLinesInTheDumpAreSkippedNotFatal() throws {
    let holey = ["1\tx\tt", "", "2\tx\tt"].joined(separator: "\n")
    #expect(try joined("url-contains", "x", holey) == "1 2 ")
}

@Test func emptyNeedleForUrlContainsMatchesEveryNonEmptyField() throws {
    #expect(try joined("url-contains", "", ["1\ta\tt", "2\tb\tt"].joined(separator: "\n")) == "1 2 ")
}

@Test func theTrailingSlashRuleAddsExactlyOneSlash() throws {
    let slashes = ["1\thttps://a/\tt", "2\thttps://a//\tt", "3\thttps://a\tt"]
        .joined(separator: "\n")
    #expect(try joined("url-exact", "https://a/", slashes) == "1 2 ")
}

@Test func badPatternIsAnErrorNotAMiss() throws {
    // bash 那側 awk exit 2，`set -o pipefail` 讓整條管線也回 2——與未知類型同一個 rc。
    #expect(throws: WindowMatchError.badPattern) { try found("title-regex", "(", dump) }
    #expect(throws: WindowMatchError.badPattern) { try found("title-regex", "[", dump) }
    #expect(throws: WindowMatchError.badPattern) { try found("title-regex", "*abc", dump) }
}

// MARK: - id_for_label 的 read 語意

@Test func idForLabelFollowsIFSWhitespaceRules() {
    // IFS 是 TAB 而 TAB 算 IFS 空白：行首行尾整段吃掉、中間連續的算一個分隔符
    #expect(WindowMatching.idForLabel("A", in: "\tA\t1") == "1")
    #expect(WindowMatching.idForLabel("", in: "\tA\t1") == nil)
    #expect(WindowMatching.idForLabel("A", in: "A\t\t1") == "1")
    #expect(WindowMatching.idForLabel("A", in: "A\t1\t") == "1")
    // 只有兩個變數，所以 v 拿到剩下全部含中間的 TAB
    #expect(WindowMatching.idForLabel("A", in: "A\t1\t2") == "1\t2")
    // 沒有 TAB 的一行：k 是整行、v 是空字串，rc 仍是 0
    #expect(WindowMatching.idForLabel("A", in: "A") == "")
    // 整行都是 TAB（或空行）時 k 是空字串，所以空的 want 反而命中
    #expect(WindowMatching.idForLabel("", in: "\t\t") == "")
    #expect(WindowMatching.idForLabel("", in: "") == "")
}

@Test func idForLabelTakesTheFirstOfDuplicateKeys() {
    #expect(WindowMatching.idForLabel("A", in: ["A\t1", "A\t2"].joined(separator: "\n")) == "1")
}

// MARK: - 兩處刻意不對齊的分歧

/// 分歧 1：`sort -u` 跑在 en_US.UTF-8 的定序下，而 macOS 的那份定序把所有非 ASCII
/// 字串視為**彼此相等**——實測三筆 id `終`／`工`／`9` 過 `sort -u` 只剩 `終` 與 `9`，
/// `工` 被當成重複的丟掉（同一個定序也讓 awk 在沒有 LC_ALL=C 的 url-exact 裡把
/// `/` 判成等於 `終端機/`）。window id 一律是十進位整數，已用 400 組隨機數字字串
/// 驗過兩種定序逐位元組相同，所以這裡用位元組序；差分語料因此只放數字 id。
@Test func knownDivergenceNonASCIIIDsAreNotCollapsed() throws {
    let cjk = ["終\tx\ta", "工\tx\tb", "9\tx\tc"].joined(separator: "\n")
    // bash 回「終 9」（工 被 sort -u 丟掉）；這裡三筆都留著，並且照位元組排序。
    #expect(try joined("url-contains", "x", cjk) == "9 工 終 ")
}

/// 分歧 2：連著兩個區間（`a{1,2}{2}`）在 awk 是**文字展開**——`a{1,2}` 先被改寫成
/// `aa?`，第二個 `{2}` 於是只綁在最後那個 atom 上，所以它配得上單一個 `a`
/// （實測 `a{2}{2}` 要三個 a、`a{2}{3}` 要四個）。這裡照一般的巢狀量詞處理，
/// `a{1,2}{2}` 需要兩到四個 a。差分語料不放這種 pattern。
///
/// 同一組還有一個不能複製的：`{2}` 單獨當 pattern 會讓本機的 awk **SIGSEGV**
/// （rc=139），這裡回的是語法錯誤 rc=2。
@Test func knownDivergenceChainedIntervalsNest() throws {
    #expect(try !regexMatches("a{1,2}{2}", "a"))
    #expect(try regexMatches("a{1,2}{2}", "aa"))
    #expect(regexThrows("{2}"))
}

// MARK: - 把字面文字變成 pattern

/// 跳脫過的字串當 pattern，必須配得上原字串。**這一條才是驗收**——
/// 下面那條只釘住形狀，而形狀對不對要由引擎自己說。
@Test func anEscapedLiteralMatchesItselfExactly() throws {
    let subjects = ["Zed (workmode)", "Zed-2.0 [beta]", "a.b*c+d?e",
                    "^start$", "{1,2}", "back\\slash", "pipe|bar"]
    for subject in subjects {
        let regex = try AwkRegex(pattern: AwkRegex.escapingLiteral(subject))
        #expect(regex.matches(subject), "跳脫後配不上自己：\(subject)")
    }
}

/// 沒跳脫的話配不上——這一條證明上面那條有牙齒。括號是 ERE 的 group，
/// 所以 `Zed (workmode)` 這個 pattern 實際上在找 `Zed workmode`。
@Test func theSameLiteralWithoutEscapingDoesNotMatch() throws {
    let regex = try AwkRegex(pattern: "Zed (workmode)")
    #expect(!regex.matches("Zed (workmode)"))
}

/// 形狀：每個 ERE 特殊字元前面多一個反斜線，其餘一個字都不動。
@Test func escapingTouchesOnlyTheSpecialBytes() {
    #expect(AwkRegex.escapingLiteral("abc") == "abc")
    #expect(AwkRegex.escapingLiteral("a.b") == "a\\.b")
    #expect(AwkRegex.escapingLiteral("(x)") == "\\(x\\)")
    // 多位元組字元一個位元組都不該被碰：UTF-8 的續位元組都 ≥ 0x80，
    // 而特殊字元全在 ASCII 區。
    #expect(AwkRegex.escapingLiteral("郵件") == "郵件")
}
