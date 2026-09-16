import WorkmodeDomain

// 這個檔案只有 protocol 與它們的參數型別，沒有一行實作。
//
// 它存在的理由不是分層美學：bash 那側「會呼叫 yabai 的函式一律靠實機驗證」，
// 因為 bash 沒有接縫可以塞假的 yabai。剩下這 21 個會碰外部世界的函式因此完全沒有
// 差分基準——它們的輸出取決於當下接了幾台螢幕、開了哪些視窗。有了 port 之後，
// 「設完 ratio 要重新量、沒有比 sibling 寬就翻成 1-ratio」這類編排邏輯第一次
// 可以在沒有 yabai 的情況下驗，而且**順序**驗得到（見 YabaiCall 的註解）。

// MARK: - yabai

/// 唯讀的 `yabai -m query`。每個 case 對應 workmode.sh 裡一個實際存在的呼叫形式，
/// 不是想像得到的組合——`--windows --display` 沒有 case，因為 bash 從來沒這樣問過。
///
/// 參數一律是 `String` 而不是 `Int`：bash 那側就是把字串塞進 argv（`--space "$ws"`
/// 的值來自 `visible_space_on`，那是一個 jq 值的字面列印，不保證是 `1` 這種形狀），
/// 先轉成 Int 等於在移植之前先改掉行為。
public enum YabaiQuery: Equatable, Sendable {
    /// workmode.sh:555（detect_location）、1112、1273、1320
    case displays
    /// workmode.sh:851（apply_ratio 要那台螢幕的 frame.w）
    case display(String)
    /// workmode.sh:1113、1321
    case spaces
    /// workmode.sh:879、886（resolve_rules 用 app 比對，掃全部視窗）
    case windows
    /// workmode.sh:647、651、672、705、713、738、739、755、756、844、849
    case window(String)
    /// workmode.sh:696、715、828、1137
    case windowsOnSpace(String)

    /// 實際傳給 yabai 的 argv（不含 `yabai -m`）。
    ///
    /// 之所以把 argv 攤出來當公開介面：fake 的 stub 與命令記錄都用它當鍵，於是
    /// 「旗標與參數的順序」本身變成可斷言的東西，而那正是 CLAUDE.md 記著的坑
    /// （`window --deminimize <id>` 與 `window <id> --deminimize` 只有前者能用）。
    public var argv: [String] {
        switch self {
        case .displays: ["query", "--displays"]
        case let .display(index): ["query", "--displays", "--display", index]
        case .spaces: ["query", "--spaces"]
        case .windows: ["query", "--windows"]
        case let .window(id): ["query", "--windows", "--window", id]
        case let .windowsOnSpace(index): ["query", "--windows", "--space", index]
        }
    }
}

/// 會改變狀態的 `yabai -m window`。
public enum YabaiCommand: Equatable, Sendable {
    /// workmode.sh:648。id 是**旗標的參數**，寫成 `window <id> --deminimize` 會失敗，
    /// 所以這件事釘在 `argv` 裡而不是留給 Adapter 自己拼。
    case deminimize(window: String)
    /// workmode.sh:687（exile_strangers）、778（樹根）、789（每條指令的 place）
    case moveToSpace(window: String, space: String)
    /// workmode.sh:790。第一個是被搬的視窗，第二個是它要貼上去的目標。
    case warp(window: String, onto: String)
    /// workmode.sh:796
    case toggleSplit(window: String)
    /// workmode.sh:805。bash 是 `window "$target" --swap "$id"`——主詞是 target，
    /// 參數是 id；兩個位置對調在畫面上看起來一樣，但記錄下來就不一樣了。
    case swap(window: String, with: String)
    /// workmode.sh:832、837。`ratio` 不含 `abs:` 前綴（那由 argv 補），但**值保留字串**
    /// 而不是 Double：837 的 inverse 是 `awk '{printf "%.4f", 1 - $1}'` 產生的，
    /// 位數是它的一部分（`0.7500` 不是 `0.75`），轉成 Double 再印回去就丟掉了。
    case setRatio(window: String, ratio: String)

