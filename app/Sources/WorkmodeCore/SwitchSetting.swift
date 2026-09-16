import WorkmodeDomain

/// `switch_setting`（workmode.sh:931-1006）。
///
/// 只寫狀態檔，不套用佈局——要再跑一次 workmode 才生效。
///
/// 這一支最重要的性質不是文法解析，是**訊息先累積不印**：任何一半失敗都會 return
/// 而不寫檔，此時若已經印過「已固定用地點 X」就是在說謊，狀態檔根本沒動。所以四句
/// 成功訊息一路存著，等 `FileStore.write` 真的成功才一起送出去（workmode.sh:953-955
/// 的註解就是在講這件事）。
public struct SwitchSetting {
    public enum Outcome: Equatable, Sendable {
        /// 狀態檔寫成功。
        case updated
        /// bash 的 `return 1`：文法錯、地點或 profile 不認得、或寫不進去。
        case rejected
        /// `load_layout` 失敗（rc=1，訊息由呼叫端依失敗種類決定）。
        case layoutUnavailable(LayoutLoadFailure)
    }

    private let loader: LayoutLoader
    private let stateReader: StateReader
    private let files: any FileStore
    private let statePath: String
    private let active: ActiveLocation
    private let measurements: WindowMeasurements
    private let reporter: any Reporter
    private let interactive: SwitchInteractive

    public init(yabai: any YabaiClient,
                files: any FileStore,
                picker: any Picker,
                layoutPath: String,
                statePath: String,
                parse: @escaping (String) throws -> JSONValue,
                renderRaw: @escaping (JSONValue) -> String,
                reporter: any Reporter)
    {
        loader = LayoutLoader(files: files, path: layoutPath, parse: parse,
                              reporter: reporter)
        stateReader = StateReader(files: files, path: statePath)
        self.files = files
        self.statePath = statePath
        active = ActiveLocation(yabai: yabai, reporter: reporter)
        measurements = WindowMeasurements(yabai: yabai)
        self.reporter = reporter
        interactive = SwitchInteractive(picker: picker, active: active,
                                        measurements: measurements,
                                        renderRaw: renderRaw, reporter: reporter)
    }

    public func run(argument: String) -> Outcome {
        let loaded: LayoutLoader.Loaded
        do {
            loaded = try loader.load()
        } catch let failure as LayoutLoadFailure {
            return .layoutUnavailable(failure)
        } catch {
            return .layoutUnavailable(.unreadable(path: ""))
        }
        let config = loaded.config
        // `state=$(read_state)`：剝掉檔尾換行的是這個捕獲，不是 read_state 自己。
        let state = CommandSubstitution.capture(stateReader.read())

        // `[ -z "$arg" ]` → 走選單。bash 是 `switch_interactive …; return $?`，
        // 而選單最後又會呼叫回 `switch_setting`，所以這裡是一次真的遞迴。
        guard !argument.isEmpty else {
            guard let chosen = interactive.pick(state: state, config: config) else {
                return .rejected
            }
            return apply(argument: chosen, state: state, config: config)
        }
        return apply(argument: argument, state: state, config: config)
    }

    private func apply(argument: String, state: String, config: JSONValue) -> Outcome {
        // `case "$arg" in */*)`：切在**第一個**斜線。`a/b/c` 的 profile 是 `b/c`
        // （`${arg#*/}` 砍的是最短前綴），那個 profile 名字不會存在，於是走驗證失敗
        // 那條——與「切在最後一個斜線」的結果不同，所以不能寫成 split 取兩段。
        let location: String
        let profile: String
        if let slash = argument.firstIndex(of: "/") {
            location = String(argument[argument.startIndex ..< slash])
            profile = String(argument[argument.index(after: slash)...])
        } else {
            location = argument
            profile = ""
        }

        // 兩半都空＝使用者只打了一個斜線。不擋的話它會走完整個流程、重寫狀態檔、
        // 印出「跑 workmode.sh 套用佈局」，而什麼都沒改。
        if location.isEmpty, profile.isEmpty {
            reporter.report(.switchArgumentEmpty(argument: argument))
            return .rejected
        }

        var next = state
        var pending: [WorkmodeEvent] = []
        guard pin(location: location, state: &next, pending: &pending, config: config),
              pin(profile: profile, state: &next, pending: &pending, config: config)
        else { return .rejected }

        do {
            try files.write(next, toPath: statePath)
        } catch {
            reporter.report(.stateFileUnwritable(path: statePath))
            return .rejected
        }

        // 寫成功了，這時候說「已固定…」才是真的。
        for event in pending {
            reporter.report(event)
        }
        reporter.report(.switchHintShown)
        return .updated
    }

