/// `spaceTrees`（角色 ＋ space uuid → 樹）的查表。
///
/// 純查表、零 port：`--space` 的編排住在 Core，但「哪個 uuid 對到哪棵樹」是規則，
/// 而規則要在 Domain 才測得到（`CLAUDE.md`：「port 只回原始資料，判斷放 Core，
/// 純的部分再往下放進 Domain」）。
///
/// **2026-08-30 之前這裡有兩支**：`name(of:in:)` 先把 uuid 反查成名字，再用名字查樹。
/// 那條鏈連帶帶來三種失效——「有名字沒樹」與「有樹沒名字」兩種孤兒，以及 `spaces`
/// 放錯層的靜默無效。uuid 直接當索引之後三種都不存在了。
public enum SpaceNames {
    /// `spaceTrees[角色][uuid]`。任何一層不在就是 nil ＝ 這個螢幕什麼都不做。
    public static func tree(role: String, uuid: String, in spaceTrees: JSONValue) -> JSONValue? {
        guard case .object = spaceTrees, let byUUID = spaceTrees[role],
              case .object = byUUID
        else { return nil }
        return byUUID[uuid]
    }

    /// `spaceTrees[角色]` 底下**每一棵**樹，照檔案裡的順序。`--space --all` 用它。
    ///
    /// 回 `[]` 而不是 nil 或 throw：角色沒有這一層就是「這台沒有東西要排」，
    /// 與 `tree(role:uuid:)` 對缺層回 nil 是同一個立場。順序保留是為了讓事件與測試
    /// 的斷言可以寫死——`JSONValue.object` 本來就是保序的。
    public static func trees(role: String, in spaceTrees: JSONValue) -> [(uuid: String, tree: JSONValue)] {
        guard case .object = spaceTrees, let byUUID = spaceTrees[role],
              case let .object(members) = byUUID
        else { return [] }
        return members.map { (uuid: $0.key, tree: $0.value) }
    }

    /// 這份 `spaceTrees` 總共存了幾個 space 的樹（所有角色相加）。
    ///
    /// 給選單列的覆蓋確認框用：一個破壞性的確認要說出它要毀掉多少東西，而
    /// 「2 個」與「0 個」的差別是「兩天的工作」與「一個空殼」。
    ///
    /// 不用 `trees(role:)` 相加是因為呼叫端拿不到角色清單（那要走 `displays`），
    /// 而它只想要一個數字。壞掉的角色跳過而不是整份回 0——與 `tree(role:uuid:)`
    /// 對缺層回 nil 同一個立場。
    public static func spaceCount(in spaceTrees: JSONValue) -> Int {
        guard case let .object(roles) = spaceTrees else { return 0 }
        return roles.reduce(0) { total, role in
            guard case let .object(byUUID) = role.value else { return total }
            return total + byUUID.count
        }
    }
}
