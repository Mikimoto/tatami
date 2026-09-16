import Foundation
import Testing
import WorkmodeAdapters
import WorkmodeCore

// renderer 是那些句子唯一的家，所以「它印的字與 bash 一樣」必須是機器驗的。
//
// 驗法不是把 bash 的字串抄進測試（那只證明我抄了兩次同一份東西），而是**從
// scripts/workmode.sh 把那一行的格式字串挖出來、真的用 bash printf 跑一次**，
// 再與 renderer 的輸出逐位元組比對。抄錯字、少一個全形空白、把「，」寫成「,」，
// 這條都會紅；`workmode.sh` 那句話被改掉時它也會紅（那正是該有人來看的時候）。

/// 讀 `tests/oracle/workmode-<line>.line`——那是 `scripts/workmode.sh` 該行的**凍結
/// 副本**，逐位元組相同（凍結時對過 7 行全同）。
///
/// 為什麼不直接讀 `scripts/workmode.sh`：那個檔已經不存在了（bash 退役），而這些
/// 格式字串是 renderer 那些 case 唯一的 oracle——語料驗的是 `__diff` 的純函式輸出，
/// 碰不到人看的那些句子。**涵蓋的是下面那張 `sites` 表，不是 renderer 的每一句**：
/// `/usr/bin/grep -cE '^ *case ' HumanEventRenderer.swift` 是 54（`HumanPhrases+Layout`
/// 另有 8），而凍在 `tests/oracle/` 的只有 17 個 `.line` 檔。
///
/// 凍住的是**格式字串本身**，不是預期輸出：測試照樣把它交給真的 `bash printf`
/// ／真的 `jq` 跑一次再比位元組。所以把字串抄進測試仍然不會過（那只證明抄了兩次），
/// 這一點與凍結前完全相同。
///
/// 用 #filePath 而不是 cwd：swift test 的工作目錄不保證是 package 根目錄。
private func workmodeLine(_ line: Int) throws -> String {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // …/app/Tests/WorkmodeAdaptersTests
        .deletingLastPathComponent() // …/app/Tests
        .deletingLastPathComponent() // …/app
        .deletingLastPathComponent() // repo 根
        .appendingPathComponent("tests/oracle/workmode-\(line).line")
    var text = try String(contentsOf: fixture, encoding: .utf8)
    // 檔案帶一個結尾換行（少了它 git 會標 "No newline at end of file"），
    // 那個換行不屬於原本那一行。
    if text.hasSuffix("\n") {
        text.removeLast()
    }
    return text
}

