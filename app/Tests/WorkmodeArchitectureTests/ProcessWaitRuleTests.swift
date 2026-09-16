import Foundation
import Testing

/// 每個 spawn 子行程的地方都必須用 `terminationHandler` 等它結束，不可以用
/// `waitUntilExit()`。
///
/// 這條寫成測試而不是註解，是因為它的失敗模式**完全靜默**：把 semaphore 換回
/// `waitUntilExit()`，642 條單元測試、2257 組語料、差分 harness、兩支 smoke 全部
/// 照樣綠，只是每次 `--probe` 慢 532ms。沒有任何東西會紅。
///
/// 那 532ms 是量出來的（2026-08-16）：子行程**已經關掉 stdout** 之後，
/// `waitUntilExit()` 仍固定要 62–67ms 才回來——它自己的輪詢週期，與子行程無關。
/// 一次 probe 走 8 次子行程呼叫，Swift 版因此比 bash 慢約 25%（2075ms → 2580ms）。
/// 換成事件驅動之後回到 2025–2076ms，比 bash 略快。
///
/// 掃描靠字串比對，所以它自己也可能壞掉——底下有正控制組。
private func adaptersDirectory() -> URL {
    URL(fileURLWithPath: #filePath) // …/app/Tests/WorkmodeArchitectureTests/X.swift
        .deletingLastPathComponent() // …/app/Tests/WorkmodeArchitectureTests
        .deletingLastPathComponent() // …/app/Tests
        .deletingLastPathComponent() // …/app
        .appendingPathComponent("Sources")
        .appendingPathComponent("WorkmodeAdapters")
}

/// 只看程式碼行：註解裡本來就會提到 `waitUntilExit`（正是為了說明為什麼不用它）。
private func codeLines(of file: URL) throws -> String {
    try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

private func adapterSources() throws -> [URL] {
    let directory = adaptersDirectory()
    let items = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    return items.filter { $0.hasSuffix(".swift") }.map { directory.appendingPathComponent($0) }
}

@Test func adaptersNeverPollForProcessExit() throws {
    let files = try adapterSources()
    #expect(!files.isEmpty, "掃不到任何 Adapters 原始碼——路徑算錯了，這個測試等於沒跑")

    for file in files {
        #expect(try !codeLines(of: file).contains("waitUntilExit"),
                "\(file.lastPathComponent) 用了 waitUntilExit()：每次多花約 65ms 輪詢，改用 terminationHandler ＋ DispatchSemaphore")
    }
}

/// 光是「沒有 waitUntilExit」還不夠：整段拿掉也會通過，而那是正確性問題不是效能問題
/// （`terminationStatus` 在子行程結束前讀是未定義的）。所以另外對帳——**會 spawn 的
/// 檔案數必須等於有 terminationHandler 的檔案數**。新增一個 spawn 的地方而忘了等，
/// 這條就會紅。
@Test func everyFileThatSpawnsAlsoWaitsForTermination() throws {
    var spawns: [String] = []
    var waits: [String] = []
    for file in try adapterSources() {
        let code = try codeLines(of: file)
        if code.contains("Process()") {
            spawns.append(file.lastPathComponent)
        }
        if code.contains("terminationHandler") {
            waits.append(file.lastPathComponent)
        }
    }
    #expect(!spawns.isEmpty, "掃不到任何 spawn 的地方——pattern 壞了，這個測試等於沒跑")
    #expect(spawns.sorted() == waits.sorted(),
            "會 spawn 的是 \(spawns.sorted())，有等結束的是 \(waits.sorted())")
}

/// 正控制組：偵測器對確定違規的字串必須有反應。沒有它的話，「乾淨」與
/// 「pattern 根本不匹配」外觀完全相同。
@Test func processWaitPatternsActuallyMatch() {
    #expect("process.waitUntilExit()".contains("waitUntilExit"))
    #expect("let process = Process()".contains("Process()"))
    #expect("process.terminationHandler = { _ in }".contains("terminationHandler"))
}
