/// 規則表格的一列。`fallback` 兩個欄位要嘛都有要嘛都沒有——layout.json 裡它是
/// 一個兩元素的陣列，拆成兩個 Optional 只是為了讓表格好畫。
///
/// 欄位是 `String` 而不是 `JSONValue`（`LayoutQuery.WindowRule` 是後者）：那一支的
/// 消費端是 `@tsv`，哪一步報錯是可觀測的行為；這一支的消費端是表格，只要印得出來。
public struct RuleRow: Equatable, Sendable {
    public let label: String
    public let matchKind: String
    public let matchValue: String
    public let fallbackKind: String?
    public let fallbackValue: String?
    /// `--launch` 要開哪個 app。nil ＝ 檔案裡沒有這個鍵（常態），與 `fallback`
    /// 同一個語意——**看鍵存不存在，不看它的值**，因為空字串在執行時與沒有這個鍵
    /// 等價（`LaunchableApps.named` 對兩者都往下推回 `match`），而表格要分得出
    /// 「沒設」與「設成空的」，不然使用者刪不掉自己打錯的那格。
    public let launch: String?

    public init(label: String, matchKind: String, matchValue: String,
                fallbackKind: String?, fallbackValue: String?,
                launch: String? = nil)
    {
        self.label = label
        self.matchKind = matchKind
        self.matchValue = matchValue
        self.fallbackKind = fallbackKind
        self.fallbackValue = fallbackValue
        self.launch = launch
    }
}
