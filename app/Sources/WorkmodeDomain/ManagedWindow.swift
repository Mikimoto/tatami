/// 「受管理的視窗」那個 select，唯一一份。
///
/// bash 那側是三個地方逐字相同的
/// `select(.["is-floating"] == false and .["is-minimized"] == false
///         and .["is-visible"] == true)`
/// （`workmode.sh` 的量測、space 矩形、以及 layout 前的視窗計數）。
///
/// 收成一份不只是去重：這個 predicate 走在 `validate`／`match_location` 之外的路徑上，
/// 副本寫錯不會有任何訊號——三個旗標的**恰好相等**很容易被寫成「truthy 判斷」，
/// 而那在缺欄位時答案就相反了。
public enum ManagedWindow {
    /// - Returns: nil ＝ jq 的 runtime error（元素不是物件也不是 null，字串索引報錯）。
    ///
    /// 三個都要**恰好**對上：缺欄位是 null，而 `null == false` 是 false、
    /// `null == true` 也是 false，所以缺欄位的視窗被排除而不是被當成 false。
    ///
    /// 短路的位置照 jq 的 `and`：`is-floating` 已經不對時後兩次索引不發生，
    /// 所以那兩個欄位就算會讓索引報錯也不影響答案。
    public static func matches(_ element: JSONValue) -> Bool? {
        guard let floating = member(element, "is-floating") else { return nil }
        guard floating == .bool(false) else { return false }
        guard let minimized = member(element, "is-minimized") else { return nil }
        guard minimized == .bool(false) else { return false }
        guard let visible = member(element, "is-visible") else { return nil }
        return visible == .bool(true)
    }

    /// `.[key]`。null 索引出 null（不是錯），物件取成員（沒有就 null），
    /// 其餘型別報錯——**陣列也不行**，字串索引只對物件成立。
    private static func member(_ value: JSONValue, _ key: String) -> JSONValue? {
        switch value {
        case .null: .null
        case .object: value[key] ?? .null
        default: nil
        }
    }
}
