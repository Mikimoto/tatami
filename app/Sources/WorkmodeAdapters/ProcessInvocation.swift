import Foundation

/// 找不到某個外部執行檔。
///
/// 與 `YabaiExecutableNotFound` 分開而不是合併成一個泛用型別：那個的訊息帶著
/// 「brew install koekeishiya/formulae/yabai」這種只對 yabai 成立的指引，
/// 而 yabai 缺席是致命的（整支腳本的每個動作都要它），fzf 缺席不是
/// （workmode.sh:1016 印一行提示就退回非互動的 `--switch a/b`）。
/// 硬要共用一個型別就得把那個差別搬進呼叫端。
public struct ExecutableNotFound: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let name: String
    public let searchedPaths: [String]

    public var description: String {
        "找不到 \(name) 執行檔。找過這些路徑：" + searchedPaths.joined(separator: "、")
    }

    public var errorDescription: String? {
        description
    }
}

/// Homebrew 的固定位置 → PATH。先試前者的理由與 `YabaiProcessClient` 相同：
/// 這支程式會被 skhd 呼叫，而 GUI／launchd 起的 process 不繼承 shell 的 PATH。
func locateExecutable(
    name: String,
    homebrew: String,
    path: String? = ProcessInfo.processInfo.environment["PATH"]
) throws -> String {
    var searched: [String] = []
    let manager = FileManager.default

    searched.append(homebrew)
    if manager.isExecutableFile(atPath: homebrew) {
        return homebrew
    }

    for directory in (path ?? "").split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = String(directory) + "/" + name
        searched.append(candidate)
        if manager.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    throw ExecutableNotFound(name: name, searchedPaths: searched)
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
}

/// 跑一個外部命令。
///
/// `stdin` 是 nil 時**繼承**我們的 stdin，不是接一根空管線：fzf 要的就是那個
/// （它從 tty 讀按鍵），而 `osascript` 的 heredoc 需要接管線。兩種都用得到，
/// 所以這個參數不能省。
///
/// 寫 stdin 與讀 stdout 沒有分執行緒：兩個呼叫點餵進去的東西都遠小於管線緩衝
/// （AppleScript 本體 653 bytes、fzf 的選單十來行），而子行程在讀完輸入前不會
/// 吐出足以塞爆 stdout 緩衝的東西。餵大量資料的呼叫點出現時這裡要先改。
func runProcess(
    executable: String,
    arguments: [String],
    stdin: Data? = nil,
    inheritStderr: Bool
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let out = Pipe()
    process.standardOutput = out
    // stderr 只有兩種去處（理由見 YabaiProcessClient.invoke 的註解：接了 Pipe
    // 又不讀它會在輸出超過緩衝時死鎖）。
    process.standardError = inheritStderr ? FileHandle.standardError : FileHandle.nullDevice

    let input = stdin.map { _ in Pipe() }
    if let input {
        process.standardInput = input
    }

    // 為什麼不是 `process.waitUntilExit()`：實測（2026-08-16）它在子行程**已經關掉
    // stdout** 之後仍固定要 62–67ms 才回來——那是它自己的輪詢週期，與子行程無關。
    // 一次 `--probe` 走 8 次子行程呼叫，就是 532ms 的純等待，讓 Swift 版比 bash 慢
    // 約 25%（2075ms → 2580ms）。改成 terminationHandler ＋ semaphore 是事件驅動的，
    // 不輪詢。量法在 CLAUDE.md；改這段之前先重量一次，別憑印象。
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    try process.run()

    if let input, let data = stdin {
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
    }

    let data = out.fileHandleForReading.readDataToEndOfFile()
    exited.wait()
    return ProcessResult(status: process.terminationStatus, stdout: data)
}
