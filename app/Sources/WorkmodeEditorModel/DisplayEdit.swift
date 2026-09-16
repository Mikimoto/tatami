import WorkmodeDomain

/// 螢幕角色的增、減、改 UUID，形狀與 `ProfileEdit`／`LocationEdit` 相同：
/// `LayoutDocument → LayoutDocument` 的純函式，走 `JSONPath` 定點修改，
/// 走不通就回原文件。
///
/// **沒有「改名角色」。** 角色名同時是 `<地點>.displays` 的鍵與
/// `<地點>.profiles.<profile>.trees` 的鍵，改一邊會讓另一邊變成孤兒，
/// 而那是兩個動作不是一個。要換名字就新增再刪掉，畫布會照實顯示中間狀態
/// （`CanvasRole` 的聯集第二段把「有 tree 沒 display」畫出來）。
public extension LayoutDocument {
    private func displaysPath(_ location: String) -> [JSONPath.Step] {
        [.key(location), .key("displays")]
    }

    /// 新增一個螢幕角色。**撞名時什麼都不做**：覆蓋會靜默改掉另一台螢幕的身分，
    /// 而畫面上兩個角色名長得一模一樣。
    func addingDisplayRole(_ role: String, uuid: String,
                           to location: String) -> LayoutDocument
    {
        guard !role.isEmpty, !displayRoles(in: location).contains(role) else { return self }
        return rebuilt(try? JSONPath.set(root, displaysPath(location) + [.key(role)],
                                         to: .string(uuid)))
    }

    func settingDisplayUUID(_ role: String, to uuid: String,
                            in location: String) -> LayoutDocument
    {
        rebuilt(try? JSONPath.set(root, displaysPath(location) + [.key(role)],
                                  to: .string(uuid)))
    }

    /// 刪掉一個螢幕角色。**不連帶刪它的樹**——那棵樹會變成「有 tree 沒 display」，
    /// 畫布照樣畫它並標橘字（`CanvasRole`）。靜默刪掉一棵樹比留一個看得見的警告糟。
    func removingDisplayRole(_ role: String, in location: String) -> LayoutDocument {
        guard displayRoleRemovalRefusal(role, in: location) == nil else { return self }
        return rebuilt(try? JSONPath.delete(root, displaysPath(location) + [.key(role)]))
    }

    /// nil 代表刪得掉。`main` 是唯一擋下來的：`displays` 是物件時 validate 要求
    /// 它存在（`LayoutValidator.swift:75-76`），刪掉之後 ⌘S 會被擋。
    func displayRoleRemovalRefusal(_ role: String, in location: String) -> String? {
        guard displayRoles(in: location).contains(role) else { return nil }
        return role == "main"
            ? "main 刪不掉：validate 要求每個有 displays 的地點都得有它。"
            : nil
    }
}
