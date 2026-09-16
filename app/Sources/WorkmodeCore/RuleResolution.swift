import WorkmodeDomain

/// `resolve_rules`（workmode.sh:870-917）：把設定裡的規則清單解成 `<label>\t<id>`。
///
/// 兩條碰撞規則，兩者現實中都發生過，也是這一支大半篇幅的理由：
///
/// * 一條規則命中多個視窗 → 取第一個，印出全部候選。**誤中不會有別的訊號**：
///   腳本照樣把某個視窗排到定位並 exit 0，只是排錯了那個。
/// * 同一個視窗被多條規則同時命中時 → 先到先得，後面的讓位。錨點曾經用子字串
///   比對而同時命中了 Chat 視窗，兩條規則會把同一個視窗往兩個螢幕拉。
///
/// 三句警告全走 stderr，而兩個呼叫端要不要看到它們不同——壓制屬呼叫端，
/// 見 `SilencedChannelReporter`。
public struct RuleResolution {
    private let yabai: any YabaiClient
    private let reporter: any Reporter

    public init(yabai: any YabaiClient, reporter: any Reporter) {
        self.yabai = yabai
        self.reporter = reporter
    }

    /// - Parameters:
    ///   - rules: 每行五欄 `<label>\t<mt>\t<mv>\t<ft>\t<fv>`（match 與 fallback 的
    ///     類型與值）。欄位切割走 `BashRead.fields`，所以空欄位會讓後面的欄位整批
    ///     往前移一格——那是 `IFS=$'\t' read` 的行為，不是「按 tab 切成五段」。
    ///   - keep: 這次的樹真的引用到的 label，一行一個。
    /// - Returns: `<label>\t<id>` 每行一筆。bash 那側是 `printf` 到 stdout 再被
    ///   `$( )` 收下，所以尾端沒有換行——這裡用 `joined` 而不是逐行補 `\n`。
    ///   找不到視窗的規則不出現在裡面（已發警告事件）。
    public func resolve(rules: String, dump: String, keep: String) -> String {
        // bash 是 `claimed=" "`，前後各補一個空白，比對 `case "$claimed" in *" $c "*)`。
        // 所以那是**整個 token 相符**而不是子字串相符：認領了 `10` 不會讓 `1` 也
        // 算被認領——這正是上面第二條碰撞規則要防的東西的反面。
        var claimed = " "
        var resolved: [String] = []

        for line in BashRead.lines(of: rules) {
            let rule = RuleFields(BashRead.fields(line, count: 5))
            if rule.label.isEmpty {
                continue
            }
            guard Self.keepAccepts(keep, label: rule.label) else { continue }

            // nil 是「整條規則放棄」，見 candidates(for:dump:) 的說明。
            guard let candidates = candidates(for: rule, dump: dump) else { continue }

            let label = rule.label
            let matchType = rule.matchType, matchValue = rule.matchValue
            let count = Self.nonEmptyLineCount(candidates)
            if count > 1 {
                reporter.report(.ruleMatchedMultipleWindows(
                    label: label, count: count,
                    // `printf '%s' "$cands" | tr '\n' ' '`：每個換行變成一個空白。
                    // `$( )` 已經剝掉尾端換行，所以最後一個候選後面**沒有**空白可補。
                    candidates: candidates.split(separator: "\n",
                                                 omittingEmptySubsequences: false).map(String.init)
                ))
            }

            let chosen = Self.firstUnclaimed(in: candidates, claimed: claimed)

            if chosen.isEmpty {
                // 兩種訊息的分野是 `[ -n "$cands" ]`——**cands 有沒有內容**，而不是
                // 「有沒有非空的候選」。全是空行的 cands 會走「都已被認領」那條，
                // 儘管一個都沒被認領。那是現行行為，照抄。
                if candidates.isEmpty {
                    reporter.report(.ruleWindowNotFound(label: label, matchType: matchType,
                                                        matchValue: matchValue))
                } else {
                    reporter.report(.ruleCandidatesAllClaimed(label: label))
                }
                continue
            }

            claimed += chosen + " "
            resolved.append("\(label)\t\(chosen)")
        }

        return resolved.joined(separator: "\n")
    }

    /// 一條規則的五個欄位（bash 是 `read -r label mtype mvalue ftype fvalue`）。
    private struct RuleFields {
        let label: String
        let matchType: String
        let matchValue: String
        let fallbackType: String
        let fallbackValue: String

