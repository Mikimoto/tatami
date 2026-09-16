import WorkmodeDomain

/// 五支「量測型」函式的 **port 那一半**。
///
/// bash 對應：`win_frame_x`（704-706）、`chat_vs_sibling_width`（709-719）、
/// `observed_axis`（736-750）、`in_order`（752-758）、`detect_location`（553-557）。
///
/// 這一層只做三件事：問哪一個 query、問幾次、問的順序。判斷全在
/// `WorkmodeDomain.Measurements` 與 `Displays`——那半才是這些函式存在的理由。
/// 順序不是裝飾：`apply_ratio` 的整段編排是「設 ratio → 量自己 → 量 sibling →
/// 發現比較窄就翻過來 → 再量一次」，量測搬到 ratio 之前就完全失效，而
/// `FakeYabai.allArgv` 是唯一能抓到那個錯誤的東西。
public struct WindowMeasurements {
    private let yabai: any YabaiClient

    public init(yabai: any YabaiClient) {
        self.yabai = yabai
    }

    /// `chat_vs_sibling_width` 的兩個模式（bash 是 `[ "$which" = "chat" ]`，
    /// 不認得的字一律落到 sibling 那條）。
    public enum WidthSubject: Equatable, Sendable {
        /// chat 自己的 `.frame.w`。
        case chat
        /// 同 space 其他受管理視窗中最寬的那個。
        case widestSibling
    }

    // MARK: - win_frame_x（workmode.sh:704-706）

    /// 這支在 bash 裡**沒有任何呼叫端**（`grep win_frame_x` 只有定義本身）。
    /// 照樣移植：移植的規則是行為原封不動，而「順手刪掉看起來沒人用的東西」在
    /// 這個 repo 已經有教訓。
    ///
    /// query 失敗回 nil：bash 是 `2>/dev/null` 之後 jq 吃到空輸入（rc=0、零輸出），
    /// 拿到的是空字串（實測 `--window 999999` 是 yabai rc=1 ＋ stdout 全空）。
    public func frameX(window: String) -> String? {
        flooredFrameField(window: window, field: "x")
    }

    // MARK: - chat_vs_sibling_width（workmode.sh:709-719）

    public func width(chat: String, space: String, of subject: WidthSubject) -> String? {
        switch subject {
        case .chat:
            return flooredFrameField(window: chat, field: "w")
        case .widestSibling:
            guard let windows = try? yabai.query(.windowsOnSpace(space)) else { return nil }
            // `--argjson c "$chat"`：值進 jq 是 JSON 而不是字串，所以 `.id != $c`
            // 是數值比較。chat 不是合法的 JSON 數字時 jq 連跑都不跑（argjson 解析
            // 失敗，rc=2、零輸出）——但 yabai 那支已經跑過了，所以順序是先 query
            // 再判斷，不能提前 return。視窗 id 一律是整數，只認整數。
            guard Int(chat) != nil else { return nil }
            return Measurements.widestSibling(windows: windows, excluding: .number(chat))
        }
    }

    // MARK: - observed_axis（workmode.sh:736-750）

    /// 回 nil ＝ bash 的 `|| return 1`：**任一次 query 失敗就整支放棄**（這兩處是
    /// 少數看 exit code 的地方）。呼叫端是 `[ "$(observed_axis …)" != "$axis" ]`，
    /// 空字串永遠不等於樹裡的 axis，所以 nil 會讓它去 `--toggle split`。
    ///
    /// 只問兩次：bash 把兩份 JSON 存進變數再用四次 jq 解，量測的是**同一個瞬間**。
    /// 拆成四次 query 會在兩次量測之間留下一個視窗可以移動的空隙。
    public func observedAxis(_ first: String, _ second: String) -> String? {
        guard let firstJSON = try? yabai.query(.window(first)) else { return nil }
        guard let secondJSON = try? yabai.query(.window(second)) else { return nil }
        return Measurements.axis(firstX: Measurements.flooredFrameField(firstJSON, "x"),
                                 firstWidth: Measurements.flooredFrameField(firstJSON, "w"),
                                 secondX: Measurements.flooredFrameField(secondJSON, "x"),
                                 secondWidth: Measurements.flooredFrameField(secondJSON, "w"))
    }

    // MARK: - in_order（workmode.sh:752-758）

    /// 與 `observedAxis` 不同：這裡**兩次 query 都一定會發生**，失敗也只是拿到
    /// 空字串（bash 沒有 `|| return`，`-n` 那道檢查在後面）。順序是 a 再 b。
    public func isInOrder(_ first: String, _ second: String, axis: String) -> Bool {
        let field = Measurements.orderField(forAxis: axis)
        let firstValue = flooredFrameField(window: first, field: field)
        let secondValue = flooredFrameField(window: second, field: field)
        return Measurements.isInOrder(firstValue, secondValue)
    }

    // MARK: - detect_location（workmode.sh:553-557）

    /// 問 yabai 當下接了哪些螢幕，交給 `Displays.matchLocation`。
    ///
    /// query 失敗時 connected 是空字串，而那**不一定是沒命中**：`matchLocation` 的
    /// pattern 在 `displays.main` 為空時收斂成兩個相連的空白，而空的 connected
    /// 組出來的草堆剛好就是兩個空白，於是那個地點命中。那是 bash 現行行為，照抄。
    public func detectLocation(in config: JSONValue) -> String? {
        let connected = (try? yabai.query(.displays))
            .map { Displays.connectedUUIDs(in: $0) } ?? ""
        return Displays.matchLocation(connected: connected, in: config)
    }

    private func flooredFrameField(window: String, field: String) -> String? {
        guard let json = try? yabai.query(.window(window)) else { return nil }
        return Measurements.flooredFrameField(json, field)
    }
}
