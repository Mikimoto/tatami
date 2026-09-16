/// 「量了才能講」那四支量測函式的**純邏輯**那一半。
///
/// `win_frame_x`／`chat_vs_sibling_width`／`observed_axis`／`in_order`
/// （workmode.sh:704-758）每一支都是「問 yabai 一次 ＋ 一段判斷」。問的那半在
/// `WorkmodeCore.WindowMeasurements`，判斷這半在這裡——這些函式存在的理由是判斷
/// 本身（`observed_axis` 的重點是那個重疊判斷，不是 query），而判斷這半沒有外部
/// 世界，測得起來。
///
/// 全部的錯誤路徑一律收斂成 `nil`＝**空字串**。bash 那側就是這樣：jq 的 runtime
/// error（rc=5）與 jq 吃到空輸入（rc=0）都只讓命令替換拿到零位元組，而
/// `set -uo pipefail` 沒有 `-e`，所以失敗的命令不會中止函式。兩者在 bash 裡不可區分，
/// 這一層跟著不區分。
public enum Measurements {
    // MARK: - win_frame_x 與 chat 自己的寬度（workmode.sh:704-706、713）

    /// `.frame.<field> | floor`。
    ///
    /// 回 `String?` 而不是 `Int?`：呼叫端拿到的就是 jq 印出來的那串文字，而 floor
    /// 之後的數字**不再逐字保留**（走 `JQNumber` 的 dtoa 模型，`1e999 | floor` 印的是
    /// `1.7976931348623157e+308`）。先轉成 Int 會把那些形狀丟掉，而 `observed_axis`
    /// 接下來拿它進 bash 算術——非整數形狀在那裡是一個看得見的行為差異（見 `axis`）。
    ///
    /// nil 的三個來源在 bash 都是空字串：`.frame` 不存在（`null | floor` 是 runtime
    /// error rc=5，實測 stdout 全空）、`.frame.<field>` 不是數字、以及 query 失敗
    /// （jq 吃空輸入 rc=0 零輸出）。最後一個由 Core 那半處理。
    public static func flooredFrameField(_ window: JSONValue, _ field: String) -> String? {
        guard let frame = member(window, "frame"),
              let value = member(frame, field),
              case let .number(literal) = value else { return nil }
        return SpaceRects.flooredText(literal)
    }

    // MARK: - chat_vs_sibling_width 的 sibling 那半（workmode.sh:714-716）

    /// `[.[] | select(.id != $c and 三個旗標) | .frame.w] | max // empty | floor`。
    ///
    /// - Parameter chat: bash 是 `--argjson c "$chat"`，所以 `.id != $c` 是**數值**
    ///   比較而不是字串比較（`.id` 5 配得上 `$c` 5.0）。Core 那半負責把視窗 id
    ///   包成 `.number`。
    ///
    /// 空清單回 nil：`max` 給 null、`null // empty` 產生 empty，於是 **`floor` 根本
    /// 沒有執行**（實測 rc=0、零輸出，不是 runtime error）。所以「該 space 只有 chat
    /// 自己」與「query 失敗」在 bash 是同一個空字串，`apply_ratio` 的 `[ -n "$ow" ]`
    /// 就是為此存在。
    public static func widestSibling(windows: JSONValue, excluding chat: JSONValue) -> String? {
        guard let elements = iterate(windows) else { return nil }

        var best: JSONValue?
        for element in elements {
            // jq 的 `and` 短路，但 `.id` 那次索引照樣發生：元素不是物件就是 runtime
            // error，整個串流中止（→ nil），不是「跳過這一筆」。
            guard let identifier = member(element, "id") else { return nil }
            if jqEquals(identifier, chat) {
                continue
            }
            guard let managed = ManagedWindow.matches(element) else { return nil }
            guard managed else { continue }
            guard let frame = member(element, "frame"),
                  let width = member(frame, "w") else { return nil }
            // 標準庫的元組 `>` 是字典序，正好就是「先比分層、同層再比數值」。
            if best == nil || rank(width) > rank(best!) {
                best = width
            }
        }

        // `// empty`：假值（null 與 false）才退讓。空清單的 `max` 是 null，所以
        // 兩件事共用這一條路。
        guard let width = best, isTruthy(width) else { return nil }
        // 這裡的 `floor` 只在 max 是數字時成功。max 挑出字串或容器時（jq 的全序裡
        // 它們排在數字之後）`floor` 是 runtime error，同樣收斂成空字串——所以
        // `rank` 不需要真的實作 jq 對字串與容器的比較，兩條路的輸出相同。
        guard case let .number(literal) = width else { return nil }
        return SpaceRects.flooredText(literal)
    }

    // MARK: - observed_axis 的重疊判斷（workmode.sh:736-750）

    /// vertical 是左右分、horizontal 是上下分（與 yabai 的 split_type、與樹裡的
    /// `axis` 同義，見 LayoutTree）。
    public static let verticalAxis = "vertical"
    public static let horizontalAxis = "horizontal"