/// 挖出 `printf '…'` 裡那個單引號字串。格式字串裡沒有單引號，所以取第一對就夠。
private func formatString(inLine line: String) throws -> String {
    guard line.contains("printf ") else {
        throw RenderCheckError.notAPrintfLine(line)
    }
    let parts = line.split(separator: "'", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { throw RenderCheckError.noQuotedFormat(line) }
    return String(parts[1])
}

private enum RenderCheckError: Error, CustomStringConvertible {
    case notAPrintfLine(String)
    case noQuotedFormat(String)

    var description: String {
        switch self {
        case let .notAPrintfLine(line):
            "workmode.sh 的行號漂掉了，這一行不是 printf：\(line)"
        case let .noQuotedFormat(line):
            "這一行找不到單引號包起來的格式字串：\(line)"
        }
    }
}

/// 用真的 bash 跑 `printf <fmt> <args…>`，回它寫到 stdout 的原始位元組。
private func bashPrintf(_ format: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    // `printf "$1" "${@:2}"`：格式字串與參數都經由 argv 傳進去，不做任何 shell 展開，
    // 所以中文與 `%s` 不會在路上被動到。
    process.arguments = ["-c", #"printf "$1" "${@:2}""#, "_", format] + arguments
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// 一行一個站點。引數不具名是為了讓下面那張表對得整齊——它是一張對照表，
/// 每一列要能一眼看出「哪一行、餵什麼、對應哪個 event」。
private struct PrintfSite {
    let line: Int
    let arguments: [String]
    let event: WorkmodeEvent

    init(_ line: Int, _ arguments: [String], _ event: WorkmodeEvent) {
        self.line = line
        self.arguments = arguments
        self.event = event
    }
}

/// 一個 case 對一個 bash printf 站點（Reporter.swift 的約定 1）。
///
/// 2026-09-07 隨 `ApplyLayout`／`TreeLayout`／`StrangerExile` 退役拿掉 10 列
/// （`exile_strangers` 的 694／698／700、`layout_tree` 的 775／785／791／798／800／
/// 807／809），連同下面原本那個 `ratioSites` 機制（`apply_ratio` 的 855，以及它的
/// note 賦值 826／839／845）。那 18 個事件現在一個發送者都沒有，凍在
/// `tests/oracle/` 的那 13 個 `.line` 檔也一起刪了——原文仍在
/// `git show bash-oracle:scripts/workmode.sh` 的那幾行，要復原就照那裡重凍。
private let sites: [PrintfSite] = [
    .init(656, ["Chat"], .minimizedWindowRestored(label: "Chat")),
    .init(658, ["Chat"], .minimizedWindowRestoreFailed(label: "Chat")),
    // resolve_rules 的三句。894 的第三個引數是 `printf '%s' "$cands" | tr '\n' ' '`
    // 的結果——`$( )` 已經剝掉尾端換行，所以 `7\n9` 變成 `7 9`（三個位元組），
    // **最後一個候選後面沒有空白**。這裡照那個實測值餵進去。
    .init(894, ["Site", "2", "7 9"],
          .ruleMatchedMultipleWindows(label: "Site", count: 2, candidates: ["7", "9"])),
    .init(907, ["Site"], .ruleCandidatesAllClaimed(label: "Site")),
    .init(909, ["Site", "url-exact", "https://a.example/"],
          .ruleWindowNotFound(label: "Site", matchType: "url-exact",
                              matchValue: "https://a.example/")),
    // load_layout 與 active_location 各一句（都走 stderr）。
    .init(109, ["/x/scripts/layout.json"],
          .layoutFileMissing(path: "/x/scripts/layout.json")),
    .init(569, ["火星"], .stateLocationNotInLayout(location: "火星")),
    // ensure_app 的四句。624 的結尾是刪節號 U+2026；631 的引數序是秒數先、app 後。
    .init(624, ["Chat"], .appNotRunning(app: "Chat")),
    .init(625, ["Chat"], .appLaunchFailed(app: "Chat")),
    .init(629, ["Chat", "3"], .appLaunched(app: "Chat", waitedSeconds: 3)),
    .init(631, ["10", "Chat"], .appLaunchTimedOut(app: "Chat", seconds: 10)),
]

@Test func rendersByteForByteWhatBashPrintfPrints() throws {
    let renderer = HumanEventRenderer()
    for site in sites {
        let format = try formatString(inLine: workmodeLine(site.line))
        let expected = try bashPrintf(format, site.arguments)
        let actual = renderer.render(site.event)
        // 比位元組而不是比 String：Swift 的 `==` 會做正規化，NFC 與 NFD 的
        // 「原本」在那裡相等，而寫進終端機的位元組不相等。
        let note = Comment(rawValue: "workmode.sh:\(site.line) 對不上："
            + "bash 印 \(expected.debugDescription)，renderer 印 \(actual.debugDescription)")
        #expect(Array(actual.utf8) == Array(expected.utf8), note)
    }
}

/// 正控制組（兩個方向）：上面那條若因為 harness 壞掉而恆真，就完全沒在驗。
/// 這條確認 (1) bash 真的印得出東西、(2) 一個刻意寫錯的字串真的會被判不同。
@Test func theComparisonHarnessCanActuallyFail() throws {
    let format = try formatString(inLine: workmodeLine(656))
    let printed = try bashPrintf(format, ["Chat"])

    #expect(printed.contains("Chat"), "bash printf 什麼都沒印——這個 harness 是壞的")
    // 半形逗號換全形、少一個空白這類差異都必須抓得到。
    #expect(printed != "  「Chat」原本是最小化的,已還原\n")
}

/// 行號漂掉時要硬失敗而不是安靜通過。
@Test func detectsWhenTheRecordedLineNumberNoLongerHoldsAPrintf() throws {
    #expect(throws: (any Error).self) {
        // 642 是 `RESTORE_POLLS=20`，不是 printf。
        try formatString(inLine: workmodeLine(642))
    }
}
