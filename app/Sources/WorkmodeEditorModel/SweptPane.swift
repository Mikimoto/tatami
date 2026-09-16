import WorkmodeDomain

/// 掃除回報的一個窗格：它在哪一棵樹的哪個位置。
///
/// **不是 `PanePath`。** 2026-08-30 之後 `PanePath.space` 是必填的（編輯器只編
/// `spaceTrees`，讓「忘了傳」變成編譯錯誤），而掃除要涵蓋的是**這個 profile 底下
/// 每一棵樹**——包含 `trees.<角色>`，那是 `workmode` 那條路徑套的、編輯器不編、
/// 但 `LayoutValidator.treeChecks` 照樣檢查的一半。少掃它的症狀是刪掉一條規則之後
/// ⌘S 被擋，而錯誤訊息指著一棵使用者沒動過的樹。
///
/// 所以這裡的 `space` 仍然是 Optional，而且**只有掃除讀得到它**：它不是編輯動作的
/// 座標，是一句話的素材。
public struct SweptPane: Equatable, Sendable {
    public let location: String
    public let profile: String
    public let role: String
    /// nil ＝ `trees.<角色>`（`workmode` 套的那一棵）。非 nil ＝ `spaceTrees` 的
    /// 那個 space uuid。
    public let space: String?
    public let slots: [Int]

    public init(location: String, profile: String, role: String,
                space: String?, slots: [Int])
    {
        self.location = location
        self.profile = profile
        self.role = role
        self.space = space
        self.slots = slots
    }

    /// 那棵樹的根。與 2026-08-30 之前 `PanePath.roleSteps` 逐字相同——這一段
    /// 就是從那裡搬過來的。
    public var roleSteps: [JSONPath.Step] {
        let base: [JSONPath.Step] = [.key(location), .key("profiles"), .key(profile)]
        guard let space else { return base + [.key("trees"), .key(role)] }
        return base + [.key("spaceTrees"), .key(role), .key(space)]
    }

    public var steps: [JSONPath.Step] {
        roleSteps + slots.flatMap { [JSONPath.Step.key("children"), .index($0)] }
    }
}
