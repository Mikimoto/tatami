// `ProfileResolution.Source` 是 `modeChosen` 的欄位（那個四→三的收斂屬 renderer）。
import WorkmodeDomain

// Core 對使用者說話的唯一出口。
//
// bash 那側 21 個函式一路 `printf`，窮舉下來有 60 多個站點。移植時**不**把那些
// 格式字串搬進 Core，而是讓 Core 發結構化事件、格式字串只活在 Adapters 的
// renderer 裡。四個理由，每一個都是實際的限制而不是分層美學：
//
// 1. `--json` 是需求。若 Core 產生人看的字串，JSON 模式就得從散文反推結構，
//    方向是反的（而且中文散文一旦改字，JSON 的欄位就跟著壞）。
// 2. **stdout 與 stderr 的分別是有作用的，不是排版**：`save_layout` 呼叫
//    `resolve_rules` 時帶 `2>/dev/null`（workmode.sh:1106，理由在 1102 的註解：
//    總表本來就含這次沒開的視窗，「找不到」在那裡是正常的），而 `main` 在 1306
//    呼叫同一支時**沒有**壓掉。同一個事件在兩個呼叫端要不要出現，取決於 bash 把它
//    送到哪個流，所以「送到哪」是事件的一部分。
// 3. 漸進輸出：套一次版面要跑好幾秒（`restore_minimized` 單一個視窗就可能 2 秒），
//    bash 是邊做邊印。事件流保留這個性質，「先收集完再一次輸出」會讓體感變差。
// 4. 測試強度：斷言型別化的事件比比對字串強。字串比對在「數字取自動作**之前**」
//    的情況下照樣會過，而那正是這個 repo 那條「量了才能講」要防的
//    （`workmode.sh` 的註解記了三次同一個坑）。
//
// 加新 case 的五條約定（後面每個 task 都會照著加自己的）：
//
// 1. 一個 bash `printf` 站點 = 一個 case。合併兩個站點等於宣稱它們永遠一起變——
//    `exile_strangers` 的收尾兩句就是反例：只有 stuck>0 那句會多一個欄位。
// 2. case 名字講「發生了什麼」不講那句話的文字（`ratioApplied` 而不是
//    `widthMessage`）。訊息改字時 case 名不該跟著改。
// 3. payload 是 bash 內插進去的值，**型別化**（數字就是數字）。先轉成字串就把
//    「這個數字是動作之後量的」這件事變成不可斷言。
// 4. 每個 case 自己知道 bash 把它送到 stdout 還是 stderr（見 `channel`）。
// 5. 格式字串只准活在 renderer 裡，而且一個站點恰好一個 case。renderer 的 switch
//    在 2026-08-18 從一支拆成一層一支（跟著這個 enum 的巢狀分組），每一支仍然窮舉、
//    仍然沒有 default，所以「少寫一個 case」照樣是編譯錯誤。Core 底下不得出現那些
//    中文字面值，`WorkmodeAdaptersTests` 那側的逐字比對是它們唯一的家。
//    可檢查：`grep -rn '<那句話的片段>' app/Sources/WorkmodeCore/` 要得 0。

/// bash 把這句話送到哪個流。
///
/// 不叫 OutputStream：Foundation 有一個同名的 class，而 renderer 住在會
/// `import Foundation` 的 Adapters。
public enum OutputChannel: Equatable, Sendable {
    /// bash 的 `printf` / `echo`（fd 1）。
    case stdout
    /// bash 的 `printf … >&2`（fd 2）。呼叫端可能用 `2>/dev/null` 整批壓掉。
    case stderr
}

/// Core 對使用者說的一句話。
///
/// 79 個站點分成五組巢狀 enum，一組一個檔（LayoutEvents.swift…）。分組的理由是
/// **renderer**：它一層一支 switch、每一支都窮舉且沒有 default，所以少寫一個 case
/// 是編譯錯誤。攤平成一個 79 case 的 enum 也有那個保證，但那支 switch 的複雜度就是
/// 79，而拆成多支 `String?` 的 helper 又一定要 `default: nil`——那會把保證整個拿掉
/// （2026-08-18 實測：79 個事件裡測試只釘到 24 個，另外 55 個沒有第二道網子）。
///
/// 呼叫端不必知道這個分組：EventFactories.swift 有 79 個一行的建構子，
/// `.minimizedWindowRestored(label:)` 照舊可用。
public enum WorkmodeEvent: Equatable, Sendable {
    /// 套版迴圈對視窗做的事：還原、放逐、分割、跳過角色。
    case layout(LayoutEvent)

    /// 規則比對與位置回報（`resolve_rules`／`report_rules`）。
    case rules(RuleEvent)

    /// 迴圈以外：讀設定、認地點、確認 app 起來了、決定 profile、段落抬頭。
    case session(SessionEvent)

    /// `workmode switch`。
    case switching(SwitchEvent)

    /// `workmode --space`：逐螢幕把目前可見的那個 space 排成它自己的樹。
    case space(SpaceEvent)

    /// `workmode --save`。
    case save(SaveEvent)

    /// tatami 自己的快捷鍵（取代 skhd）。
    case hotkey(HotkeyEvent)

    public var channel: OutputChannel {
        switch self {
        case let .layout(event): event.channel
        case let .rules(event): event.channel
        case let .session(event): event.channel
        case let .switching(event): event.channel
        case let .space(event): event.channel
        case let .save(event): event.channel
        case let .hotkey(event): event.channel
        }
    }
}

/// 事件的收受端。
///
/// 不 throw：bash 的 `printf` 失敗（例如 stdout 是壞掉的 pipe）不會讓任何一支
/// 函式改變流程，所以讓 Core 去處理輸出錯誤等於憑空多一條 bash 沒有的分支。
public protocol Reporter {
    func report(_ event: WorkmodeEvent)
}

/// 把送到某個流的事件整批丟掉。bash 那側的 `2>/dev/null`。
///
/// 為什麼是包裝而不是給 `RuleResolution.resolve` 加一個 `quiet:` 參數：bash 是
/// **呼叫端重導整個呼叫的 stderr**，而同一支 `resolve_rules` 的兩個呼叫端答案不同——
/// `main`（workmode.sh:1306）不壓，警告要讓使用者看到；`save_layout`（1106）帶
/// `2>/dev/null`，理由在 1102 的註解：總表本來就含這次沒開的視窗，「找不到」在那裡
/// 是正常的。
///
/// 包裝讓「要不要壓」這個決定留在呼叫端（與 bash 同一個形狀）；參數會讓被呼叫的
/// 函式去猜呼叫端想要什麼，而它猜不到——那個答案不在它手上。
///
/// 只丟一個流而不是收一組 channel：`2>/dev/null` 就是丟一個流，而「兩個都丟」在
/// bash 那側從來沒發生過，替它先寫好等於憑空多一條沒有對應的路徑。
public struct SilencedChannelReporter: Reporter {
    private let dropped: OutputChannel
    private let inner: any Reporter

    public init(dropping channel: OutputChannel, into inner: any Reporter) {
        dropped = channel
        self.inner = inner
    }

    public func report(_ event: WorkmodeEvent) {
        guard event.channel != dropped else { return }
        inner.report(event)
    }
}
