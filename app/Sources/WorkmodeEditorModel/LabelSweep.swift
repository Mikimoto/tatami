import WorkmodeDomain

/// 規則編輯連動樹：刪掉一條規則就把引用它的窗格掃掉。
///
/// **為什麼不是「收集 `PanePath` 再逐個 `deletingPane`」**：刪掉一個窗格會讓同一棵樹裡
/// 其他路徑的 slot 索引失效，第二次刪就打在錯的節點上——而結果仍然是一棵合法的樹，
/// 沒有任何訊號。這裡一次遞迴重建，`panesAffectedByDeleting` 只用來出聲。
///
/// **不經過 `PaneNode`**：那個投影會把 `{"window": 7}` 變成 `{"window": "7"}` 並靜默
/// 刪掉使用者自己加的鍵（理由逐字寫在 `TreeEdit.swift:9-10`）。這裡整段在 `JSONValue`
/// 上工作，不認得的鍵原樣帶過。
extension LayoutDocument {
    /// 一棵樹拿掉所有引用 `label` 的窗格之後的樣子。nil ＝ 整棵沒了。
    ///
    /// 塌一層時**父節點自己的鍵一起丟**（`axis`、`ratio`、使用者的自訂鍵），與
    /// `TreeEdit.deletingPane`（`TreeEdit.swift:74`）的
    /// `JSONPath.set(root, parent.steps, to: sibling)` 逐字同語意——刻意對齐，
    /// 不是疏漏：兩條路徑產出不同形狀的樹，使用者會看到「拖掉」與「刪規則」
    /// 得到不一樣的版面。
    ///
    /// `children` 不是恰好兩個就原樣不動：validator 對那種節點自己會抱怨
    /// （`LayoutValidator.swift:331`），掃除不該替它猜。
    static func pruning(_ node: JSONValue, label: JSONValue) -> JSONValue? {
        guard case let .object(members) = node else { return node }
        if let window = members.first(where: { $0.key == "window" })?.value {
            return LayoutValidator.labelEquals(window, label) ? nil : node
        }
        guard case let .array(children)? =
            members.first(where: { $0.key == "children" })?.value,
            children.count == 2
        else { return node }
        let alive = children.compactMap { pruning($0, label: label) }
        switch alive.count {
        case 0:
            return nil
        case 1:
            return alive[0]
        default:
            return .object(members.map {
                $0.key == "children"
                    ? JSONMember(key: "children", value: .array(alive))
                    : $0
            })
        }
    }

    /// 這個 profile 底下每一棵樹：（角色, 分頁）。分頁 nil ＝ `trees.<角色>`。
    ///
    /// 回（角色, 分頁）而不是回路徑，是為了讓掃除與 `panesAffectedByDeleting`
    /// 走**同一個列舉**——`SweptPane` 從這兩段就組得出 `roleSteps`。抄兩份的那一份
    /// 遲早會少掃一種樹，而症狀是「掃過了但存不了檔」。
    ///
    /// **走原始 JSON 的鍵，不走 `canvasRoles`**（`LayoutDocument.swift:82`）：那支是
    /// `displays` ∪ `trees`，所以「只有 `spaceTrees`、沒有 `trees` 也沒有 `displays`」
    /// 的角色它列不出來——而那棵樹照樣被
    /// `LayoutValidatorSpaces.spaceTreeChecks` 檢查、照樣擋 ⌘S。
    func treeSlots(location: String, profile: String) -> [(role: String, space: String?)] {
        var out = roles(location: location, profile: profile)
            .map { (role: $0, space: String?.none) }
        guard case let .object(spaceRoles)? =
            root[location]?["profiles"]?[profile]?["spaceTrees"] else { return out }
        for role in spaceRoles {
            out += spaceTreeNames(location: location, profile: profile, role: role.key)
                .map { (role: role.key, space: String?.some($0)) }
        }
        return out
    }

    /// 「這個 label 在編輯前生效、編輯後不生效」的那些 profile。
    ///
    /// 這一句同時處理三件事，所以不需要另外寫規則：
    /// **精準**（別的 profile 清單沒變就不掃）、**取代語意**（自己有 `windows` 的
    /// profile 清單不會因為共用層少一條而變）、**跨地點**（另一個地點沒有那條規則）。
    ///
    /// 清單走 `LayoutQuery.effectiveLabels`（`LayoutQuery.swift:154`），它委派
    /// `LayoutValidator.effectiveLabels`——與 ⌘S 那道閘門是同一套。自己算一份的話，
    /// 症狀是「掃過了但存不了檔」，而兩邊的差別在畫面上看不出來。
    ///
    /// 回 nil 代表 jq 在那裡會 runtime error（`map(.label)` 撞到非物件的 entry）。
    /// 那種 profile **不掃**：清單算不出來就無從判斷誰失效了，而亂掃會刪掉版面。
    func profilesLosing(_ label: JSONValue, comparedTo after: LayoutDocument)
        -> [(location: String, profile: String)]
    {
        var out: [(location: String, profile: String)] = []
        for location in locations {
            for profile in profiles(in: location) {
                guard let was = LayoutQuery.effectiveLabels(location: location,
                                                            profile: profile, in: root),
                    let now = LayoutQuery.effectiveLabels(location: location,
                                                          profile: profile, in: after.root)
                else { continue }
                let had = was.contains { LayoutValidator.labelEquals($0, label) }
                let has = now.contains { LayoutValidator.labelEquals($0, label) }
                if had, !has {
                    out.append((location, profile))
                }
            }
        }
        return out
    }