    /// 地點那一半。回 false 是已經 report 過的拒絕；名字是空的就什麼都不做。
    ///
    /// 兩半都收 `inout` 而不是各自回一份新狀態：profile 那半要對照「處理完地點
    /// 之後」的狀態驗證（見它的註解），所以它們是有順序的同一串修改，不是兩個
    /// 獨立的計算。
    private func pin(location: String, state: inout String,
                     pending: inout [WorkmodeEvent], config: JSONValue) -> Bool
    {
        guard !location.isEmpty else { return true }
        if location == reservedAuto {
            state = capture(state, key: "location", value: "")
            // 這句話裡的 `$(detect_location …)` 在**組訊息時**就跑了，所以即使
            // 後面寫檔失敗、這句永遠不會被印出來，yabai 還是被問過一次。
            let detected = measurements.detectLocation(in: config) ?? unrecognizedLocation
            pending.append(.locationOverrideCleared(detected: detected))
            return true
        }
        guard isKnown(location, in: config) else {
            reporter.report(.switchLocationUnknown(location: location,
                                                   available: locationNames(in: config)))
            return false
        }
        state = capture(state, key: "location", value: location)
        pending.append(.locationPinned(location: location))
        return true
    }

    /// profile 那一半。回 false 是已經 report 過的拒絕；名字是空的就什麼都不做。
    private func pin(profile: String, state: inout String,
                     pending: inout [WorkmodeEvent], config: JSONValue) -> Bool
    {
        guard !profile.isEmpty else { return true }
        // 用改過的 state 而不是原本那份：profile 要對照「處理完地點之後」生效的
        // 地點驗證，否則 `--switch office/休閒` 會拿舊地點去查 profile 清單。
        guard let current = active.resolve(state: state, config: config) else {
            reporter.report(.switchLocationUnresolved)
            return false
        }
        let here = current.location
        if profile == reservedAuto {
            state = capture(state, key: "profile." + here, value: "")
            pending.append(.profileMemoryCleared(location: here))
            return true
        }
        guard profileNames(inLocation: here, in: config)
            .split(separator: " ").map(String.init).contains(profile)
        else {
            reporter.report(.switchProfileUnknown(
                want: profile, location: here,
                available: profileNames(inLocation: here, in: config)
            ))
            return false
        }
        state = capture(state, key: "profile." + here, value: profile)
        pending.append(.profilePinned(location: here, profile: profile))
        return true
    }

    /// `state=$(state_set "$state" …)`。
    ///
    /// **那個 `$(…)` 不是排版**：`state_set` 的產物每一筆都帶結尾換行，而寫檔時
    /// adapter 又補一個（`printf '%s\n'`）。少了這一次剝除，狀態檔每被 `--switch`
    /// 寫一次就多長一行——實測就是這樣抓到的（stdout、stderr、rc 全同，只有檔案
    /// 多一個空行）。
    private func capture(_ content: String, key: String, value: String) -> String {
        CommandSubstitution.capture(StateFile.set(content, key: key, value: value))
    }

    /// 與 `ActiveLocation.isKnown` 同一個判準（`[ -n "$(location_desc …)" ]`），
    /// 包含「desc 是空字串的地點會被判成不存在」那個既有行為。
    private func isKnown(_ location: String, in config: JSONValue) -> Bool {
        guard let described = try? LayoutQuery.locationDescription(location, in: config)
        else { return false }
        if case let .string(text) = described {
            return !text.isEmpty
        }
        return true
    }

    private func locationNames(in config: JSONValue) -> String {
        (try? LayoutQuery.locationNames(in: config)) ?? ""
    }

    private func profileNames(inLocation location: String, in config: JSONValue) -> String {
        (try? LayoutQuery.profileNames(inLocation: location, in: config)) ?? ""
    }
}

/// 地點與 profile 共用的保留字。`layout.json` 的驗證擋掉同名的地點與 profile，
/// 所以這個字在兩層都只有一個意思。
let reservedAuto = "auto"

/// `detect_location "$json" || echo '認不出來'` 的那個 fallback。
let unrecognizedLocation = "認不出來"
