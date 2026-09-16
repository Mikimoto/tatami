import WorkmodeCore
import WorkmodeDomain

// 這些 fake 是後面每一個 use case 測試的地基，所以三件事是硬要求：
//
// 1. 預先塞回應，鍵是「argv」而不是「哪個方法」——同一個方法配不同參數是不同的
//    外部呼叫，合起來記就驗不到「量的是哪個視窗」。
// 2. 記錄順序。很多 yabai 不變式是關於順序的：`--ratio` 設完要重新量、`--warp`
//    之後要量測再修方向與順序。只記「有沒有呼叫過」的話，把量測搬到 ratio 之前
//    這種錯誤完全抓不到（CLAUDE.md 記過同源的坑：mutation 清單要含「移動位置」）。
// 3. 沒塞回應的呼叫**丟錯**。回空值會讓測試為了錯的理由通過——一個打錯 argv 的
//    stub 與「這條路徑根本沒被走到」外觀完全相同。
//
// 併發：全部是 `final class` 且沒有鎖。它們只在 swift-testing 的單一測試函式內
// 建立與使用（不是檔案層級的 `let`，所以不是全域變數，Swift 6 嚴格併發下合法）。
// 要在測試裡跨 Task 共用就得自己包 actor——不要直接加 `@unchecked Sendable`。

/// fake 記下來的一次外部呼叫。用 argv 當唯一表示：`query --windows --window 7` 與
/// `window --deminimize 7` 在同一個時間軸上，跨 query/command 的先後才比得出來。
public struct FakeYabaiCall: Equatable {
    public let argv: [String]
}

enum FakeError: Error, Equatable, CustomStringConvertible {
    /// 沒有預先塞回應。訊息帶上 argv，因為打錯 stub 的 argv 是最容易犯的錯。
    case unstubbed(argv: [String])
    /// 塞的回應用完了。與 unstubbed 分開報：前者是鍵錯了，後者是次數估錯了。
    case exhausted(argv: [String])

    var description: String {
        switch self {
        case let .unstubbed(argv): "沒有預先塞回應：yabai -m \(argv.joined(separator: " "))"
        case let .exhausted(argv): "預先塞的回應用完了：yabai -m \(argv.joined(separator: " "))"
        }
    }
}

/// 依序回放的回應佇列。
///
/// 分成「一次性佇列」與「固定值」兩種而不是「最後一筆自動重複」：後者會讓
/// 「多問了一次」這種錯誤靜默通過，而輪詢型的測試正是要驗問了幾次。
private struct Replay<Value> {
    private var queue: [Value] = []
    private var sticky: Value?

    var isEmpty: Bool {
        queue.isEmpty && sticky == nil
    }

    mutating func enqueue(_ values: [Value]) {
        queue.append(contentsOf: values)
    }

    mutating func fix(_ value: Value) {
        sticky = value
    }

    mutating func next() -> Value? {
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        return sticky
    }
}

/// 假的 yabai。
final class FakeYabai: YabaiClient {
    /// 所有呼叫，依發生順序。query 與 command 混在同一份。
    private(set) var calls: [FakeYabaiCall] = []

    private var queries: [[String]: Replay<Result<JSONValue, Error>>] = [:]
    private var configs: [String: Replay<Result<String, Error>>] = [:]
    /// 命令的預設是成功：bash 那側絕大多數命令的 exit code 被丟掉，逐一 stub
    /// 只會讓測試充滿與待驗行為無關的樣板。要驗失敗路徑就明確 `fail(...)`。
    private var commands: [[String]: Replay<Error?>] = [:]

    // MARK: 塞回應

    /// 依序回放：第 n 次問同一個 query 拿第 n 個值。輪詢用這個
    /// （例：`is-minimized` 前五次 true、第六次 false）。
    func stub(_ query: YabaiQuery, _ values: [JSONValue]) {
        queries[query.argv, default: Replay()].enqueue(values.map { .success($0) })
    }

    /// 問幾次都回同一個值。狀態不隨呼叫改變的東西用這個。
    func stubFixed(_ query: YabaiQuery, _ value: JSONValue) {
        queries[query.argv, default: Replay()].fix(.success(value))
    }

    func stubFailure(_ query: YabaiQuery, _ error: Error) {
        queries[query.argv, default: Replay()].fix(.failure(error))
    }

    func stubConfig(_ key: String, _ value: String) {
        configs[key, default: Replay()].fix(.success(value))
    }

    /// 讓某個命令失敗。bash 只在 687 的 `--space` 與 790 的 `--warp` 看 exit code，
    /// 那兩條降級路徑要靠這個才走得到。
    func fail(_ command: YabaiCommand, with error: Error? = nil) {
        let argv = command.argv
        let failure = error ?? YabaiError.commandFailed(argv: argv, status: 1)
        commands[argv, default: Replay()].fix(failure)
    }

