/// 廢止的 `spaces` 鍵與 profile 層 `spaceTrees`（角色 → {space uuid: 樹}）的檢查。
///
/// 分成獨立的檔案是因為 `LayoutValidator.swift` 已經 362 行，而 swiftlint 的
/// `file_length` 在 400 行報警、`mise run lint` 對任何一行輸出都回非零。
///
/// 這兩個鍵**沒有 bash 對應**，所以這裡沒有「照抄 jq 行為」的義務——形狀不對就直接
/// 報，不學 `displays` 那條靜默略過的怪脾氣（`LayoutValidator.swift:73-77`）。
/// 那條之所以留著是因為它是 bash 的既有行為，複製它是移植的義務；新鍵沒有。
///
/// `spaces` 2026-08-30 廢止（見 `spacesChecks`），所以它只剩「擋下舊格式」這一件事。
extension LayoutValidator {
    /// `spaces` 這個鍵**已經廢止**（2026-08-30）：`spaceTrees` 直接用 space uuid 當索引。
    ///
    /// 這裡不再檢查它的內容，而是**擋下它的存在**。不擋的話舊格式會靜默失效——
    /// `spaceTrees` 用名字當鍵，而 `--space` 的查表只認 uuid，於是每個螢幕都走
    /// 「這個 space 沒有樹」，設定看起來寫好了而功能就是不動。
    ///
    /// 形狀不重要：不論它是物件、字串還是 null，答案都是「這個鍵不該在這裡」。
    static func spacesChecks(location: String, value: JSONValue) -> [LayoutProblem] {
        guard value["spaces"] != nil else { return [] }
        return [.structural(retiredSpacesKey(prefix: location))]
    }
}

extension LayoutValidator {
    /// profile 層的 `spaces` 也擋，訊息與地點層那條相同。
    ///
    /// 兩層都要擋：`spacesChecks` 只在地點層跑，把舊的 `spaces` 搬進 profile 就繞過去了。
    ///
    /// 抽成一支函式而不是寫在 `profileChecks` 裡：那支已經是 cyclomatic complexity 10，
    /// 再多一個分支就破 swiftlint 的上限（而 `.swiftlint.yml` 明文禁止調參數）。
    static func misplacedSpacesCheck(prefix: String, value: JSONValue) -> [LayoutProblem] {
        guard value["spaces"] != nil else { return [] }
        return [.structural(retiredSpacesKey(prefix: prefix))]
    }

    /// 兩層共用同一句話。分成兩份的話它們會漂，而使用者看得到的就只有這句。
    private static func retiredSpacesKey(prefix: String) -> String {
        "\(prefix)：spaces 已經不用了——space 版面改用 space uuid 當索引，"
            + "把 spaceTrees 的鍵從名字換成 uuid 再刪掉這個鍵"
    }
}

extension LayoutValidator {
    /// `spaceTrees[角色][space uuid]` 的每一棵樹都走一次 `treeChecks`。
    ///
    /// `labels` 由呼叫端傳進來而不是在這裡重算：它與 `trees` 用的必須是同一份，
    /// 而「profile 自己有 windows 就整塊取代共用層與地點層」這條規則只寫在
    /// `effectiveLabels` 一個地方才不會漂。
    ///
    /// 回傳的 `continues` 與 `allTreeChecks` 同義：false 代表 jq 那側會 runtime
    /// error、整個串流結束，呼叫端必須跟著停。
    static func spaceTreeChecks(value: JSONValue, labels: [JSONValue], prefix: String)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        guard let spaceTrees = value["spaceTrees"] else { return ([], true) }
        guard case let .object(roles) = spaceTrees else {
            return ([.structural("\(prefix)：spaceTrees 要是物件（角色 → {space uuid: 樹}）")], true)
        }
        var out: [LayoutProblem] = []
        for role in roles {
            guard case let .object(named) = role.value else {
                out.append(.structural(
                    "\(prefix).spaceTrees.\(role.key)：要是物件（space uuid → 樹）"
                ))
                continue
            }
            for entry in named {
                out += spaceKeyChecks(key: entry.key,
                                      prefix: "\(prefix).spaceTrees.\(role.key)")
                let step = treeChecks(node: entry.value, labels: labels,
                                      path: "\(prefix).spaceTrees.\(role.key).\(entry.key)")
                out += step.problems
                if !step.continues {
                    return (out, false)
                }
            }
        }
        return (out, true)
    }
}

extension LayoutValidator {
    /// space uuid 這個鍵本身合不合理。
    ///
    /// 只擋兩種「永遠配不到任何 space」的鍵：**空字串**與**含空白的字串**。
    /// `--space` 是拿當下可見的 space uuid 去查這張表，而那兩種都不可能是它，
    /// 所以那棵樹是死設定——而症狀是「那個 space 我明明畫過，切過去卻什麼都沒發生」，
    /// 沒有任何訊息。實際踩到過（`office.開發.spaceTrees` 底下 `main` 與 `ASUS`
    /// 各有一個 `""`，各掛著一棵畫好的兩格樹，2026-09-07 由清點抓到）。
    ///
    /// **不檢查 uuid 的格式。** 那會需要一份「什麼算 uuid」的定義，而擋錯的代價
    /// （一份寫對的設定存不了檔，而畫面上那個 uuid 看起來完全正常）遠高於漏掉
    /// 一個手打錯的 uuid——後者的樹一樣不會生效，但那與「這個 space 已經被 macOS
    /// 刪掉了」在檢查得到的資訊裡完全一樣，而後者是合法的狀態
    /// （編輯器把查不到的 uuid 標橘字，見 `SpaceTabs`）。
    ///
    /// 空白用 validator 自己那支 `containsWhitespace`（它認得全形空白與 NBSP，
    /// 與 jq 的 `\s` 對齊）——寫 `key.contains(" ")` 會放行一個全形空白的鍵。
    static func spaceKeyChecks(key: String, prefix: String) -> [LayoutProblem] {
        guard key.isEmpty || containsWhitespace(key) else { return [] }
        return [.structural(
            "\(prefix)：space uuid 不能是空的或含空白（「\(key)」）——"
                + "這棵樹永遠不會被套用，因為查表比的是當下可見那個 space 的 uuid"
        )]
    }
}
