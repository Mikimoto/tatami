import WorkmodeDomain

/// `switch_interactive`（workmode.sh:1013-1057）。兩段式選單：先地點、後 profile。
///
/// **只從終端機跑。** 實測（2026-08-08）在沒有 controlling tty 的情境下跑互動式 fzf
/// 不是失敗而是**無聲卡住**（`timeout 3` 兩分鐘都沒收掉它，最後要 pkill），從快捷鍵
/// 按下去會變成畫面沒反應、腳本在背景卡死。所以它不進 skhdrc。
///
/// 這一支不寫任何東西：它只把兩次選擇組成 `switch_setting` 的參數字串。bash 也是
/// 這樣（1056 行呼叫回 `switch_setting`），所以驗證只要看「組出什麼字串」。
struct SwitchInteractive {
    private let picker: any Picker
    private let active: ActiveLocation
    private let measurements: WindowMeasurements
    private let renderRaw: (JSONValue) -> String
    private let reporter: any Reporter

    init(picker: any Picker, active: ActiveLocation, measurements: WindowMeasurements,
         renderRaw: @escaping (JSONValue) -> String, reporter: any Reporter)
    {
        self.picker = picker
        self.active = active
        self.measurements = measurements
        self.renderRaw = renderRaw
        self.reporter = reporter
    }

    /// 回 nil ＝ bash 的 `return 1`（沒有 fzf，或使用者取消了任一段）。
    /// 回字串 ＝ 要交給 `switch_setting` 的那個參數。
    func pick(state: String, config: JSONValue) -> String? {
        guard picker.isAvailable else {
            reporter.report(.pickerMissing)
            reporter.report(.pickerFallbackLocations(
                available: (try? LayoutQuery.locationNames(in: config)) ?? ""
            ))
            return nil
        }

        // `|| cur_line=""`：認不出地點不是錯，只是沒有「←目前」那個標記。
        let currentLocation = active.resolve(state: state, config: config)?.location ?? ""

        guard let pickedLocationLine = (try? picker.pick(locationMenu(config: config,
                                                                      current: currentLocation),
                                                         prompt: "地點 > ")) ?? nil
        else { return nil }
        let pickedLocation = firstField(of: pickedLocationLine)

        // 選 auto 之後 profile 要記在**偵測出來**的地點上，不是記在 "auto" 上。
        let target: String
        if pickedLocation == reservedAuto {
            guard let detected = measurements.detectLocation(in: config) else {
                // bash 在這裡直接 `switch_setting auto; return $?`——不問 profile。
                reporter.report(.pickerLocationUnresolvedAfterAuto)
                return reservedAuto
            }
            target = detected
        } else {
            target = pickedLocation
        }

        let remembered = StateFile.value(forKey: "profile." + target, in: state)
        guard let pickedProfileLine = (try? picker.pick(profileMenu(config: config,
                                                                    location: target,
                                                                    remembered: remembered),
                                                        prompt: "profile（\(target)） > ")) ?? nil
        else { return nil }

        return pickedLocation + "/" + firstField(of: pickedProfileLine)
    }

    /// `to_entries[] | select(.key != "windows") | [.key, .value.desc + …] | @tsv`
    /// 後面接一行字面的 `auto`。
    ///
    /// jq 的 `+` 對 null 是恆等（`null + "x"` 是 `"x"`、`null + ""` 是 `""`），所以
    /// 沒有 desc 的地點在選單裡是一個空欄位而不是 `null`。desc 是數字之類的型別則是
    /// runtime error，整個串流中止＝那一行之後一行都不印。
    private func locationMenu(config: JSONValue, current: String) -> [String] {
        var lines: [String] = []
        if case let .object(members) = config {
            for member in members where member.key != LayoutQuery.reservedKey {
                let suffix = member.key == current ? "  ←目前" : ""
                // `.value.desc`：非物件是 runtime error，整個串流中止（`break`
                // 而不是 `continue`——後面的地點連印都沒印出來）。
                guard case .object = member.value else { break }
                guard let desc = concatenate(member.value["desc"], suffix) else { break }
                lines.append(tsv([member.key, desc]))
            }
        }
        lines.append(tsv([reservedAuto, "自動偵測（清除地點覆寫）"]))
        return lines
    }

    /// `(.[$l].profiles // {}) | to_entries[] | [.key, (if … then "←記住的" else "" end)] | @tsv`
    private func profileMenu(config: JSONValue, location: String,
                             remembered: String) -> [String]
    {
        var lines: [String] = []
        // `// {}`：不存在、null、false 三種都退到空物件，於是選單只剩 `auto` 那行。
        let profiles = (config[location]?["profiles"]).flatMap { isTruthy($0) ? $0 : nil }
        if case let .object(members)? = profiles {
            for member in members {
                lines.append(tsv([member.key, member.key == remembered ? "←記住的" : ""]))
            }
        }
        lines.append(tsv([reservedAuto, "清除記憶，改用 default"]))
        return lines
    }

    /// jq 的真值：只有 `null` 與 `false` 是假，`0` 與 `""` 都是真。
    private func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case let .bool(flag): flag
        default: true
        }
    }

    /// jq 的 `+`：null 是恆等，兩個字串相接，其餘型別是 runtime error（回 nil）。
    private func concatenate(_ value: JSONValue?, _ suffix: String) -> String? {
        switch value {
        case .none, .some(.null): suffix
        case let .some(.string(text)): text + suffix
        default: nil
        }
    }

    private func tsv(_ fields: [String]) -> String {
        fields.map(JQPrint.tsvEscape).joined(separator: "\t")
    }

    /// `cut -f1`：第一個 tab 之前的全部。沒有 tab 就是整行。
    private func firstField(of line: String) -> String {
        guard let tab = line.firstIndex(of: "\t") else { return line }
        return String(line[line.startIndex ..< tab])
    }
}
