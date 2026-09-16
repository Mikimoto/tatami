import WorkmodeDomain

// 沒有人可以問「這個視窗要叫什麼」時（選單列，`Interaction.automatic`）自己推。
//
// 自成一檔的理由是 `file_length`（上限 400，`.swiftlint.yml` 的檔頭明文禁止調參數）：
// `SaveLayout.swift` 已經 367 行、`SaveLayoutParts.swift` 359 行，這一組放不進任何
// 一個。先例是 `SpaceTargets.swift`。

extension SaveLayout {
    /// 判斷全在 Domain（`AutoWindowName`），這裡只接線、記帳與發事件。
    ///
    /// 這一支與 `askForNames` 的分工是「誰決定名字」，不是「要不要問」：那一支的
    /// 答案來自 tty，這一支來自推導，而兩支吐同一個 `Named` 交給同一段組樹與寫檔。
    ///
    /// 推不出身分的**要說出來**：不說的話使用者會以為那個視窗存進去了，而下次
    /// 套用時它不會出現——那是查不出來的。
    func invent(unnamed rects: [JSONValue], catalog: String, dump: String,
                appRules: Set<String>) -> Named
    {
        var newRules: [NewRule] = []
        var addMap: [String: String] = [:]
        var taken = Set(labels(of: catalog).split(separator: "\n").map(String.init))
        var appRules = appRules
        var skipped = 0

        for rect in rects where renderRaw(rect["label"] ?? .null).isEmpty {
            let id = renderRaw(rect["id"] ?? .null)
            let app = renderRaw(rect["app"] ?? .null)
            guard let derived = AutoWindowName.derive(id: id, app: app, dump: dump,
                                                      taken: taken,
                                                      existingAppRules: appRules)
            else {
                skipped += 1
                continue
            }
            newRules.append(NewRule(rule: derived.rule, app: app))
            addMap[id] = derived.label
            remember(derived, app: app, taken: &taken, appRules: &appRules)
            reporter.report(.saveRuleInvented(label: derived.label,
                                              match: matchText(of: derived.rule)))
        }
        if skipped > 0 {
            reporter.report(.saveSkippedUnnamed(count: skipped))
        }
        // `invented` 就是 `addMap` 的鍵：同一個地方建，兩者不會分岔。
        return Named(rules: newRules, labels: addMap, invented: Set(addMap.keys))
    }

    /// 剛加的這一條要讓**同一次存檔**後面的視窗看得見。兩筆記帳擋的是兩件事：
    ///
    /// * `taken`：兩個各只有一個分頁的 Safari 視窗會各拿到一條規則，少了它兩條
    ///   同名，`LayoutValidator` 的重複 label 檢查會擋下整次存檔（`.rejected`）。
    /// * `appRules`：兩個同 app 的無名視窗，第二個不該再拿到一條一模一樣的
    ///   `["app", X]`——那兩條誰認到哪個視窗由執行時的順序決定，於是版面會換位置。
    ///
    /// 收 `app` 而不是從 `match[1]` 讀回來：`AutoWindowName.derive` 建的就是
    /// `["app", app]`，多繞一手只是多一個會與它分岔的地方。
    private func remember(_ derived: AutoWindowName.Derived, app: String,
                          taken: inout Set<String>, appRules: inout Set<String>)
    {
        taken.insert(derived.label)
        if case let .array(match)? = derived.rule["match"], match.count >= 2,
           case .string("app") = match[0]
        {
            appRules.insert(app)
        }
    }