    /// 一個 profile 的樹全部掃過。
    ///
    /// 逐棵 `set` 或 `delete` 是安全的：這些路徑最後一段全是**鍵**不是索引，
    /// 刪掉 `trees.main` 不會讓 `trees.second` 的路徑漂掉。
    func sweepingLabel(_ label: JSONValue, location: String,
                       profile: String) -> LayoutDocument
    {
        var edited = root
        for slot in treeSlots(location: location, profile: profile) {
            let path = SweptPane(location: location, profile: profile,
                                 role: slot.role, space: slot.space, slots: []).roleSteps
            guard let node = JSONPath.get(edited, path) else { continue }
            if let kept = Self.pruning(node, label: label) {
                edited = (try? JSONPath.set(edited, path, to: kept)) ?? edited
            } else {
                // **刪掉那個鍵，不是留 `{}`。** 空物件會讓
                // `LayoutValidator.splitNodeChecks`（`LayoutValidator.swift:309`）報
                // 「節點既沒有 window 也沒有 axis」，⌘S 被擋而畫面上沒有辦法修好它；
                // 而 `allTreeChecks` 走 `to_entries`，鍵不存在就完全不檢查。
                edited = (try? JSONPath.delete(edited, path)) ?? edited
            }
        }
        return LayoutDocument(root: edited)
    }

    /// 一棵樹把引用 `old` 的窗格改成 `new`。nil ＝ 這棵樹沒有引用到。
    ///
    /// **回 nil 是最佳化，不是守衛。** 把 `guard renamed.contains(where: { $0 != nil })`
    /// 換成 `guard !renamed.isEmpty` 是**全綠**的（2026-08-26 實測，942 條零失敗）
    /// ——底下那個重建是忠實的（`members.map` 只換 `children` 那一個成員），
    /// 所以重蓋一棵沒有引用到的樹會得到逐位元組相同的結果。它省下的只是工作量：
    /// 一份設定有幾十棵樹時，改一個 label 不必把每一棵都重蓋一遍。
    /// 不要因為它沒有測試就刪掉它，也不要為它硬寫一條測不到的斷言。
    static func renaming(_ node: JSONValue, from old: JSONValue,
                         to new: JSONValue) -> JSONValue?
    {
        guard case let .object(members) = node else { return nil }
        if let window = members.first(where: { $0.key == "window" })?.value {
            guard LayoutValidator.labelEquals(window, old) else { return nil }
            return .object(members.map {
                $0.key == "window" ? JSONMember(key: "window", value: new) : $0
            })
        }
        guard case let .array(children)? =
            members.first(where: { $0.key == "children" })?.value else { return nil }
        let renamed = children.map { renaming($0, from: old, to: new) }
        guard renamed.contains(where: { $0 != nil }) else { return nil }
        return .object(members.map { member in
            guard member.key == "children" else { return member }
            return JSONMember(key: "children",
                              value: .array(zip(children, renamed).map { $1 ?? $0 }))
        })
    }

    /// 一棵樹裡引用 `label` 的每個窗格，從根往下走的 slot 路徑。
    static func slots(referencing label: JSONValue, in node: JSONValue,
                      prefix: [Int] = []) -> [[Int]]
    {
        guard case let .object(members) = node else { return [] }
        if let window = members.first(where: { $0.key == "window" })?.value {
            return LayoutValidator.labelEquals(window, label) ? [prefix] : []
        }
        guard case let .array(children)? =
            members.first(where: { $0.key == "children" })?.value else { return [] }
        return children.enumerated().flatMap {
            slots(referencing: label, in: $0.element, prefix: prefix + [$0.offset])
        }
    }

    /// 一個 profile 的樹全部改過。與 `sweepingLabel` 走同一個 `treeSlots`。
    func renamingLabelInTrees(from old: JSONValue, to new: JSONValue,
                              location: String, profile: String) -> LayoutDocument
    {
        var edited = root
        for slot in treeSlots(location: location, profile: profile) {
            let path = SweptPane(location: location, profile: profile,
                                 role: slot.role, space: slot.space, slots: []).roleSteps
            guard let node = JSONPath.get(edited, path),
                  let renamed = Self.renaming(node, from: old, to: new)
            else { continue }
            edited = (try? JSONPath.set(edited, path, to: renamed)) ?? edited
        }
        return LayoutDocument(root: edited)
    }
}

public extension LayoutDocument {
    /// 刪掉這一列會連帶拿掉哪些窗格。**給出聲用，不用來刪**（理由在檔頭）。
    ///
    /// 收 scope 與 index 而不是收 label：這一支要與 `deletingRule` 做**完全相同**的
    /// 前後比對，收 label 的話兩邊會各算一次「哪些 profile 受影響」而漂移。呼叫端
    /// 也不必去拿原始的 `JSONValue`——`RuleRow.label` 是 `JQPrint.interpolate` 印出來
    /// 的字串，非字串 label 拿它去比會對不上。
    /// 先例是 `canSetRatio` 與 `settingRatio` 共用同一個 guard。
    func panesAffectedByDeleting(_ scope: RuleScope, index: Int) -> [SweptPane] {
        let rulePath = scope.windowsPath + [.index(index)]
        guard let label = JSONPath.get(root, rulePath + [.key("label")]) else { return [] }
        let deleted = rebuilt(try? JSONPath.delete(root, rulePath))
        guard deleted != self else { return [] }
        var out: [SweptPane] = []
        for hit in profilesLosing(label, comparedTo: deleted) {
            for slot in treeSlots(location: hit.location, profile: hit.profile) {
                let base = SweptPane(location: hit.location, profile: hit.profile,
                                     role: slot.role, space: slot.space, slots: [])
                guard let node = JSONPath.get(root, base.roleSteps) else { continue }
                out += Self.slots(referencing: label, in: node)
                    .map { SweptPane(location: hit.location, profile: hit.profile,
                                     role: slot.role, space: slot.space, slots: $0) }
            }
        }
        return out
    }
}
