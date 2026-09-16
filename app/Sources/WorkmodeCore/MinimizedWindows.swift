/// `restore_minimized`（workmode.sh:643-661）。
///
/// 為什麼要還原而不是跳過：最小化的視窗不在 bsp 樹裡（`--warp` 回「not managed」），
/// 而 query 回的 frame 停在最小化前的值，量什麼都是舊的。使用者對「app 沒在跑」選的
/// 是順便開起來，同一個取捨延伸到這裡就是還原它。
///
/// 這一支整段的存在理由是那個輪詢：`--deminimize` 之後**不能立刻查** `is-minimized`。
/// 還原是 macOS 的動畫，實測這台機器上固定要 ~600ms 才翻成 false（三次量測都是
/// 第 6 次輪詢），立刻查必定讀到 true，於是每次成功的還原都會被報成失敗。
public struct MinimizedWindows {
    /// workmode.sh:642 的 `RESTORE_POLLS=20`。
    public static let restorePolls = 20
    /// workmode.sh:653 的 `sleep 0.1`。
    public static let pollInterval = 0.1

    private let yabai: any YabaiClient
    private let clock: any Clock
    private let reporter: any Reporter

    public init(yabai: any YabaiClient, clock: any Clock, reporter: any Reporter) {
        self.yabai = yabai
        self.clock = clock
        self.reporter = reporter
    }

    /// - Parameter map: `resolve_rules` 的輸出：每行 `<label>\t<id>`。
    ///   id 為空的行跳過（`[ -z "${id}" ] && continue`），空字串也算一行——見 `BashRead`。
    public func restore(map: String) {
        for line in BashRead.lines(of: map) {
            let (label, id) = BashRead.labelAndRest(line)
            if id.isEmpty {
                continue
            }

            // `[ … = "true" ] || continue`：只有**字串 `"true"`** 才動它。
            // false、null（欄位缺席）、空字串（query 失敗）一律跳過，而且三者
            // 在這裡走的是同一條路——bash 沒有分開處理。
            guard isMinimized(id) else { continue }

            // exit code 被 `2>/dev/null` 之外的地方忽略：bash 這行沒有 `||`，
            // 失敗就讓接下來的輪詢去發現（於是報「還原失敗」）。
            try? yabai.run(.deminimize(window: id))

            // 迴圈的形狀很重要：**先查、再遞增、再睡**。所以 `i == 0` 那次查詢是
            // 立刻發生的（還沒睡過），而它必定讀到 true——那正是上面註解說的坑。
            // 立刻就 false 時 break，`i` 是 0，一次都沒睡。
            var polls = 0
            while polls < Self.restorePolls {
                if isMinimizedFlag(id) == "false" {
                    break
                }
                polls += 1
                clock.sleep(seconds: Self.pollInterval)
            }

            // 第 20 次查詢仍失敗時 `i` 變成 20 並**再睡一次**才離開迴圈（睡 20 次），
            // 這是 bash 那個 while 的收尾行為，不是多睡一次的 bug。
            if polls < Self.restorePolls {
                reporter.report(.minimizedWindowRestored(label: label))
            } else {
                reporter.report(.minimizedWindowRestoreFailed(label: label))
            }
        }
    }

    private func isMinimized(_ id: String) -> Bool {
        isMinimizedFlag(id) == "true"
    }

    /// `yabai -m query --windows --window <id> 2>/dev/null | jq -r '."is-minimized"'`。
    /// 回的是那一行文字，不是 Bool：呼叫端比對的是字串，而 `null`／`""` 與 `"false"`
    /// 在兩處比對（`= "true"` 與 `= "false"`）的答案不同。
    private func isMinimizedFlag(_ id: String) -> String {
        JQPipeline.member(try? yabai.query(.window(id)), "is-minimized")
    }
}
