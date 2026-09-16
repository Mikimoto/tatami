import WorkmodeDomain

/// 一個螢幕角色畫布上方的一個分頁 ＝ 一個 space。
///
/// **2026-08-30 之前第一頁是「目前可見」**（`trees.<角色>`），其餘是使用者手動命名的
/// space。那一頁拿掉了：編輯器只編 `spaceTrees`，而 space 的身分是 uuid，不再有名字。
public struct SpaceTab: Equatable, Sendable {
    /// 這個分頁的 space uuid。**這就是 `spaceTrees[角色]` 的鍵。**
    public let space: String
    /// yabai 現在給這個 space 的編號，給人看的。
    ///
    /// nil ＝ **yabai 查不到它**，兩個成因：這個 space 被 macOS 刪掉了（樹變成孤兒），
    /// 或者根本沒接上 yabai。兩者 UI 都標橘字——不標的話那棵樹會看不見地留在檔案裡。
    public let index: Int?
    /// 有沒有樹。沒有的話畫布是空的，拖第一個 label 進去才會建。
    public let hasTree: Bool

    public init(space: String, index: Int?, hasTree: Bool) {
        self.space = space
        self.index = index
        self.hasTree = hasTree
    }
}

public extension LayoutDocument {
    /// 這個角色的分頁列 ＝ **live spaces ∪ `spaceTrees[角色]` 已有的 uuid**。
    ///
    /// 兩邊都要，而且順序是「yabai 的在前、孤兒接在後面」（與 `canvasRoles` 的
    /// display 在前、只有 tree 的接在後面同一個形狀）：
    ///
    ///   * 只看 yabai → 被 macOS 刪掉的 space 留下的樹從畫面上消失，而檔案裡還在，
    ///     `validate` 照樣會檢查它、照樣會擋 ⌘S。
    ///   * 只看 `spaceTrees` → 還沒畫過的 space 沒有分頁可以拖東西進去，等於退回
    ///     舊的「要先新增才能畫」。
    ///
    /// `live` 由呼叫端查好傳進來：Model 不能碰外部世界（`DependencyRuleTests` 的
    /// `editorLayersKeepTheirDistance` 掃原始碼在守），而查 yabai 每次都 spawn 子行程。
    func spaceTabs(location: String, profile: String, role: String,
                   live: [LiveSpace]) -> [SpaceTab]
    {
        let treed = spaceTreeNames(location: location, profile: profile, role: role)
        let known = Set(live.map(\.uuid))
        let hasTree = Set(treed)
        return live.map { SpaceTab(space: $0.uuid, index: $0.index,
                                   hasTree: hasTree.contains($0.uuid)) }
            + treed.filter { !known.contains($0) }
            .map { SpaceTab(space: $0, index: nil, hasTree: true) }
    }

    /// `spaceTrees[角色]` 的鍵（space uuid），來源鍵序。
    func spaceTreeNames(location: String, profile: String, role: String) -> [String] {
        guard case let .object(trees)? =
            root[location]?["profiles"]?[profile]?["spaceTrees"]?[role] else { return [] }
        return trees.map(\.key)
    }

    /// 某一頁那棵樹。
    ///
    /// 路徑不存在時回 `.empty` 而不是 nil，與既有那支同一條：UI 只要畫得出「未指定」
    /// 就夠，不必替「沒有這個角色」與「這個角色是畸形節點」分兩種畫法。
    func tree(location: String, profile: String, role: String, space: String) -> PaneNode {
        guard let node = root[location]?["profiles"]?[profile]?["spaceTrees"]?[role]?[space]
        else { return .empty }
        return PaneNode(node)
    }
}