        init(_ fields: [String]) {
            label = fields[0]
            matchType = fields[1]
            matchValue = fields[2]
            fallbackType = fields[3]
            fallbackValue = fields[4]
        }
    }

    /// 主比對，命不中再試 fallback。
    ///
    /// 回 nil 是 `cands=$(find_windows …) || continue`：**整條規則放棄**。失敗是
    /// rc=2（未知類型或 pattern 編不起來），而那代表設定寫錯，不是「這次沒開這個
    /// 視窗」——所以連 fallback 都不試。
    ///
    /// fallback 那側相反，是 `|| true`：它本來就是「試一下，沒有就算了」，失敗不該
    /// 讓那條規則連「找不到視窗」的警告都印不出來，所以那裡回空字串而不是 nil。
    private func candidates(for rule: RuleFields, dump: String) -> String? {
        var found: String
        if rule.matchType == "app" {
            found = appCandidates(rule.matchValue)
        } else {
            do {
                found = try Self.joined(WindowMatching.findWindows(
                    kind: rule.matchType, value: rule.matchValue, dump: dump
                ))
            } catch {
                return nil
            }
        }
        guard found.isEmpty, rule.fallbackType != "-" else { return found }

        if rule.fallbackType == "app" {
            return appCandidates(rule.fallbackValue)
        }
        do {
            return try Self.joined(WindowMatching.findWindows(
                kind: rule.fallbackType, value: rule.fallbackValue, dump: dump
            ))
        } catch {
            return ""
        }
    }

    /// 第一個還沒被別條規則認領的候選；一個都沒有就回空字串。
    ///
    /// `claimed` 前後各補一個空白，比對的是**整個 token**而不是子字串：認領了 `10`
    /// 不會讓 `1` 也算被認領。
    private static func firstUnclaimed(in candidates: String, claimed: String) -> String {
        for line in BashRead.lines(of: candidates) {
            let candidate = BashRead.singleField(line)
            if candidate.isEmpty {
                continue
            }
            if claimed.contains(" \(candidate) ") {
                continue
            }
            return candidate
        }
        return ""
    }

    /// `printf '%s\n' "$keep" | LC_ALL=C grep -qxF -- "$label"`。
    ///
    /// `-qxF` 是**整行、固定字串**比對。不用 `case` 的 glob 是因為 label 是使用者
    /// 自訂字串，含 `*` `?` `[` 會被當萬用字元而誤判（workmode.sh:869 的註解）。
    ///
    /// 比 UTF-8 位元組而不是 Swift 的 `String ==`：後者會做正規化，而 grep 不會，
    /// 所以 NFC 與 NFD 的同一個 label 在 bash 那側不相等。
    private static func keepAccepts(_ keep: String, label: String) -> Bool {
        // `printf '%s\n'` 補一個換行，所以空的 keep 是**一行空字串**而不是零行。
        // label 為空的規則在上面已經跳掉了，所以那一行配不上任何還活著的 label。
        let target = Array(label.utf8)
        return keep.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { Array($0.utf8) == target }
    }

