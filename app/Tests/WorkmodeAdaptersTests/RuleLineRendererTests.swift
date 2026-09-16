import Foundation
import Testing
import WorkmodeAdapters
import WorkmodeCore

// `report_rules` 那兩句的逐位元組比對。
//
// 它們**不能**用 `HumanEventRendererTests` 那個 harness：那支是「挖出 printf 的格式
// 字串，用 bash printf 跑一次」，而這兩句一句是 `echo`、另一句根本不是 shell 印的
// ——是 `jq -r` 的字串插值。所以這裡的 oracle 換成對應的真工具：
//
//   * workmode.sh:667 → `/bin/bash` 的 `echo`（換行由它自己補）
//   * workmode.sh:674 → 真的 `jq -r --arg l …`，filter 從 workmode.sh 挖出來、
//     餵一份 window JSON 進 stdin
//
// 這樣「renderer 印的字」與「產品路徑上真的會出現在終端機的位元組」用的是同一個
// 產生器，抄錯字、少一個全形空白、把 `@` 前面的空白弄掉都會紅。

/// 讀 `tests/oracle/workmode-<line>.line`——那是 `scripts/workmode.sh` 該行的**凍結
/// 副本**，逐位元組相同（凍結時對過 7 行全同）。
///
/// 為什麼不直接讀 `scripts/workmode.sh`：它要被換成呼叫 Swift 執行檔的 wrapper，
/// 那時這些格式字串就不存在了，而它們是 renderer 那 167 個 case 唯一的 oracle
/// ——語料驗的是 `__diff` 的純函式輸出，碰不到人看的那些句子。
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

private enum RuleLineCheckError: Error, CustomStringConvertible {
    case notAnEchoLine(String)
    case notAJQFilter(String)

    var description: String {
        switch self {
        case let .notAnEchoLine(line):
            "workmode.sh 的行號漂掉了，這一行不是 echo \"…\"：\(line)"
        case let .notAJQFilter(line):
            "這一行不是單引號包起來的 jq filter：\(line)"
        }
    }
}

/// 挖出 `echo "…"` 裡那個雙引號字串。
private func echoedString(inLine line: String) throws -> String {
    guard line.contains("echo \""),
          let first = line.firstIndex(of: "\""),
          let last = line.lastIndex(of: "\""),
          first < last
    else {
        throw RuleLineCheckError.notAnEchoLine(line)
    }
    return String(line[line.index(after: first) ..< last])
}