    /// 已經有 `["app", X]` catch-all 的那些 app。
    ///
    /// 讀的是**這個 location／profile 生效的那一份**：`LayoutQuery.windowRules`
    /// 自己處理「profile 有 `windows` 時整塊取代共用層與地點層」
    /// （`LayoutQuery.swift:113-122`）。三層的聯集會把一份根本不生效的清單算進來，
    /// 而那個方向的錯是靜默的——視窗被判成「已經有人認得它的 app」於是推不出規則，
    /// 症狀是那一格還是空的。
    ///
    /// **只看 `match`，與 `RulePlacement.isCatchAll` 同一個定義**（`fallback` 不算，
    /// 理由寫在那支的 doc）。兩邊分岔的話沒有任何東西會發現。已知的一處寬窄差異：
    /// 這裡要求 `matchValue` 是字串，`isCatchAll` 也是——非字串的 `match[1]`
    /// 兩邊都不算 catch-all。
    func existingAppRules(location: String, profile: String,
                          in config: JSONValue) -> Set<String>
    {
        var out: Set<String> = []
        // 丟出來的錯照 `LayoutReading.windowRulesText` 的處置：jq 那側是邊算邊印的，
        // 中止之前送出來的那幾條算數。
        try? LayoutQuery.windowRules(location: location, profile: profile,
                                     in: config)
        { rule in
            guard case .string("app") = rule.matchKind,
                  case let .string(value) = rule.matchValue else { return }
            out.insert(value)
        }
        return out
    }

    /// 事件裡那一段：`app Zed`、`url-contains https://meet.google.com/abc`。
    /// 只給人看，所以不走 `JQPrint` 的引號。
    private func matchText(of rule: JSONValue) -> String {
        guard case let .array(match) = rule["match"] ?? .null, match.count >= 2 else {
            return ""
        }
        return renderRaw(match[0]) + " " + renderRaw(match[1])
    }
}

// MARK: - 自動命名的退路

extension SaveLayout {
    /// 把矩形切成樹；切不開就把**這一輪自己命名的**那些拿掉再試一次。
    ///
    /// 自動命名讓陌生視窗變成「有名字的」，於是它開始參與幾何
    /// （`SaveLayoutParts.onlyNamed` 不再濾掉它）。一個**部分重疊**的隨手擺的視窗
    /// 因此會讓整個 space 存不下來——而 2026-09-08 使用者抱怨的正是那件事
    /// （「一個隨手擺的 Finder 視窗就讓那個 space 存不下來」）。
    /// 2026-09-10 使用者裁決：丟掉這一輪自己命名的那些，其餘照存，並說一句話。
    ///
    /// **只丟自己推的**。使用者在終端機親手回答過名字的視窗不在 `invented` 裡：
    /// 他剛剛才說了要存它，靜默扔掉是在推翻他的回答；那條路照舊整個角色不存
    /// （`saveRoleNotSplittable`），他看得見、改得動。
    ///
    /// **丟掉的規則留在設定裡**（呼叫端的 `named.rules` 不動）。三個理由：
    /// `LayoutValidator` 只檢查「樹的 label 都在生效清單裡」這一個方向
    /// （`LayoutValidator.swift:281`，反向不查），所以沒人引用的規則無害；
    /// 同一個 label 可能在**別的角色或別的 space** 上切得開，全域拿掉會弄壞那些；
    /// 而下次那個視窗沒有重疊時，那條規則就直接認得它了。
    ///
    /// 回 nil ＝ 拿掉之後**還是**切不開（或本來就沒有東西可丟），呼叫端照舊報
    /// `saveRoleNotSplittable`。那時**不報**被丟掉的視窗：這個角色一棵樹都沒存，
    /// 再說「某某沒能存進去」是把同一件事講兩次，而且會讓人以為其餘的存進去了。
    func splittable(_ rects: JSONValue, named: Named, role: String) -> JSONValue? {
        if let tree = try? RectTree.fromRects(rects), tree != .null {
            return tree
        }
        let items = rectArray(rects)
        let dropped = items.filter { named.invented.contains(renderRaw($0["id"] ?? .null)) }
        let kept = items.filter { !named.invented.contains(renderRaw($0["id"] ?? .null)) }
        guard !dropped.isEmpty, !kept.isEmpty,
              let tree = try? RectTree.fromRects(.array(kept)), tree != .null
        else { return nil }
        for rect in dropped {
            reporter.report(.saveWindowLostToOverlap(role: role,
                                                     label: renderRaw(rect["label"] ?? .null)))
        }
        return tree
    }
}
