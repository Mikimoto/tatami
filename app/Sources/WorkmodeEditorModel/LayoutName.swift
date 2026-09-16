import WorkmodeDomain

/// 地點名與 profile 名的合法性。四條規則都來自 `LayoutValidator`，
/// 訊息直接進 `EditorController.lastRejection` 的 alert。
///
/// **回訊息而不是回 Bool**：四種拒絕要改的東西不一樣，同一句話等於沒說。
public enum LayoutName {
    /// nil 代表合法。`what` 是「地點」或「profile」，只用來組訊息。
    /// `existing` 不含「正在被改名的那個自己」——改名成自己不算撞名。
    public static func rejection(for name: String, existing: [String],
                                 what: String) -> String?
    {
        if name.isEmpty {
            return "\(what)名稱不能是空的。"
        }
        if name == "auto" {
            return "\(what)不能叫 auto，那是 --switch 的保留字。"
        }
        if LayoutValidator.containsWhitespace(name) {
            return "\(what)名稱「\(name)」不能含空白（全形空白與 NBSP 也算）。"
        }
        if existing.contains(name) {
            return "已經有一個叫「\(name)」的\(what)了。"
        }
        return nil
    }
}