/// 挖出那一行單引號包起來的 jq filter。整個 filter 沒有單引號，取第一對就夠。
private func jqFilter(inLine line: String) throws -> String {
    let parts = line.split(separator: "'", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts[1].contains("\\(") else {
        throw RuleLineCheckError.notAJQFilter(line)
    }
    return String(parts[1])
}

/// 跑一個外部命令，回它寫到 stdout 的原始位元組。
private func stdout(of executable: String, _ arguments: [String],
                    stdin: String? = nil) throws -> String
{
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    if let stdin {
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        input.fileHandleForWriting.closeFile()
    } else {
        try process.run()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// workmode.sh:667 的 `echo`。格式字串與參數都經由 argv，不做 shell 展開。
private func bashEcho(_ text: String) throws -> String {
    try stdout(of: "/bin/bash", ["-c", #"echo "$1""#, "_", text])
}

/// 真的 `jq -r --arg l <label> <filter>`，window JSON 餵 stdin。
private func jqLine(label: String, window: String) throws -> String {
    let filter = try jqFilter(inLine: workmodeLine(674))
    return try stdout(of: "/usr/bin/env",
                      ["jq", "-r", "--arg", "l", label, filter], stdin: window)
}

/// 一個 window JSON 對一個事件。JSON 的數字都是**字面值**，因為 jq 1.8 逐字保留
/// 沒被運算過的數字，而 floor 過的那四個走 dtoa 模型——這一行同時有兩種形狀。
private let windows: [(json: String, event: WorkmodeEvent)] = [
    (#"{"id":7,"display":1,"space":2,"frame":{"w":1878.50,"h":1000,"x":0,"y":25.5}}"#,
     .ruleWindowPositionReported(label: "Chat", id: "7", display: "1", space: "2",
                                 frame: ReportedFrame(width: "1878", height: "1000",

                                                      originX: "0", originY: "25"))),
    // 逐字保留：`2.50` 不是 `2.5`，而 space 是字串時 `-r` 印的是不加引號的原文。
    (#"{"id":2.50,"display":1,"space":"0007","frame":{"w":10,"h":20,"x":30,"y":40}}"#,
     .ruleWindowPositionReported(label: "Chat", id: "2.50", display: "1", space: "0007",
                                 frame: ReportedFrame(width: "10", height: "20",

                                                      originX: "30", originY: "40"))),
    // 欄位缺席 → 插值成**字面的 null**，不是空字串。
    (#"{"space":2,"frame":{"w":10,"h":20,"x":30,"y":40}}"#,
     .ruleWindowPositionReported(label: "Chat", id: "null", display: "null", space: "2",
                                 frame: ReportedFrame(width: "10", height: "20",

                                                      originX: "30", originY: "40"))),
    // 負座標與 floor 的方向：`-0.4 | floor` 是 `-1`（不是 `-0`）。
    (#"{"id":7,"display":1,"space":2,"frame":{"w":10,"h":20,"x":-0.4,"y":-1000.9}}"#,
     .ruleWindowPositionReported(label: "Chat", id: "7", display: "1", space: "2",
                                 frame: ReportedFrame(width: "10", height: "20",

                                                      originX: "-1", originY: "-1001"))),
]

@Test func rendersTheRuleLineByteForByteWhatJQPrints() throws {
    let renderer = HumanEventRenderer()
    for window in windows {
        let expected = try jqLine(label: "Chat", window: window.json)
        let actual = renderer.render(window.event)
        // 比位元組而不是比 String：Swift 的 `==` 會做正規化，而寫進終端機的位元組不會。
        let note = Comment(rawValue: "jq 印 \(expected.debugDescription)，"
            + "renderer 印 \(actual.debugDescription)")
        #expect(Array(actual.utf8) == Array(expected.utf8), note)
    }
}

/// 正控制組（兩個方向）：上面那條若因為 harness 壞掉而恆真，就完全沒在驗。
/// 這條確認 (1) jq 真的印得出東西、(2) 一個刻意寫錯的字串真的會被判不同。
@Test func theJQOracleCanActuallyFail() throws {
    let printed = try jqLine(label: "Chat",
                             window: #"{"id":7,"display":1,"space":2,"frame":{"w":1,"h":2,"x":3,"y":4}}"#)

    #expect(printed.contains("id=7"), "jq 什麼都沒印——這個 harness 是壞的")
    // 少一個空白、把 `@` 寫成 `at` 這類差異都必須抓得到。
    #expect(printed != "  Chat id=7 display=1 space=2 1x2 @3,4\n")
}

/// `.frame` 缺席時 jq 是 runtime error 並印**零位元組**——這是 Core 那側「不發事件」
/// 的依據。它在這裡驗一次，否則那個決定只是我讀出來的推論。
@Test func jqPrintsNothingAtAllWhenTheFrameIsMissing() throws {
    let printed = try jqLine(label: "Chat", window: #"{"id":7,"display":1,"space":2}"#)
    #expect(printed.isEmpty)
}

/// workmode.sh:667 那句是 `echo` 而不是 `printf`——換行由 echo 自己補。
@Test func rendersThePlaceholderByteForByteWhatBashEchoPrints() throws {
    let expected = try bashEcho(echoedString(inLine: workmodeLine(667)))
    let actual = HumanEventRenderer().render(.noRulesResolved)

    #expect(!expected.isEmpty, "bash echo 什麼都沒印——這個 harness 是壞的")
    #expect(Array(actual.utf8) == Array(expected.utf8),
            Comment(rawValue: "bash 印 \(expected.debugDescription)，"
                + "renderer 印 \(actual.debugDescription)"))
}

/// 行號漂掉時要硬失敗而不是安靜通過。
@Test func detectsWhenTheRecordedRuleLineNumbersNoLongerHold() throws {
    #expect(throws: (any Error).self) {
        // 664 是 `report_rules() {`，不是 echo。
        try echoedString(inLine: workmodeLine(664))
    }
    #expect(throws: (any Error).self) {
        // 673 是 `| jq -r --arg l "$label" \`，filter 在下一行。
        try jqFilter(inLine: workmodeLine(673))
    }
}
