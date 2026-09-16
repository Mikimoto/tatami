import WorkmodeDomain

// `switch_setting`（workmode.sh:931-1006）與 `switch_interactive`（1013-1057）。
//
// 拒絕與生效分成兩組不只是為了 case 數：這支命令的所有拒絕都走 stderr 且不寫檔，
// 所有生效都走 stdout 且寫了狀態檔，分組把那個對應關係變成型別上看得見的東西。

/// 不改任何東西就退出的五條路。全部走 stderr。
public enum SwitchRejection: Equatable, Sendable {
    /// workmode.sh:949。使用者只打了一個斜線，兩半都空。
    case switchArgumentEmpty(argument: String)

    /// workmode.sh:964。`available` 後面 renderer 還會補一個 ` auto`——那個字面的
    /// `auto` 是格式字串的一部分（`可用的有：%s auto`），不是 `location_names_from`
    /// 的輸出，所以它不在 payload 裡。
    case switchLocationUnknown(location: String, available: String)

    /// workmode.sh:976。要記 profile 但認不出當下的地點。
    case switchLocationUnresolved

    /// workmode.sh:992。與 `profileNotInLocation`（resolve_profile 那句）是**不同**
    /// 的站點：這句尾巴多一個 ` auto`，因為這裡的 `auto` 是可以打的。
    case switchProfileUnknown(want: String, location: String, available: String)

    /// workmode.sh:1001。
    case stateFileUnwritable(path: String)

    public var channel: OutputChannel {
        switch self {
        case .stateFileUnwritable, .switchArgumentEmpty, .switchLocationUnknown,
             .switchLocationUnresolved, .switchProfileUnknown:
            .stderr
        }
    }
}

/// 狀態檔真的被改了。全部走 stdout。
public enum SwitchOutcome: Equatable, Sendable {
    /// workmode.sh:1005。收尾那句，寫成功才印。
    case switchHintShown

    /// workmode.sh:961。`detected` 是那句話裡內嵌的 `detect_location`，
    /// 認不出來時是字面的「認不出來」。
    case locationOverrideCleared(detected: String)

    /// workmode.sh:969。
    case locationPinned(location: String)

    /// workmode.sh:982。
    case profileMemoryCleared(location: String)

    /// workmode.sh:988。
    case profilePinned(location: String, profile: String)

    public var channel: OutputChannel {
        switch self {
        case .locationOverrideCleared, .locationPinned, .profileMemoryCleared,
             .profilePinned, .switchHintShown:
            .stdout
        }
    }
}

/// `switch_interactive`：沒有 fzf、或選單選不出東西。
public enum PickerEvent: Equatable, Sendable {
    /// workmode.sh:1017。
    case pickerMissing

    /// workmode.sh:1018。緊接在上一句後面的第二行。
    case pickerFallbackLocations(available: String)

    /// workmode.sh:1039。選了 auto 但清掉覆寫之後偵測不出地點。
    case pickerLocationUnresolvedAfterAuto

    public var channel: OutputChannel {
        switch self {
        case .pickerFallbackLocations, .pickerLocationUnresolvedAfterAuto, .pickerMissing:
            .stderr
        }
    }
}

/// `workmode switch` 的事件。
public enum SwitchEvent: Equatable, Sendable {
    /// 什麼都沒改。
    case rejected(SwitchRejection)

    /// 狀態檔改了。
    case applied(SwitchOutcome)

    /// 互動選單那條路。
    case picker(PickerEvent)

    public var channel: OutputChannel {
        switch self {
        case let .rejected(event): event.channel
        case let .applied(event): event.channel
        case let .picker(event): event.channel
        }
    }
}