    /// `n=$(printf '%s' "$cands" | grep -c . || true)`。
    ///
    /// `.` 要求至少一個字元，所以空行不算。`printf '%s'` 不補換行，但 grep 照樣把
    /// 最後那段未收尾的內容算成一行（實測 `printf '7' | grep -c .` 是 1）。
    /// 空輸入時 `grep -c .` 印 0 而 rc=1，`|| true` 就是為了那個 rc。
    private static func nonEmptyLineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count { !$0.isEmpty }
    }

    /// `find_windows` 的輸出被 `$( )` 收下的樣子：每個 id 一行、尾端換行被剝掉。
    ///
    /// nil 是 `app` 那條（find_windows 對它一個位元組都不印）。這兩個呼叫點的
    /// 類型都已經確定不是 `app`，所以 nil 走不到——但這裡不 assert：走不到的
    /// 分支要嘛餵得到輸入，要嘛收斂成與 bash 相同的結果，而空清單正是 bash
    /// 在那種情況下會拿到的東西。
    private static func joined(_ ids: [String]?) -> String {
        (ids ?? []).joined(separator: "\n")
    }

    /// `yabai -m query --windows | jq -r --arg a "$mv" '.[] | select(.app == $a) | .id'`。
    ///
    /// 這條管線**沒有** `2>/dev/null` 也沒有 `|| continue`：query 失敗時 jq 吃到空
    /// 輸入（rc=0、零輸出），於是候選是空字串，而那與「這個 app 沒開視窗」在 bash
    /// 完全同一條路。
    private func appCandidates(_ app: String) -> String {
        guard let json = try? yabai.query(.windows) else { return "" }

        // `.[]` 對陣列逐一、對物件走它的**值**、其餘型別是 runtime error（零輸出）。
        let elements: [JSONValue]
        switch json {
        case let .array(items): elements = items
        case let .object(members): elements = members.map(\.value)
        default: return ""
        }

        // jq 是**串流**：中途某一筆出錯時，前面已經印出去的行照樣被 `$( )` 收下
        // （實測 `[{...},true]` 印了第一筆才報錯）。所以這裡是「印到出錯為止」。
        var out: [String] = []
        for element in elements {
            switch element {
            case .null:
                // `null.app` 是 null 不是錯，而 null 不等於任何字串 → 不選中、
                // 也不中止。所以 null 元素是**跳過**而不是終止串流（實測過）。
                continue
            case .object:
                // `.app == $a`：`$a` 恆為字串（`--arg`），所以只有同一個字串會相等。
                // 逐位元組比而不是 `String ==`：jq 比的是碼位，不做正規化。
                guard case let .string(name) = element["app"] ?? .null,
                      Array(name.utf8) == Array(app.utf8) else { continue }
                out.append(JQPrint.raw(element["id"] ?? .null))
            default:
                return out.joined(separator: "\n")
            }
        }
        return out.joined(separator: "\n")
    }
}

/// `report_rules`（workmode.sh:664-676）：印每條規則解到的視窗當下的位置。
///
/// 帶 y 的理由在 663 的註解：有了上下分之後只看 x 判斷不出形狀。
public struct RulePositionReport {
    private let yabai: any YabaiClient
    private let reporter: any Reporter

    public init(yabai: any YabaiClient, reporter: any Reporter) {
        self.yabai = yabai
        self.reporter = reporter
    }

    /// - Parameter rules: `RuleResolution.resolve` 的輸出：每行 `<label>\t<id>`。
    public func report(rules: String) {
        // `[ -z "$rules" ]` 走的是 `echo` 加 `return 0`，**迴圈完全不跑**。
        if rules.isEmpty {
            reporter.report(.noRulesResolved)
            return
        }
        for line in BashRead.lines(of: rules) {
            let (label, id) = BashRead.labelAndRest(line)
            if id.isEmpty {
                continue
            }
            guard let event = position(of: id, label: label) else { continue }
            reporter.report(event)
        }
    }

    /// 那一行 jq 插值的結果，nil ＝ jq 一個位元組都沒印。
    ///
    /// nil 有兩個來源，bash 那側都是靜默的而且都是正確行為：
    ///   * query 失敗（`2>/dev/null` ＋ jq 吃空輸入，rc=0 零輸出）；
    ///   * 值不是物件，或 `.frame.<欄位>` 不是數字（含 `.frame` 整個缺席）——
    ///     `null | floor` 是 runtime error，jq 中止、**整行都不出現**，即使
    ///     `.id` 好好的（實測 rc=5、stdout 全空）。
    private func position(of id: String, label: String) -> WorkmodeEvent? {
        guard let window = try? yabai.query(.window(id)) else { return nil }
        // 非物件（陣列、字串…）在 `.id` 那次索引就是 runtime error。`null` 索引出
        // null 不報錯，但它的四個 floor 必定報錯，所以兩者收斂成同一個 nil。
        guard case .object = window else { return nil }
        guard let width = Measurements.flooredFrameField(window, "w"),
              let height = Measurements.flooredFrameField(window, "h"),
              let originX = Measurements.flooredFrameField(window, "x"),
              let originY = Measurements.flooredFrameField(window, "y") else { return nil }
        // `\(.id)` 等三個走插值：欄位缺席時是字面的 `null`（不是空字串），
        // 而沒被運算過的數字逐字保留（`2.50` 不變 `2.5`）。
        return .ruleWindowPositionReported(
            label: label,
            id: JQPrint.interpolate(window["id"] ?? .null),
            display: JQPrint.interpolate(window["display"] ?? .null),
            space: JQPrint.interpolate(window["space"] ?? .null),
            frame: ReportedFrame(width: width, height: height,
                                 originX: originX, originY: originY)
        )
    }
}