    /// 依序：前幾次失敗、之後成功（或反之）。nil 是成功。
    func stubCommand(_ command: YabaiCommand, _ outcomes: [Error?]) {
        commands[command.argv, default: Replay()].enqueue(outcomes)
    }

    // MARK: YabaiClient

    func query(_ query: YabaiQuery) throws -> JSONValue {
        let argv = query.argv
        calls.append(FakeYabaiCall(argv: argv))
        guard var replay = queries[argv] else { throw FakeError.unstubbed(argv: argv) }
        guard let result = replay.next() else { throw FakeError.exhausted(argv: argv) }
        queries[argv] = replay
        return try result.get()
    }

    func run(_ command: YabaiCommand) throws {
        let argv = command.argv
        calls.append(FakeYabaiCall(argv: argv))
        guard var replay = commands[argv], !replay.isEmpty else { return }
        let outcome = replay.next()
        commands[argv] = replay
        if let inner = outcome, let error = inner {
            throw error
        }
    }

    // MARK: 斷言用的視角

    /// 只看命令（濾掉 query）。驗「先 warp 再 toggle split」這種順序時用它，
    /// 中間夾了幾次量測不影響斷言。
    var commandArgv: [[String]] {
        calls.map(\.argv).filter { $0.first != "query" && $0.first != "config" }
    }

    var allArgv: [[String]] {
        calls.map(\.argv)
    }
}

/// 假的 Clock：不睡，只把時間記下來。
///
/// `restore_minimized` 最多輪詢 20 次 × 0.1s、`ensure_app` 最多 10 × 1s，
/// 真的睡的話這兩段的測試每條要跑好幾秒。
final class FakeClock: Clock {
    private(set) var slept: [Double] = []
    /// 累積的虛擬時間。判斷「等了幾秒」用它，不要自己加總 slept。
    private(set) var elapsed: Double = 0

    func sleep(seconds: Double) {
        slept.append(seconds)
        elapsed += seconds
    }
}

/// 假的 Reporter：記下事件，依發生順序。
///
/// 記順序而不是記成集合：`exile_strangers` 的每一句 stuck 訊息都在收尾那句
/// **之前**，而收尾那句的文字尾巴（「見上」）就是在指它們。順序錯了那句話變成謊。
final class FakeReporter: Reporter {
    private(set) var events: [WorkmodeEvent] = []

    func report(_ event: WorkmodeEvent) {
        events.append(event)
    }

    /// 只看送到某個流的事件。`save_layout` 用 `2>/dev/null` 壓掉整批 stderr
    /// （workmode.sh:1106），那條路徑要驗的正是「哪些事件在那時看不見」。
    func events(on channel: OutputChannel) -> [WorkmodeEvent] {
        events.filter { $0.channel == channel }
    }
}

/// 假的 Safari。
final class FakeSafari: SafariClient {
    /// 直接放原始 TSV 文字：port 回的就是這個，fixture 也該長這樣。
    var dump: String = ""
    var error: Error?
    private(set) var callCount = 0

    init(dump: String = "") {
        self.dump = dump
    }

    func tabDump() throws -> String {
        callCount += 1
        if let error {
            throw error
        }
        return dump
    }
}

/// 假的 app 狀態查詢。
final class FakeAppQuery: AppQuery {
    /// 依序回放：`ensure_app` 會先問一次、開起來之後每秒再問一次，
    /// 「第三次才起來」這種情境要靠依序回放才驗得到。
    private var answers: [String: [Bool]] = [:]
    private var fixed: [String: Bool] = [:]
    private(set) var asked: [String] = []

    func stub(_ app: String, _ values: [Bool]) {
        answers[app] = values
    }

    func stubFixed(_ app: String, _ value: Bool) {
        fixed[app] = value
    }

    func isRunning(app: String) -> Bool {
        asked.append(app)
        if var queue = answers[app], !queue.isEmpty {
            let head = queue.removeFirst()
            answers[app] = queue
            return head
        }
        // 沒塞回應時回 false 而不是丟錯：這個 port 的 bash 對應本來就不區分
        // 「osascript 失敗」與「沒在跑」（workmode.sh:617 是 `= "true"` 比對），
        // 所以「沒塞」在這裡有一個明確且與產品行為一致的答案。
        return fixed[app] ?? false
    }
}

/// 假的 app 啟動器。
final class FakeAppLauncher: AppLauncher {
    private(set) var opened: [String] = []
    var error: Error?

    func open(app: String) throws {
        opened.append(app)
        if let error {
            throw error
        }
    }
}

/// 假的 fzf。
final class FakePicker: Picker {
    var isAvailable: Bool = true
    /// 每次呼叫收到的行與 prompt，依順序。兩段式選單的第二段要驗它收到的清單
    /// 是依第一段的選擇算出來的。
    private(set) var prompts: [(prompt: String, lines: [String])] = []

