import WorkmodeDomain

/// `active_location`（workmode.sh:559-573）。
///
/// 狀態檔寫壞了不該讓整支腳本停擺：覆寫指到一個不存在的地點時**警告後回退**自動
/// 偵測，而不是失敗。那條回退是這一支唯一有分支的地方，也是它存在的理由。
public struct ActiveLocation {
    /// 這個地點是誰決定的。bash 印的是第二欄的字面文字（`override`／`detect`），
    /// 所以 rawValue 就是那兩個字，呼叫端不必再對照一張表。
    public enum Source: String, Equatable, Sendable {
        case override
        case detect
    }

    public struct Resolved: Equatable, Sendable {
        public let location: String
        public let source: Source

        public init(location: String, source: Source) {
            self.location = location
            self.source = source
        }
    }

    private let measurements: WindowMeasurements
    private let reporter: any Reporter

    public init(yabai: any YabaiClient, reporter: any Reporter) {
        measurements = WindowMeasurements(yabai: yabai)
        self.reporter = reporter
    }

    /// 回 nil ＝ bash 的 `return 1`（覆寫不可用而且偵測不到）。
    public func resolve(state: String, config: JSONValue) -> Resolved? {
        let wanted = StateFile.value(forKey: "location", in: state)
        if !wanted.isEmpty {
            if isKnown(wanted, in: config) {
                return Resolved(location: wanted, source: .override)
            }
            reporter.report(.stateLocationNotInLayout(location: wanted))
        }
        guard let detected = measurements.detectLocation(in: config) else { return nil }
        return Resolved(location: detected, source: .detect)
    }

    /// `[ -n "$(location_desc "$l" "$json")" ]`。
    ///
    /// 判的是「location_desc 印了東西沒有」而不是「這個地點存在嗎」，兩者不同：
    /// `desc` 是空字串時 bash 印一個換行、命令替換剝掉它、`-n` 為假，於是**存在的
    /// 地點也會被判成不在 layout.json 裡**。照抄那個行為。
    ///
    /// 除了空字串以外的值一律非空（`null`／`false` 早在 jq 的 `// empty` 就變成零
    /// 位元組，其餘型別印出來至少一個字元），所以這裡不需要 Wire 的 writer 就分得出來。
    /// jq 的 runtime error 也是零位元組（訊息在 stderr），與「沒印」同一條路。
    private func isKnown(_ location: String, in config: JSONValue) -> Bool {
        // `try?` 對回 Optional 的函式會壓平，所以這一個 binding 同時吃掉兩種 nil：
        // jq 的 runtime error 與 `// empty`，而 bash 那側兩者都是零位元組。
        guard let described = try? LayoutQuery.locationDescription(location, in: config)
        else { return false }
        if case let .string(text) = described {
            return !text.isEmpty
        }
        return true
    }
}
