/// yabai 說現在開著的一個視窗。三個欄位就是挑選器要的全部。
///
/// **與 `WorkmodeDomain.Display` 分開**，理由同一條：那些型別是「yabai 說了什麼」，
/// 而這裡還要接上 Safari 說了什麼。
public struct LiveWindow: Equatable, Sendable {
    public let id: String
    public let app: String
    /// yabai 的 `title` 欄位。**只用來顯示**——沒有任何 match kind 讀它
    /// （`title-regex` 配的是 Safari 的分頁標題）。
    public let title: String

    public init(id: String, app: String, title: String) {
        self.id = id
        self.app = app
        self.title = title
    }
}

/// 挑選器上的一個視窗。
public struct WindowChoice: Equatable, Sendable {
    public let id: String
    public let app: String
    public let title: String
    /// 這個視窗**當前分頁**的網址。dump 裡沒有這個 id 就是 nil，而那正是
    /// 「只能用 app 條件」的判準（下一個任務的 `conditions`）。
    public let tabURL: String?
    public let tabTitle: String?

    public init(id: String, app: String, title: String,
                tabURL: String?, tabTitle: String?)
    {
        self.id = id
        self.app = app
        self.title = title
        self.tabURL = tabURL
        self.tabTitle = tabTitle
    }

    /// 把 yabai 那份與 Safari 的分頁 dump 接起來。
    ///
    /// **以 yabai 那份為準**（與 `DisplayChoice.merge` 同一條）：dump 有而 yabai
    /// 沒列的視窗不出現——規則配的是 yabai 管理的視窗，列一個它不管的只會讓使用者
    /// 建出一條永遠不生效的規則。順序也照 yabai。
    ///
    /// **這裡的 dump 解析只用來顯示與產生初始值。** `SafariClient.tabDump()` 的 doc
    /// 說不可以先切成結構，那條是針對**比對路徑**——比對仍然由 `WindowMatching` 做，
    /// 它走位元組語意（`$2 == n` 是 strnum 比較、`.` 吃一個位元組）。這裡撿出來的
    /// 字串之後會被寫進 `layout.json`，再由那支比對。
    public static func merge(_ windows: [LiveWindow], dump: String) -> [WindowChoice] {
        let tabs = currentTabs(in: dump)
        return windows.map { window in
            let tab = tabs[normalized(window.id)]
            return WindowChoice(id: window.id, app: window.app, title: window.title,
                                tabURL: tab?.url, tabTitle: tab?.title)
        }
    }

    /// 每個 window id 的**當前**分頁。判準與 `WindowMatching.currentTabURL` 相同：
    /// 第四欄是 `1`（`1.0` 與 ` 1` 都不算當前分頁——那支的右手邊是字串常數）。
    ///
    /// **同一個 id 命中多次時留第一筆**，與那支的 `return` 一致（它掃到就回，
    /// 不會走完）。寫成字典的預設覆寫是**最後一筆**贏，那不只在畸形的 dump 上
    /// 給出不同答案，還會讓「收下每一個分頁」這個突變在當前分頁剛好是最後一行時
    /// 靜默全綠——2026-08-28 實測就是這樣（那個守衛看起來有測試而其實沒有）。
    private static func currentTabs(in dump: String)
        -> [String: (url: String, title: String)]
    {
        var out: [String: (url: String, title: String)] = [:]
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 4, columns[3] == "1" else { continue }
            let key = normalized(String(columns[0]))
            guard out[key] == nil else { continue }
            out[key] = (String(columns[1]), String(columns[2]))
        }
        return out
    }

    /// id 兩邊都先試著當整數。dump 是 osascript 印的、yabai 那份走
    /// `JQPrint.interpolate`，實務上兩邊都是十進位整數；但字面比對一旦失配是
    /// **靜默**的（Safari 視窗沒有網址可選），而正規化的成本是一次 `Int(_:)`。
    /// 轉不出整數就用原字串——那不是預期的輸入，但退回字面比對比丟掉那筆好。
    private static func normalized(_ id: String) -> String {
        Int(id).map(String.init) ?? Double(id).map { String(Int($0)) } ?? id
    }
}