    /// 兩個視窗當下是左右分還是上下分：**x 範圍有沒有重疊**，重疊代表上下疊著。
    ///
    /// 不看 `split-type` 欄位——那描述的是視窗自己的分割模式而非它與 sibling 的關係，
    /// 而且 `--warp` 之後不保證立刻更新。frame 是實際畫面。
    ///
    /// bash 是 `[ "$((ax + aw))" -gt "$bx" ] && [ "$((bx + bw))" -gt "$ax" ]`，
    /// 三個非顯而易見的行為都在這裡複製（都實測過）：
    ///   - 空字串在 `$(( ))` 裡是 0，但 `[ "0" -gt "" ]` 是 `integer expected`（rc=2）
    ///     ＝條件為假 → **vertical**。所以任何一邊量不到都會判成 vertical。
    ///   - 第一個 `[` 為假時 `&&` 短路，`$((bx + bw))` 根本沒有求值。
    ///   - 算術**本身**出錯（jq 印出 `1.5e+300` 這種非整數形狀時）不是「條件為假」：
    ///     實測整個 `if` 複合命令被中止、h 與 v 都沒印、rc=1。那對應這裡的 `nil`
    ///     ——零輸出且非零 rc，與 `|| return 1` 走同一個管道。
    public static func axis(firstX: String?, firstWidth: String?,
                            secondX: String?, secondWidth: String?) -> String?
    {
        guard let leftEdge = arithmetic(firstX, firstWidth) else { return nil }
        guard let secondLeft = integer(secondX), leftEdge > secondLeft else { return verticalAxis }
        guard let rightEdge = arithmetic(secondX, secondWidth) else { return nil }
        guard let firstLeft = integer(firstX), rightEdge > firstLeft else { return verticalAxis }
        return horizontalAxis
    }

    // MARK: - in_order（workmode.sh:752-758）

    /// vertical 看 `.frame.x`、其餘看 `.frame.y`。
    ///
    /// 看起來反直覺，其實是命名的緣故：vertical 指的是**分割線是垂直的**（左右分），
    /// 而左右分的先後由 x 決定。判斷是 `[ "$axis" = "vertical" ]` 這個**字面字串**
    /// 比較，axis 來自樹裡的值，不認得的字一律落到 y。
    public static func orderField(forAxis axis: String) -> String {
        axis == verticalAxis ? "x" : "y"
    }

    /// `[ -n "$av" ] && [ -n "$bv" ] && [ "$av" -lt "$bv" ]`。
    ///
    /// 任一邊量不到就是 false（＝「順序不對」，呼叫端會去 `--swap`，然後再量一次）。
    /// 非整數形狀走的是 `[` 的 `integer expression expected`（rc=2）＝false，
    /// 而**不是** `axis` 那條算術中止的路——同一種壞值在兩支函式裡的後果不同。
    public static func isInOrder(_ firstValue: String?, _ secondValue: String?) -> Bool {
        guard let first = integer(firstValue), let second = integer(secondValue) else { return false }
        return first < second
    }

    // MARK: - bash 的整數

    /// `$((a + b))`。空字串是 0（未設定的變數在算術裡就是 0）。
    ///
    /// 只認「可選正負號 ＋ 十進位數字」：jq 的 floor 只會印出這個形狀或指數形狀，
    /// 而指數形狀在 bash 算術裡是語法錯誤。溢位也回 nil（bash 會靜默繞回，但那要
    /// 先有一個超過 Int64 的視窗座標）。
    private static func arithmetic(_ lhs: String?, _ rhs: String?) -> Int? {
        guard let left = arithmeticOperand(lhs), let right = arithmeticOperand(rhs) else { return nil }
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? nil : sum
    }

    private static func arithmeticOperand(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return 0 }
        return decimal(text)
    }

    /// `[ "$x" -gt "$y" ]` 的一邊。空字串與非整數都是 `integer expression expected`。
    private static func integer(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        return decimal(text)
    }

    private static func decimal(_ text: String) -> Int? {
        var digits = Substring(text)
        if digits.first == "-" || digits.first == "+" {
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    // MARK: - jq 的零件

    /// jq 全序裡的分層：null < false < true < 數字 < 字串 < 陣列 < 物件。
    /// 數字之外只需要分層——見 `widestSibling` 裡的說明。
    private static func rank(_ value: JSONValue) -> (Int, Double) {
        switch value {
        case .null: (0, 0)
        case let .bool(flag): (flag ? 2 : 1, 0)
        case let .number(literal): (3, Double(literal) ?? 0)
        case .string: (4, 0)
        case .array: (5, 0)
        case .object: (6, 0)
        }
    }

    private static func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case let .bool(flag): flag
        default: true
        }
    }

    /// `.[]`。物件走的是它的**值**；純量報錯。
    private static func iterate(_ value: JSONValue) -> [JSONValue]? {
        switch value {
        case let .array(items): items
        case let .object(members): members.map(\.value)
        default: nil
        }
    }

    /// `.[key]`。null 索引出 null（不是錯），物件取成員（沒有就 null），
    /// 其餘型別報錯——**陣列也不行**。
    private static func member(_ value: JSONValue, _ key: String) -> JSONValue? {
        switch value {
        case .null: .null
        case .object: value[key] ?? .null
        default: nil
        }
    }
}
