import WorkmodeDomain

/// `load_layout`（workmode.sh:107-116）。
///
/// 路徑不是這一層算的，是建構時傳進來的。bash 用「腳本自己所在的目錄」
/// （`dirname "${BASH_SOURCE[0]}"`），而 Swift 的執行檔住在 `.build/debug/workmode`
/// 或安裝目的地，跟設定檔完全無關——照抄那個算法會指向錯的地方，所以決定權留給
/// 最外層（`TatamiPaths`）。
public struct LayoutLoader {
    /// 讀進來的設定：原文與解析後的值。
    ///
    /// 兩份都留著不是冗餘：bash 的 `load_layout` 印的是**原文**（`printf '%s' "$json"`，
    /// 而且沒有結尾換行），後續函式再各自拿它去餵 jq；把原文丟掉、需要時從
    /// JSONValue 重新序列化，寫回 layout.json 時就會得到一個無意義的全檔 diff
    /// （CLAUDE.md 記著這條：jq 逐字保留數字字面值）。
    public struct Loaded: Equatable, Sendable {
        /// `printf '%s' "$json"` 印出去的那串位元組，**沒有結尾換行**——
        /// `json=$(cat …)` 已經把檔尾換行剝掉了，而這裡也不補回去。
        public let text: String
        public let config: JSONValue

        public init(text: String, config: JSONValue) {
            self.text = text
            self.config = config
        }
    }

    private let files: any FileStore
    private let path: String
    private let parse: (String) throws -> JSONValue
    private let reporter: any Reporter

    /// - Parameter parse: JSON 解析。用注入的函式而不是直接呼叫 `WorkmodeWire`：
    ///   相依方向是 Wire → Domain，Core 不許 import Wire（`SpaceRects.compute` 的
    ///   `idText:` 已經是同一個做法）。
    public init(files: any FileStore, path: String,
                parse: @escaping (String) throws -> JSONValue,
                reporter: any Reporter)
    {
        self.files = files
        self.path = path
        self.parse = parse
        self.reporter = reporter
    }

    /// 成功回原文與解析結果；四條失敗路徑各自 throw。
    ///
    /// 只有 `.missing` 會在這裡發事件——那是 `load_layout` 自己的 `printf`
    /// （workmode.sh:109）。另外三條在 bash 是 `validate_layout` 印的，而那三段格式
    /// 已經有唯一的家（`workmode validate` 的輸出，差分 harness 逐位元組守著它），
    /// 在 renderer 再抄一份會變成兩份要同步的敘述。
    public func load() throws -> Loaded {
        guard files.exists(atPath: path) else {
            reporter.report(.layoutFileMissing(path: path))
            throw LayoutLoadFailure.missing(path: path)
        }
        // `json=$(cat "$LAYOUT_FILE")`。bash 那側 cat 失敗時 stderr 會有 cat 自己的
        // 訊息、`json` 是空字串，而空字串餵給 `jq empty` 是 rc=0（**靜默通過**）於是
        // load_layout 回 0 並印零位元組。那是既有的 bug——空的設定應該被擋下來——
        // 所以這裡跟 `validate` 那兩條已知分歧同一個判斷：不複製它。
        guard let raw = try? files.read(atPath: path) else {
            throw LayoutLoadFailure.unreadable(path: path)
        }
        // 命令替換剝掉**全部**尾端換行，而後面的 `printf '%s'` 一個都不補。真實的
        // layout.json 是以一個換行結尾的檔案，所以這一步不做的話 load_layout 的輸出
        // 就多一個位元組——而那個字串會被寫回檔案（`--save`）。
        var text = raw
        while text.hasSuffix("\n") {
            text.removeLast()
        }
        guard let config = try? parse(text) else {
            throw LayoutLoadFailure.unparsable(path: path)
        }
        let problems = LayoutValidator.validate(config)
        guard problems.isEmpty else {
            throw LayoutLoadFailure.invalid(problems: problems)
        }
        return Loaded(text: text, config: config)
    }
}

/// `load_layout` 的四種失敗。
///
/// 分成四個 case 而不是一個 bool：呼叫端要印的東西不同（`.missing` 的訊息已經發過
/// 事件，另外三條的文字由 `workmode validate` 那套 renderer 產生）。
public enum LayoutLoadFailure: Error, Equatable, Sendable {
    /// workmode.sh:108 的 `[ ! -f "$LAYOUT_FILE" ]`。事件已發。
    case missing(path: String)
    /// bash 沒有對應的分支（見 `load` 的註解）。
    case unreadable(path: String)
    /// workmode.sh:36 的 `jq empty` 失敗。
    case unparsable(path: String)
    /// workmode.sh:44-95 的兩段檢查。順序就是要印出去的順序。
    case invalid(problems: [LayoutProblem])
}

/// `read_state`（workmode.sh:547-550）。
///
/// 不存在**不是錯誤**：`[ -f … ] && cat || printf ''`，回空字串。與 `load_layout`
/// 刻意不同——那邊缺檔是硬失敗，這邊缺檔是「還沒有人設過任何覆寫」的正常狀態。
/// 回的是 `read_state` **本身**的輸出，沒有剝結尾換行——剝的是呼叫端那個
/// `state=$(read_state)`（workmode.sh:934、1269），見 `CommandSubstitution`。
public struct StateReader {
    private let files: any FileStore
    private let path: String

    public init(files: any FileStore, path: String) {
        self.files = files
        self.path = path
    }

    public func read() -> String {
        guard files.exists(atPath: path) else { return "" }
        // cat 失敗也是空字串：bash 的 `||` 接的是整個 `[ -f ] && cat`，
        // cat 非零時同樣落到 `printf ''`。
        return (try? files.read(atPath: path)) ?? ""
    }
}