    public var argv: [String] {
        switch self {
        case let .deminimize(id): ["window", "--deminimize", id]
        case let .moveToSpace(id, space): ["window", id, "--space", space]
        case let .warp(id, target): ["window", id, "--warp", target]
        case let .toggleSplit(id): ["window", id, "--toggle", "split"]
        case let .swap(id, other): ["window", id, "--swap", other]
        case let .setRatio(id, ratio): ["window", id, "--ratio", "abs:\(ratio)"]
        }
    }
}

/// yabai 呼叫失敗。bash 只在兩個地方看 exit code（687 的 `--space`、790 的 `--warp`），
/// 其餘一律 `2>/dev/null` 丟掉——但 port 這側一律 throw，讓「哪裡該忽略」變成 Core
/// 裡看得見的決定（`try?`）而不是藏在 Adapter 的 `2>/dev/null`。
public enum YabaiError: Error, Equatable, Sendable {
    case commandFailed(argv: [String], status: Int32)
    /// query 回的東西解不成 JSON。bash 那側是 jq 吃到壞輸入回 rc=5。
    case malformedOutput(argv: [String])
}

public protocol YabaiClient {
    /// 回 `JSONValue` 而不是原始 bytes：解析屬於 Wire，而 Core 不許 import Wire
    /// （相依方向是 CLI → Adapters → Core → Domain）。若讓 port 回 String，Core 就
    /// 必須自己有一個 parser，那個 parser 遲早會與 Wire 的分歧。
    ///
    /// 而且 Domain 的消費端本來就吃 JSONValue：`SpaceRects.compute(windows:)`、
    /// `Displays.visibleSpace(on:in:)`、`LayoutTree.prune(_:live:)` 全部如此，
    /// 它 order-preserving 又把數字留成字面值（jq 1.8 逐字保留數字，`2.50` 不變 `2.5`）。
    func query(_ query: YabaiQuery) throws -> JSONValue

    func run(_ command: YabaiCommand) throws
}

/// 對一個視窗設 frame，回**設完重讀**的實際值。
///
/// 只有一個方法，因為其餘的查詢與搬移都走 `YabaiClient` 的形狀（`WindowServerClient`
/// 兩個都實作）：Core 讀 yabai 形狀的 JSON 讀了兩年，換一套型別只會把
/// `LayoutPreamble`／`RuleResolution`／`MinimizedWindows` 全部拖進來重寫。
/// yabai 的 bsp 沒有「設 frame」這個動作，所以它是新 port 而不是 `YabaiCommand` 的 case。
public protocol WindowServer {
    func setFrame(window: String, _ frame: Rect) throws -> Rect
}

// MARK: - osascript 那兩件事

/// workmode.sh:584 的 `safari_tab_dump`。
public protocol SafariClient {
    /// 回原始的 TSV 文字（`<window_id>\t<url>\t<title>\t<is-current>` 每行一筆），
    /// 不先切成結構：`WindowMatching.findWindows(kind:value:dump:)` 與
    /// `currentTabURL(window:dump:)` 吃的就是這份字串，而它們內部走的是 awk 的
    /// 位元組語意（`$2 == n` 是 strnum 比較、`.` 吃一個位元組）。先解析成
    /// `[Tab]` 會把那些行為丟掉，等於偷偷改掉比對結果。
    func tabDump() throws -> String
}

/// workmode.sh:617 的 `app_running`。
///
/// 分成獨立的 port 而不是塞進 AppLauncher：bash 那側 `app_running` 是唯讀的判斷，
/// `ensure_app` 的輪詢會連續問它很多次，測試要能讓它「第 3 次才回 true」。
public protocol AppQuery {
    /// 不 throw：bash 是 `[ "$(osascript … 2>/dev/null)" = "true" ]`，osascript 失敗
    /// 與回答「沒在跑」在那裡完全同一條路。
    func isRunning(app: String) -> Bool
}

/// workmode.sh:625 的 `open -a "$app"`。bash 看它的 exit code（開不起來就 return 1），
/// 所以這裡 throw。
public protocol AppLauncher {
    func open(app: String) throws
}

