import WorkmodeDomain

// 一次執行的外圍：讀設定、認地點、確認 app 起來了、決定用哪個 profile，
// 以及三段抬頭。這些在套版迴圈**之前或外面**發生。

/// `ensure_app`（workmode.sh:620-633）。
public enum AppEvent: Equatable, Sendable {
    /// workmode.sh:624。要開了。
    case appNotRunning(app: String)

    /// workmode.sh:625。`open -a` 非零。
    case appLaunchFailed(app: String)

    /// workmode.sh:629。等到了。`waitedSeconds` 是**迴圈計數**（第幾次查到），
    /// 型別化成 Int 就是為了讓「這個數字是實際等到的次數」可斷言——照抄成字串的話，
    /// 把它換成常數 10 的錯誤在測試裡看不出來。
    case appLaunched(app: String, waitedSeconds: Int)

    /// workmode.sh:631。逾時。`seconds` 是常數 `APP_WAIT_SECONDS`，不是迴圈計數
    /// （兩者在這裡相等，但來源不同）。
    case appLaunchTimedOut(app: String, seconds: Int)

    public var channel: OutputChannel {
        switch self {
        case .appLaunchFailed, .appLaunchTimedOut, .appLaunched, .appNotRunning:
            .stdout
        }
    }
}

/// 決定「這次要用哪個地點與哪個 profile」的那一段
/// （`resolve_profile` workmode.sh:207-234，以及 `main` 開頭的地點判斷）。
public enum ModeEvent: Equatable, Sendable {
    /// workmode.sh:215。`--probe 會議` 那個名字不在這個地點底下。
    ///
    /// bash 是 `resolve_profile` 自己印的，而它的呼叫端只看 rc；移植後印的人變成
    /// `ApplyLayout`（Domain 那支是純函式、throw 一個帶三個欄位的錯誤），所以這個
    /// case 的家在這裡。`available` 是**重算一次**的 `profile_names_in` 而不是那個
    /// 前後補了空白的 `names`——bash 那句 printf 就是重算的。
    case profileNotInLocation(want: String, location: String, available: String)

    /// workmode.sh:1262。第一個參數是不認得的旗標。
    ///
    /// 沒有欄位：那句用法字串裡沒有 `%s`，bash 不告訴使用者是哪個旗標壞了。
    case usageRejected

    /// workmode.sh:1272。三段「認不出地點」的第一段。
    ///
    /// 這三段走 **stdout**（`echo`，不是 `>&2`），與 `load_layout`／`active_location`
    /// 那兩句相反——`main` 的 stdout 不是任何人的回傳值，所以沒有污染的問題。
    case locationUnrecognized

    /// workmode.sh:1274。當下接到的一台螢幕。
    ///
    /// **不是 printf 而是 jq 的字串插值**（與 `ruleWindowPositionReported` 同一種），
    /// 所以三個欄位都是 String：uuid 缺席時插值成字面的 `null`，而兩個 floor 走
    /// `JQNumber` 的 dtoa 模型。這一行「沒有發生」的表示法是不發事件——
    /// jq 的 runtime error 中止整個串流，後面的螢幕連印都沒印。
    case connectedDisplayListed(uuid: String, width: String, height: String)

    /// workmode.sh:1275。三段的最後一段：叫使用者怎麼自己救。
    case manualLocationHinted

    /// workmode.sh:1294。抬頭。
    ///
    /// `overridden` 是 Bool 而不是那句「，手動覆寫」：那段文字是 1280 行的變數賦值，
    /// 照約定 5 只能活在 renderer。`profileSource` 同理——1288-1292 那個 case 把四種
    /// 來源收成三種文字（`default` 與 `first` 共用一句），而那個收斂本身是 renderer
    /// 的事；型別化成 Source 才能斷言「memory 沒有被誤印成 default」。
    case modeChosen(location: String, desc: String, overridden: Bool,
                    profile: String, profileSource: ProfileResolution.Source)

    /// workmode.sh:1296。記住的 profile 已經不在這個地點底下了。
    case rememberedProfileGone(stale: String, location: String, profile: String)

    public var channel: OutputChannel {
        switch self {
        case .connectedDisplayListed, .locationUnrecognized, .manualLocationHinted,
             .modeChosen, .rememberedProfileGone:
            .stdout
        case .profileNotInLocation, .usageRejected:
            .stderr
        }
    }
}

/// `main` 的段落抬頭。它們沒有 payload，存在的意義是**順序**。
///
/// 原本四句（1309／1314／1317／1367），2026-09-07 只剩 probe 這一句——「執行前／
/// 套用／執行後」那三段是 `ApplyLayout` 印的，那支退役之後它們一個發送者都沒有。
public enum BannerEvent: Equatable, Sendable {
    /// workmode.sh:1309。probe 模式的抬頭。
    ///
    /// 一個段落標題一個 case 而不是一個帶字串的 `bannerShown`：它們是獨立的 `echo`
    /// 站點（約定 1），而且 `--json` 的消費端要靠 kind 分辨自己讀到的是哪一段，
    /// 不該去 parse 那句中文。
    case probeBannerShown

    public var channel: OutputChannel {
        switch self {
        case .probeBannerShown:
            .stdout
        }
    }
}

/// 套版迴圈以外的事件。
public enum SessionEvent: Equatable, Sendable {
    /// 目標 app 沒在跑，要不要等它起來。
    case app(AppEvent)

    /// 這次用哪個地點、哪個 profile。
    case mode(ModeEvent)

    /// 段落抬頭。
    case banner(BannerEvent)

    /// workmode.sh:109。設定檔不在。這是 `load_layout` 唯一的 `printf`——
    /// 「不是合法 JSON」與結構問題那三段是 `validate_layout` 印的，它們的格式已經
    /// 有唯一的家（`workmode validate` 的輸出），所以不在這個 enum 裡。
    case layoutFileMissing(path: String)

    /// workmode.sh:569。狀態檔裡的 `location` 鍵指到一個 `location_desc` 印不出東西的地點。
    ///
    /// 這句話走 stderr 而且**不是**失敗路徑的結尾：警告完就回退自動偵測。
    case stateLocationNotInLayout(location: String)

    public var channel: OutputChannel {
        switch self {
        case let .app(event): event.channel
        case let .mode(event): event.channel
        case let .banner(event): event.channel
        case .layoutFileMissing, .stateLocationNotInLayout:
            .stderr
        }
    }
}
