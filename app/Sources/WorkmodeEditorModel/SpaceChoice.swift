import WorkmodeDomain

/// yabai 現在列出來的一個 space，原樣四個欄位。
///
/// 是具名型別而不是 tuple：swiftlint 的 `large_tuple` 從三個欄位起就報，
/// 而這四個要跨 CLI → Control → Model 三層傳。
public struct LiveSpace: Equatable, Sendable {
    public let uuid: String
    public let index: Int
    public let display: Int
    public let visible: Bool

    public init(uuid: String, index: Int, display: Int, visible: Bool) {
        self.uuid = uuid
        self.index = index
        self.display = display
        self.visible = visible
    }
}

/// 分頁列上的一個 space。
///
/// 拿 uuid 當身分而不是 index：index 會在 Mission Control 增刪 space 時**無聲錯位**，
/// 而 uuid 撐得過重開機（2026-08-22 實測，證據在 repo 的 `CLAUDE.md`）。
/// index 只是給人看的。
public struct SpaceChoice: Equatable, Sendable {
    public let uuid: String
    /// yabai 的 space index（給人看的，不是身分）。
    public let index: Int
    /// 這個 space 在哪台螢幕上（yabai 的 display index）。
    ///
    /// **現在沒有生產程式碼讀它**——清單已經濾成單一螢幕，label 也拿掉了
    /// 「顯示器 N ·」，唯一的讀者是測試。留著是因為它是來源事實的一部分，
    /// 但不要以為畫面上看得到它。2026-08-29 由 fresh-context review 指出。
    public let displayIndex: Int
    public let isVisible: Bool
    /// 這個 space 在這個 profile 底下有沒有樹。沒有的話分頁還是列，只是畫布是空的。
    ///
    /// **2026-08-30 之前這裡是 `takenBy: String?`**（已經被哪個名字佔走）。那時分頁
    /// 要先命名才會出現，所以「被佔走」是一個要標成不可選的狀態；現在全部都列，
    /// 唯一的區別是有沒有畫過。
    public let hasTree: Bool

    public init(uuid: String, index: Int, displayIndex: Int,
                isVisible: Bool, hasTree: Bool)
    {
        self.uuid = uuid
        self.index = index
        self.displayIndex = displayIndex
        self.isVisible = isVisible
        self.hasTree = hasTree
    }

    /// 把 yabai 的清單濾成這個角色的螢幕，再標出哪些已經有樹。
    ///
    /// **只留 `onDisplay` 那一台**：角色對應一台螢幕，而 `--space` 只套「這台螢幕
    /// 現在可見的 space」，別台的 uuid 永遠不會被走到——列出來就是做得出一個靜默
    /// 永遠不生效的設定。
    ///
    /// 排序照 index：yabai 回的順序是它自己的（實測不連續也沒排序過）。
    /// 過濾之後 display 都相同，所以不必再照 display 排。
    public static func merge(_ spaces: [LiveSpace],
                             treed: [String],
                             onDisplay: Int) -> [SpaceChoice]
    {
        let hasTree = Set(treed)
        return spaces
            .filter { $0.display == onDisplay }
            .sorted { $0.index < $1.index }
            .map { SpaceChoice(uuid: $0.uuid, index: $0.index, displayIndex: $0.display,
                               isVisible: $0.visible, hasTree: hasTree.contains($0.uuid)) }
    }
}
