import WorkmodeDomain

/// 挑選器上的一台螢幕。
///
/// **名稱不放進 `WorkmodeDomain.Display`**：那個型別是「yabai 說了什麼」，而名稱
/// yabai 沒說（它的 `label` 是使用者自己貼的標籤，實測三台都是空字串）。名稱來自
/// `NSScreen.localizedName`，那是 Adapters 的事——Model 只負責把兩邊接起來。
public struct DisplayChoice: Equatable, Sendable {
    public let uuid: String
    public let index: Int
    /// 查不到就 nil——UI 那側退回顯示 UUID。
    public let name: String?
    public let size: String?

    public init(uuid: String, index: Int, name: String?, size: String?) {
        self.uuid = uuid
        self.index = index
        self.name = name
        self.size = size
    }

    /// **以 yabai 那份為準**：能被 `layout.json` 引用的就是它列出來的那些，順序也照它
    /// （實測使用者的機器是 index 1、3、2，不連續也沒排序過）。
    ///
    /// macOS 認得而 yabai 沒列的螢幕不會出現；yabai 列了而 macOS 沒有名稱的，
    /// `name` 與 `size` 是 nil 而那台**仍然要在清單裡**——把它濾掉的話使用者就選不到
    /// 那台螢幕，而畫面上看不出少了什麼。
    public static func merge(_ displays: [Display],
                             names: [String: (name: String, size: String)]) -> [DisplayChoice]
    {
        displays.map { display in
            let entry = names[display.uuid]
            return DisplayChoice(uuid: display.uuid, index: display.index,
                                 name: entry?.name, size: entry?.size)
        }
    }
}