    /// 依序回放每次選單的結果。nil 是使用者取消（fzf rc≠0）。
    private var choices: [String?] = []

    init(choices: [String?] = []) {
        self.choices = choices
    }

    func pick(_ lines: [String], prompt: String) throws -> String? {
        prompts.append((prompt: prompt, lines: lines))
        guard !choices.isEmpty else {
            // 這裡刻意丟錯而不是回 nil：回 nil 等於「使用者取消」，而那是一條
            // 真實的產品路徑，測試會安靜地走它然後為了錯的理由通過。
            throw FakeError.unstubbed(argv: ["fzf", prompt])
        }
        return choices.removeFirst()
    }
}

/// 假的檔案系統。只有一層 path → 內容的 map，沒有目錄概念。
final class FakeFileStore: FileStore {
    /// 一次寫入。`atomic` 記的是走了哪個方法——layout.json 必須走暫存檔換名那條，
    /// 而兩條路徑在「檔案內容變了」這件事上看起來一樣。
    struct WriteRecord: Equatable {
        let path: String
        let contents: String
        let atomic: Bool
    }

    private(set) var files: [String: String]
    private(set) var writes: [WriteRecord] = []
    /// 對這些路徑的寫入一律失敗。用來驗 workmode.sh:1000 與 1248 的錯誤分支。
    var unwritablePaths: Set<String> = []
    /// 對這些路徑的讀取一律失敗（`exists` 仍回 true）。真的 `FileManagerStore.read`
    /// 在權限不足或路徑是目錄時就是這個形狀，而 `load_layout` 與 `read_state` 對它的
    /// 反應相反（前者硬失敗、後者回空字串），所以那兩條分支需要走得到。
    var unreadablePaths: Set<String> = []

    init(files: [String: String] = [:]) {
        self.files = files
    }

    func exists(atPath path: String) -> Bool {
        files[path] != nil
    }

    func read(atPath path: String) throws -> String? {
        guard !unreadablePaths.contains(path) else {
            throw FileStoreError.readFailed(path: path)
        }
        return files[path]
    }

    func write(_ contents: String, toPath path: String) throws {
        try record(contents, path, atomic: false)
    }

    func writeAtomically(_ contents: String, toPath path: String) throws {
        try record(contents, path, atomic: true)
    }

    private func record(_ contents: String, _ path: String, atomic: Bool) throws {
        guard !unwritablePaths.contains(path) else {
            // 失敗就不動內容：bash 那側 `>|` 失敗會保留舊內容（noclobber），
            // 而 mktemp 那條是 `rm -f "$tmp"` 後原檔沒動。兩者都是「舊的還在」。
            throw FileStoreError.writeFailed(path: path)
        }
        writes.append(WriteRecord(path: path, contents: contents, atomic: atomic))
        // **磁碟上多一個換行**：真的 `FileManagerStore` 兩個 write 都寫 `contents + "\n"`
        // （它的合約是「寫這些**行**」）。`writes` 記的是呼叫端傳了什麼，`files` 記的是
        // 讀回來會是什麼——少了這個換行，任何對讀回內容做**整串比對**的程式碼在測試裡
        // 都是綠的而在真實世界永遠不相等（yabai signal 那條路的 debounce token 就這樣
        // 壞了很久；那支 2026-09-14 隨 yabai 退役了，但這個坑本身還在）。
        files[path] = contents + "\n"
    }
}

/// 假的終端機。
final class FakeTerminal: Terminal {
    var hasControllingTTY: Bool
    private var lines: [String]
    private(set) var readCount = 0

    init(hasControllingTTY: Bool = true, lines: [String] = []) {
        self.hasControllingTTY = hasControllingTTY
        self.lines = lines
    }

    /// 沒有更多輸入時回 nil＝EOF。bash 是 `IFS= read -r label < /dev/tty || label='-'`，
    /// 所以 EOF 是一條有意義的路徑，不能在這裡丟錯。
    func readLine() -> String? {
        readCount += 1
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

/// 假的 window server。沒設 `actual` 的視窗回要求的那個 frame（＝app 照做）。
final class FakeWindowServer: WindowServer {
    struct Call: Equatable {
        let window: String
        let frame: Rect
    }

    private(set) var calls: [Call] = []
    /// 讓某個視窗「夾」成別的值。
    var actual: [String: Rect] = [:]
    /// 讓某個視窗設不下去。
    var failing: Set<String> = []

    func setFrame(window: String, _ frame: Rect) throws -> Rect {
        calls.append(Call(window: window, frame: frame))
        if failing.contains(window) {
            throw FakeError.unstubbed(argv: ["setFrame", window])
        }
        return actual[window] ?? frame
    }
}
