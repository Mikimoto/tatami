import Foundation
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// 找不到 yabai 執行檔。
///
/// 不併進 `YabaiError`：那個 enum 是 port 的一部分，描述的是「yabai 說不行」；
/// 這裡是「yabai 不在這台機器上（或路徑不對）」，Core 沒有任何處理方式，
/// 唯一該做的事就是把訊息原樣印給人看，所以它只在 Adapters 存在。
public struct YabaiExecutableNotFound: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let searchedPaths: [String]

    public var description: String {
        "找不到 yabai 執行檔。找過這些路徑：" + searchedPaths.joined(separator: "、")
            + "。請確認 yabai 已安裝（brew install asmvik/formulae/yabai），"
            + "或用 YabaiProcessClient(executablePath:) 指定實際路徑。"
    }

    public var errorDescription: String? {
        description
    }
}

/// 用 `Process` 跑真的 yabai。
///
/// 三個方法對 exit code 的態度刻意不一致，因為 bash 那側就不一致，而不一致的地方
/// 正是行為所在：
///
/// - `query` **完全不看 exit code**。bash 的每個 query 都長成
///   `$(yabai -m query … 2>/dev/null | jq -r '…')`，exit code 被管線與重導丟掉，
///   真正決定行為的是「jq 有沒有拿到可解析的東西」。實測（2026-08-14）
///   `yabai -m query --windows --window 999999` 是 rc=1、stdout 全空，
///   而那份空 stdout 餵給 jq 是 **rc=0、零輸出**——所以 bash 的
///   `restore_minimized`（workmode.sh:647）拿到的是空字串，不是錯誤，
///   而它靠 `= "true"` 比不過就 `continue` 跳過那個視窗。
/// - `config` 與 `run` 看 exit code（見各自的 doc）。
///
/// stderr 的處理也是逐個呼叫點照抄 bash：query 與 run 的呼叫點全部帶 `2>/dev/null`
/// （648、687、790 與所有 query），所以丟掉；`yabai -m config`（workmode.sh:852）
/// **沒有**重導，所以繼承我們的 stderr，讓使用者看得到 yabai 自己的抱怨
/// （實測 `yabai -m config nosuchkey` 的 stderr 是
/// `unknown command 'nosuchkey' for domain 'config'`）。
public struct YabaiProcessClient: YabaiClient, Sendable {
    /// Homebrew 在 Apple Silicon 的固定位置。先試它而不是先查 PATH：這支程式會被
    /// skhd 呼叫，而 GUI／launchd 起的 process 不繼承 shell 的 PATH，
    /// 那時 PATH 通常只剩 `/usr/bin:/bin:/usr/sbin:/sbin`，裡面沒有 yabai。
    public static let homebrewPath = "/opt/homebrew/bin/yabai"

    private let executablePath: String

    /// 指定執行檔。測試與非標準安裝路徑用。
    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    /// 自動尋找執行檔：Homebrew 的固定位置 → PATH。兩者都沒有就 throw，
    /// 不做「等到第一次呼叫才失敗」——那會讓錯誤出現在一個與原因無關的地方。
    public init() throws {
        executablePath = try Self.locateExecutable()
    }

    static func locateExecutable(
        homebrew: String = homebrewPath,
        path: String? = ProcessInfo.processInfo.environment["PATH"]
    ) throws -> String {
        var searched: [String] = []
        let manager = FileManager.default

        searched.append(homebrew)
        if manager.isExecutableFile(atPath: homebrew) {
            return homebrew
        }

        for directory in (path ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = String(directory) + "/yabai"
            searched.append(candidate)
            if manager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw YabaiExecutableNotFound(searchedPaths: searched)
    }

    // MARK: - YabaiClient

    /// 解析失敗（含 stdout 全空）一律丟 `malformedOutput`。
    ///
    /// 這個對應關係是刻意的，不是缺陷：bash 那側「查不到的視窗」得到的是空字串，
    /// 對應到這裡就是 `try? client.query(.window(id))` 回 nil。Core 那邊要複製
    /// bash 的「跳過它」就用 `try?`，要複製「當成錯誤」就 `try`——
    /// 差別第一次寫在 Core 看得見的地方，而不是藏在 Adapter 的 `2>/dev/null` 裡。
    public func query(_ query: YabaiQuery) throws -> JSONValue {
        let result = try invoke(query.argv, inheritStderr: false)
        guard let text = String(data: result.stdout, encoding: .utf8),
              let value = try? JSONParser.parse(text)
        else {
            throw YabaiError.malformedOutput(argv: query.argv)
        }
        return value
    }

    public func run(_ command: YabaiCommand) throws {
        let argv = command.argv
        let result = try invoke(argv, inheritStderr: false)
        guard result.status == 0 else {
            throw YabaiError.commandFailed(argv: argv, status: result.status)
        }
    }

    // MARK: - Process

    private struct Invocation {
        let status: Int32
        let stdout: Data
    }

    private func invoke(_ argv: [String], inheritStderr: Bool) throws -> Invocation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        // 每個 argv 都缺 `-m`（port 那邊只描述 yabai 的 domain 與旗標），在這裡補。
        process.arguments = ["-m"] + argv

        let out = Pipe()
        process.standardOutput = out
        // stderr 只有兩種去處，沒有第三種：接 Pipe 而不讀它會在輸出超過管線緩衝時
        // 死鎖，而 yabai 的 stderr 對本程式的行為零影響（錯誤由 exit code 與
        // stdout 可解析性決定）。
        process.standardError = inheritStderr ? FileHandle.standardError : FileHandle.nullDevice

        // 不用 waitUntilExit 的理由與 ProcessInvocation.runProcess 那段相同（輪詢
        // 週期 ~65ms／次）。兩處要一起改，因為 yabai 走的是這一支、不是那一支。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return Invocation(status: process.terminationStatus, stdout: data)
    }
}
