import WorkmodeDomain

/// 地點的增刪改名，形狀與 `ProfileEdit` 相同：`LayoutDocument → LayoutDocument`
/// 的純函式，走 `JSONPath` 定點修改，走不通就回原文件。
public extension LayoutDocument {
    /// 新增一個地點。**一次建齊 validate 要求的四件事**（C1）：非空 desc、
    /// `displays.main`、非空的 `profiles`、以及那個 profile 的 `trees`。
    /// 只建空殼的話存不了檔，而使用者看不出缺什麼。
    ///
    /// **`main` 的 UUID 是空字串，不是猜一個值。** validate 只查那個鍵存不存在
    /// （`LayoutValidator.swift:76`），所以空字串過得了——但那個地點永遠不會被
    /// 自動偵測到。留一個看得見的洞比留一個看不見的假值好，UI 那側要標出來。
    /// phase 2d 會從 yabai 帶真的 UUID 進來。
    ///
    /// **名字不合法就什麼都不做**，而「已經有一個同名地點」也算不合法：
    /// `JSONPath.set` 對既有的鍵是**原地更新**，少了這道守衛，
    /// `addingLocation("office", …)` 會把整個 office 換成新建的空殼——
    /// 連同它的 displays、profiles 與全部的樹，而且沒有任何訊號。
    /// `addingAgreesWithTheNameRefusal` 的 `office` 那一項釘著這件事。
    func addingLocation(_ name: String, desc: String,
                        firstProfile: String) -> LayoutDocument
    {
        guard locationNameRefusal(name) == nil else { return self }
        return rebuilt(try? JSONPath.set(root, [.key(name)], to: .object([
            JSONMember(key: "desc", value: .string(desc)),
            JSONMember(key: "displays", value: .object([
                JSONMember(key: "main", value: .string("")),
            ])),
            JSONMember(key: "profiles", value: .object([
                JSONMember(key: firstProfile, value: .object([
                    JSONMember(key: "trees", value: .object([])),
                ])),
            ])),
        ])))
    }

    /// 改名，位置不動。地點名在文件裡沒有別處引用（`default` 是地點**內**的），
    /// 所以不用像 profile 那樣做 fixup。
    ///
    /// **但狀態檔會變成孤兒**：`~/.config/tatami/.tatami-state` 的 `location=<舊名>` 與
    /// `profile.<舊名>=…` 指到一個不存在的地點。那個檔在文件外、編輯器不碰它，
    /// 後果是下次啟動時那個覆寫失效、退回自動偵測——可復原，所以不擋。
    func renamingLocation(_ old: String, to new: String) -> LayoutDocument {
        guard locationNameRefusal(new, excluding: old) == nil else { return self }
        return rebuilt(try? JSONPath.renameKey(root, [], from: old, to: new))
    }

    func settingLocationDesc(_ location: String, to desc: String) -> LayoutDocument {
        rebuilt(try? JSONPath.set(root, [.key(location), .key("desc")], to: .string(desc)))
    }

    func deletingLocation(_ name: String) -> LayoutDocument {
        guard locationDeletionRefusal(name) == nil else { return self }
        return rebuilt(try? JSONPath.delete(root, [.key(name)]))
    }

    /// nil 代表刪得掉。零個地點的設定 validate 不會抱怨（它逐地點檢查，沒有地點
    /// 就沒有檢查），但那份設定對 `workmode` 完全沒有用——擋下來比讓使用者
    /// 存出一個空殼好。
    func locationDeletionRefusal(_ name: String) -> String? {
        guard locations.contains(name) else { return nil }
        return locations.count <= 1
            ? "這是唯一的地點，刪掉之後這份設定就沒有任何地點可以套用了。"
            : nil
    }

    /// 這個名字當**地點**合不合法。nil 代表可以。
    ///
    /// `excluding` 是「正在被改名的那個自己」——改名成自己不算撞名。
    ///
    /// **`windows` 這條只在地點層成立**（profile 叫 `windows` 完全合法，
    /// `ProfileResolution` 的疊加語意就靠 profile 層那個鍵），所以它不在
    /// `LayoutName` 裡。
    ///
    /// **`addingLocation` 與 `renamingLocation` 走的是同一支**，抄兩份會漂移——
    /// `addingAgreesWithTheNameRefusal` 把它們綁在一起驗。
    func locationNameRefusal(_ name: String, excluding current: String? = nil) -> String? {
        if name == LayoutQuery.reservedKey {
            return "地點不能叫 \(LayoutQuery.reservedKey)，那是共用規則總表的鍵。"
        }
        return LayoutName.rejection(for: name,
                                    existing: locations.filter { $0 != current },
                                    what: "地點")
    }

    /// desc 空的就存不了檔：validate 要求它是**非空**字串
    /// （`LayoutValidator.swift` 的「<地點>.desc（要非空字串）」）。
    func locationDescRefusal(_ desc: String) -> String? {
        desc.isEmpty ? "說明不能是空的：validate 要求 desc 是非空字串。" : nil
    }

    /// 這個地點的 desc。非字串照 `JQPrint.interpolate` 印（與 `displayUUID` 同一條
    /// ——編輯器要能開一份還沒通過 validate 的檔）。缺這個鍵回空字串。
    func locationDesc(_ location: String) -> String {
        guard let value = root[location]?["desc"] else { return "" }
        switch value {
        case .null, .bool(false): return ""
        default: return JQPrint.interpolate(value)
        }
    }
}
