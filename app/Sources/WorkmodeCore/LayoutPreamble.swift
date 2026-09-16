import WorkmodeDomain

/// `workmode` 與 `workmode --space` 共同的開場：讀設定 → 認地點 → 決定 profile。
///
/// 抽出來不是為了整潔，是因為**兩條套用路徑必須用同一套判斷**。`--space` 若自己再寫
/// 一次「哪個 profile 生效」，兩份規則遲早分歧，而症狀是「同一台機器上 `workmode` 與
/// `workmode --space` 套的是不同的 profile」，沒有任何訊息說得出為什麼。
///
/// 從 `ApplyLayout` 整段搬出來，行為零變更——那個檔當時 398 行，而 swiftlint 的
/// `file_length` 在 400 行報警且 `.swiftlint.yml` 明文禁止調參數。
struct LayoutPreamble {
    /// 三種失敗，呼叫端各自翻成自己的 Outcome。訊息在這裡就已經發過事件了。
    enum Failure: Equatable, Sendable {
        case layoutUnavailable(LayoutLoadFailure)
        case locationUnrecognized
        case profileUnresolved
    }

    let yabai: any YabaiClient
    let reporter: any Reporter
    let reading: LayoutReading
    let renderRaw: (JSONValue) -> String
    let loader: LayoutLoader
    let stateReader: StateReader
    let activeLocation: ActiveLocation

    struct Decided {
        let config: JSONValue
        let location: String
        let choice: ProfileChoice
    }

    enum Step {
        case ready(Decided)
        case failed(Failure)
    }

    /// - Parameter want: 使用者指定的 profile。`""` ＝ 沒指定（bash 的 `want=""`）。
    /// 「這次要套哪個地點的哪個 profile」。三種失敗各自已經 report 過了。
    ///
    /// 一條線不是三件事：state 決定 active，active 決定 choice。
    func decide(want: String) -> Step {
        let loaded: LayoutLoader.Loaded
        do {
            loaded = try loader.load()
        } catch let failure as LayoutLoadFailure {
            return .failed(.layoutUnavailable(failure))
        } catch {
            // `LayoutLoader.load` 只 throw `LayoutLoadFailure`，這條是型別系統要的。
            return .failed(.layoutUnavailable(.unreadable(path: "")))
        }
        let config = loaded.config
        // `state=$(read_state)`：剝掉檔尾換行的是這個捕獲，不是 read_state 自己。
        let state = CommandSubstitution.capture(stateReader.read())

        guard let active = activeLocation.resolve(state: state, config: config) else {
            reporter.report(.locationUnrecognized)
            listConnectedDisplays()
            reporter.report(.manualLocationHinted)
            return .failed(.locationUnrecognized)
        }

        // `desc=$(location_desc "$location" "$json")`：命令替換砍掉尾端換行，
        // 而 `// empty` 與 jq 的 runtime error 都收斂成空字串。
        let desc = reading.describe(active.location, in: config)

        let choice: ProfileChoice
        do {
            choice = try ProfileResolution.resolve(location: active.location, want: want,
                                                   state: state, in: config,
                                                   renderRaw: renderRaw)
        } catch let error as ProfileResolutionError {
            guard case let .unknownProfile(want, location, available) = error else {
                return .failed(.profileUnresolved)
            }
            reporter.report(.profileNotInLocation(want: want, location: location,
                                                  available: available))
            return .failed(.profileUnresolved)
        } catch {
            return .failed(.profileUnresolved)
        }

        reporter.report(.modeChosen(location: active.location, desc: desc,
                                    overridden: active.source == .override,
                                    profile: choice.name, profileSource: choice.source))
        // `[ -n "$stale" ] && printf …`：只有記憶被丟掉的那次才印。
        if !choice.ignoredMemory.isEmpty {
            reporter.report(.rememberedProfileGone(stale: choice.ignoredMemory,
                                                   location: active.location,
                                                   profile: choice.name))
        }
        return .ready(Decided(config: config, location: active.location, choice: choice))
    }

    /// `yabai -m query --displays 2>/dev/null | jq -r '.[] | "      \(.uuid)  …"'`
    /// （workmode.sh:1273-1274）。
    ///
    /// 一台螢幕一個事件。jq 是串流的，所以 runtime error 之前印出去的行留著，
    /// 之後的整批不見——因此這裡是 `return` 而不是 `continue`。
    private func listConnectedDisplays() {
        guard let displays = try? yabai.query(.displays) else { return }
        let elements: [JSONValue]
        switch displays {
        case let .array(items): elements = items
        case let .object(members): elements = members.map(\.value)
        // `.[]` 對純量是 runtime error，而 query 失敗是空輸入（rc=0 零輸出）。
        default: return
        }
        for element in elements {
            switch element {
            // `null.uuid` 是 null 不是錯，但它的兩個 floor 必定報錯，所以下面那道
            // guard 會接住它。純量在 `.uuid` 那次索引就中止串流。
            case .object, .null: break
            default: return
            }
            guard let width = Measurements.flooredFrameField(element, "w"),
                  let height = Measurements.flooredFrameField(element, "h") else { return }
            reporter.report(.connectedDisplayListed(
                uuid: JQPrint.interpolate(element["uuid"] ?? .null),
                width: width, height: height
            ))
        }
    }
}