public enum AppLauncherError: Error, Equatable, Sendable {
    case openFailed(app: String, status: Int32)
}

// MARK: - fzf

/// workmode.sh:1031、1052 的兩段式選單。
///
/// 兩次呼叫的旗標完全相同（`--delimiter='\t' --with-nth=1,2 --height=40% --reverse`），
/// 只有 prompt 與餵進去的行不同，所以是一個方法而不是兩個。
public protocol Picker {
    /// workmode.sh:1016 的 `command -v fzf`。
    var isAvailable: Bool { get }

    /// 回 nil 代表使用者取消（fzf rc≠0，bash 那邊是 `|| return 1`）。
    /// 行是整行原文（含 tab），呼叫端自己 `cut -f1`——bash 就是這樣做的。
    func pick(_ lines: [String], prompt: String) throws -> String?
}

// MARK: - 時間

/// 這個 port 存在的唯一理由是它讓輪詢測得到。
///
/// `restore_minimized`（workmode.sh:647-655）在 `--deminimize` 之後不能立刻查
/// `is-minimized`：還原是 macOS 的動畫，實測固定要 ~600ms（三次量測都是第 6 次輪詢）
/// 才翻成 false，立刻查必定讀到 true，於是每次成功的還原都會被報成失敗。
/// `ensure_app`（workmode.sh:627）同理，一次一秒最多十次。
///
/// 沒有這個 port，那兩段編排的測試會真的睡好幾秒；有了它，fake 可以瞬間推進。
public protocol Clock {
    /// workmode.sh:627 的 `sleep 1` 與 653 的 `sleep 0.1`。
    func sleep(seconds: Double)
}

// MARK: - 檔案

/// `layout.json`（workmode.sh:108-113）與狀態檔（548-551、1000）的讀寫。
public protocol FileStore {
    /// workmode.sh:108 與 548 的 `[ -f "$FILE" ]`。
    func exists(atPath path: String) -> Bool

    /// 檔案不存在時回 nil，讓呼叫端自己決定那是錯誤（load_layout 印「找不到設定檔」）
    /// 還是空字串（read_state 回 `printf ''`）。bash 那兩處的判斷不同，port 不該替它選。
    func read(atPath path: String) throws -> String?

    /// workmode.sh:1000 的 `printf '%s\n' "$state" >| "$STATE_FILE"`。
    /// 直接覆寫，沒有暫存檔：狀態檔壞掉的代價是重設一次。
    func write(_ contents: String, toPath path: String) throws

    /// workmode.sh:1246-1252：`mktemp` → 寫 → `mv -f`。
    /// 與 `write` 分開是因為那個註解本身就是理由——中途失敗不會留下半份 layout.json。
    func writeAtomically(_ contents: String, toPath path: String) throws
}

public enum FileStoreError: Error, Equatable, Sendable {
    case readFailed(path: String)
    case writeFailed(path: String)
}

// MARK: - 終端機

/// `--save` 的互動。
///
/// 這個 port 的重點是 `hasControllingTTY`：實測（2026-08-08）沒有 controlling tty 時
/// 互動不是失敗而是**無聲卡住**（timeout 3 兩分鐘都收不掉），所以 bash 在
/// workmode.sh:1070 就先擋下來。那個擋法必須跟著移植過來，而且要測得到——
/// 沒有 port 的話這條分支只能靠「從快捷鍵按一次看會不會卡死」驗。
public protocol Terminal {
    /// workmode.sh:1070 的 `[ ! -t 0 ] || [ ! -r /dev/tty ]`。
    var hasControllingTTY: Bool { get }

    /// workmode.sh:1163、1236 的 `IFS= read -r x < /dev/tty`。
    /// 從 /dev/tty 讀而不是 stdin：1163 那個迴圈的 stdin 是 here-string，
    /// 直接 read 會把待命名清單自己吃掉。回 nil 是讀到 EOF（bash 的 `|| label='-'`）。
    func readLine() -> String?
}
