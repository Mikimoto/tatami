import WorkmodeDomain

// `resolve_rules`（workmode.sh:870-917）與 `report_rules`（664-676）。
// 兩支合成一組：它們是同一件事的兩面（把規則對到視窗，再報告對到的位置），
// 而且只有這一組會被 SilencedChannelReporter 整批壓掉。

/// 規則比對與位置回報。
public enum RuleEvent: Equatable, Sendable {
    /// workmode.sh:667。`rules` 是空字串。
    ///
    /// 這一句是 `echo` 而不是 `printf`，所以 renderer 的逐位元組比對不能沿用
    /// 那個「挖出 printf 的格式字串」的 harness——`echo` 會自己補換行，而它印的
    /// 是原文不是格式字串。
    case noRulesResolved

    /// workmode.sh:674。一條規則解到的視窗當下的位置。
    ///
    /// 八個欄位全是 `String`，因為**這一行不是 `printf` 印的、是 jq 的字串插值印的**：
    /// 沒被算術運算過的數字逐字保留（jq 1.8 把 `2.50` 印成 `2.50`，`1e3` 印成 `1E+3`），
    /// 欄位缺席時插值成字面的 `null`，而四個 `floor` 過的走 `JQNumber` 的 dtoa 模型
    /// （`1e999 | floor` 印成 `1.7976931348623157e+308`）。轉成 Int 會把這些形狀
    /// 全部丟掉，而它們是實際會出現在終端機上的位元組。
    ///
    /// 帶 y 的理由在 workmode.sh:663 的註解：有了上下分之後只看 x 判斷不出形狀。
    ///
    /// 「這一行沒有發生」不用空字串或 0 表示，而是**根本不發這個事件**。兩條路都
    /// 走得到而且都是正確行為：query 失敗（`2>/dev/null` ＋ jq 吃空輸入，rc=0
    /// 零輸出）、以及 `.frame` 缺席（`null | floor` 是 runtime error，jq 中止、
    /// stdout 全空，即使 `.id` 好好的）。
    case ruleWindowPositionReported(label: String, id: String, display: String,
                                    space: String, frame: ReportedFrame)

    /// workmode.sh:894。一條規則命中多個視窗 → 取第一個未被認領的，並印出全部候選。
    ///
    /// 這句話存在的理由：誤中**不會有別的訊號**——腳本照樣把某個視窗排到定位並
    /// exit 0，只是排錯了那個。
    ///
    /// `count` 與 `candidates.count` 可以不同，兩個值的來源不同：前者是
    /// `grep -c .`（只數非空行），後者是 `tr '\n' ' '` 的每一段（空行照樣佔一格）。
    case ruleMatchedMultipleWindows(label: String, count: Int, candidates: [String])

    /// workmode.sh:907。候選都被前面的規則認領掉了 → 先到先得，這條讓位。
    ///
    /// 這句話存在的理由：錨點曾經用子字串比對而同時命中了 Chat 視窗，
    /// 兩條規則會把同一個視窗往兩個螢幕拉。
    case ruleCandidatesAllClaimed(label: String)

    /// workmode.sh:909。連候選都沒有。帶 match 的類型與值，才看得出是哪一條沒中。
    case ruleWindowNotFound(label: String, matchType: String, matchValue: String)

    public var channel: OutputChannel {
        switch self {
        case .noRulesResolved, .ruleWindowPositionReported:
            .stdout
        case .ruleCandidatesAllClaimed, .ruleMatchedMultipleWindows, .ruleWindowNotFound:
            .stderr
        }
    }
}
