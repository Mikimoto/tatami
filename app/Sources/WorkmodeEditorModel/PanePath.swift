import WorkmodeDomain

/// 畫布上一個窗格的位置：哪個地點、哪個 profile、哪個角色、**哪一頁**，以及從那棵樹
/// 的根往下走過的 slot（每一步是 0 或 1）。
///
/// 把五段綁成一個值而不是五個參數：`PaneView` 遞迴時只要 `path.child(0)`，
/// 而編輯動作的簽名不會變成六個字串。回報在 phase 3b 兌現——`space` 加進來之後，
/// `placing`／`deletingPane`／`settingRatio`／`flippingAxis` **一個字都不用改**，
/// 因為它們全部經過 `roleSteps`。
/// `Hashable` 是給 SwiftUI 的 `@FocusState` 用的——`.focused(_:equals:)` 要求它。
/// 所有成員本來就都是 Hashable，不用寫任何實作。
public struct PanePath: Equatable, Hashable, Sendable {
    public let location: String
    public let profile: String
    public let role: String
    /// 這一頁的 space uuid。**必填**——2026-08-30 之前它是 Optional，nil 代表
    /// 分頁列的第一頁「目前可見」（`trees.<角色>`）。那一頁拿掉之後編輯器只編
    /// `spaceTrees`，而讓它非 Optional 是為了讓「忘了傳」變成編譯錯誤而不是
    /// 靜默掉回 `trees` 那棵（那棵通常也存在，所以症狀是「編到了別的版面」）。
    public let space: String
    public let slots: [Int]

    /// **`space` 沒有預設值**：留著預設值就等於留著「忘了傳會靜默掉回 `trees`」
    /// 那個洞，而拿掉那一頁的用意正是把它變成編譯錯誤。
    public init(location: String, profile: String, role: String,
                space: String, slots: [Int])
    {
        self.location = location
        self.profile = profile
        self.role = role
        self.space = space
        self.slots = slots
    }

    public func child(_ slot: Int) -> PanePath {
        PanePath(location: location, profile: profile, role: role, space: space,
                 slots: slots + [slot])
    }

    /// 根沒有父親。刪掉根窗格走的是「刪掉那棵樹的鍵」那條路。
    public var parent: PanePath? {
        slots.isEmpty
            ? nil
            : PanePath(location: location, profile: profile, role: role, space: space,
                       slots: Array(slots.dropLast()))
    }

    /// 同一個父親底下另一邊的 slot。塌掉一個窗格時頂上來的就是它。
    public var siblingSlot: Int? {
        guard let last = slots.last else { return nil }
        return 1 - last
    }

    /// 這一頁那棵樹的根。**這是整個檔案裡唯一決定「編的是哪棵樹」的地方。**
    ///
    /// 2026-08-30 之前這裡有一個 `guard let space` 的分支走 `trees.<角色>`
    /// （分頁列的第一頁「目前可見」）。那一頁拿掉了：編輯器只編 `spaceTrees`。
    public var roleSteps: [JSONPath.Step] {
        [.key(location), .key("profiles"), .key(profile),
         .key("spaceTrees"), .key(role), .key(space)]
    }

    /// 這個窗格自己的路徑。
    public var steps: [JSONPath.Step] {
        roleSteps + slots.flatMap { [JSONPath.Step.key("children"), .index($0)] }
    }
}
