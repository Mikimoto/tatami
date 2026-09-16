import WorkmodeDomain

/// profile 的增刪改名，形狀與 `RuleEdit`／`TreeEdit` 相同：
/// `LayoutDocument → LayoutDocument` 的純函式，走 `JSONPath` 定點修改，
/// 走不通就回原文件。
public extension LayoutDocument {
    private func profilesPath(_ location: String) -> [JSONPath.Step] {
        [.key(location), .key("profiles")]
    }

    /// 新增一個 profile。**形狀是 `{"trees": {}}`**，與 `--save` 建新 profile 時
    /// 相同（`ProfileResolution.merge`）——兩邊產出不同形狀會讓「哪個是對的」
    /// 變成沒人知道的問題。
    ///
    /// **名字不合法就什麼都不做**，而「已經有一個同名 profile」也算不合法：
    /// `JSONPath.set` 對既有的鍵是**原地更新**，少了這道守衛，
    /// `addingProfile("開發", to: "office")` 會把 `office.開發` 整個換成
    /// `{"trees": {}}`——那個 profile 的所有樹靜默消失。
    /// `addingAgreesWithTheNameRefusal` 的 `開發` 那一項釘著這件事。
    func addingProfile(_ name: String, to location: String) -> LayoutDocument {
        guard profileNameRefusal(name, in: location) == nil else { return self }
        return rebuilt(try? JSONPath.set(root, profilesPath(location) + [.key(name)],
                                         to: .object([
                                             JSONMember(key: "trees", value: .object([])),
                                         ])))
    }

    /// 改名，**位置不動**，並且**順手改 `default`**：它指著舊名字的話會變成假指標，
    /// validate 報「<地點>.default「X」不是這個地點的 profile」而 ⌘S 被擋。
    /// 與刪除不對稱是刻意的——改名時使用者的意圖明確（同一個 profile 換個名字），
    /// 刪除時不明確（要換一個 default 還是不要 default？），所以刪除是拒絕。
    func renamingProfile(_ old: String, to new: String,
                         in location: String) -> LayoutDocument
    {
        guard profileNameRefusal(new, in: location, excluding: old) == nil else { return self }
        guard let renamed = try? JSONPath.renameKey(root, profilesPath(location),
                                                    from: old, to: new)
        else { return self }
        guard JSONPath.get(renamed, [.key(location), .key("default")]) == .string(old)
        else { return rebuilt(renamed) }
        return rebuilt(try? JSONPath.set(renamed, [.key(location), .key("default")],
                                         to: .string(new)))
    }

    /// 刪除。被 `profileDeletionRefusal` 擋下時回原文件不變。
    func deletingProfile(_ name: String, in location: String) -> LayoutDocument {
        guard profileDeletionRefusal(name, in: location) == nil else { return self }
        return rebuilt(try? JSONPath.delete(root, profilesPath(location) + [.key(name)]))
    }

    /// 刪得掉嗎。nil 代表可以，非 nil 是**給使用者看的理由**（UI 拿它當 tooltip
    /// 並停用按鈕，所以不走 `lastRejection`——那個 alert 是給「按了才發現沒生效」
    /// 用的，而這裡按不下去）。
    ///
    /// 兩個守衛的來源都是 validate（C1／C2）：地點的 `profiles` 不能是空的，
    /// 而 `default` 必須指到存在的 profile。
    func profileDeletionRefusal(_ name: String, in location: String) -> String? {
        let all = profiles(in: location)
        guard all.contains(name) else { return nil }
        if all.count <= 1 {
            return "這是「\(location)」唯一的 profile，刪掉之後這個地點就不合法了"
                + "（validate 要求 profiles 不能是空的）。"
        }
        if JSONPath.get(root, [.key(location), .key("default")]) == .string(name) {
            return "「\(location)」的 default 指著它。先把 default 改成別的 profile，"
                + "再回來刪這個。"
        }
        return nil
    }

    /// 這個名字在這個地點當 **profile** 合不合法。nil 代表可以。
    /// `excluding` 是正在被改名的那個自己。
    ///
    /// **不擋 `LayoutQuery.reservedKey`**：profile 叫 `windows` 是合法的，
    /// 那個鍵在 profile 層是「整組取代共用規則」的語意。地點層才擋，
    /// 見 `locationNameRefusal`。
    func profileNameRefusal(_ name: String, in location: String,
                            excluding current: String? = nil) -> String?
    {
        LayoutName.rejection(for: name,
                             existing: profiles(in: location).filter { $0 != current },
                             what: "profile")
    }
}
