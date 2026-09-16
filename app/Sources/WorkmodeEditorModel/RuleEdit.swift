import WorkmodeDomain

/// 表格上編得動的六個欄位。`fallback` 那兩個在檔案裡是同一個陣列的兩個位置，
/// 拆成兩個 case 是因為使用者一次只改一格。
public enum RuleField: Equatable, Sendable {
    case label
    case matchKind
    case matchValue
    case fallbackKind
    case fallbackValue
    /// `--launch` 要開哪個 app。與其他五個不同：**打成空字串是刪掉那個鍵**，
    /// 見 `settingRuleField`。
    case launch
}

/// 規則的六個編輯動作，全部是 `LayoutDocument → LayoutDocument` 的純函式。
///
/// **不能「把一列寫回去」。** `RuleRow` 是有損投影（非字串走 `JQPrint.interpolate`，
/// 所以 `"label": 7` 投影成 `"7"`、缺 label 投影成 `"null"`），而且它只認得
/// `label`／`match`／`fallback`／`launch` 四個鍵——整列重建會把使用者的 `7` 改成 `"7"`，
/// 並把投影看不見的鍵**靜默刪掉**。所以每個動作都表示成「把
/// `scope.windowsPath + [.index(index)] + …` 這條路徑的值設成 X」，其餘位元組由
/// `JSONPath` 原樣帶過（`editingDoesNotSwallowKeysTheProjectionCannotSee` 釘著）。
///
/// **設欄位一律寫 `.string(…)`**：使用者在表格裡打的就是文字，替他猜 `7` 是數字
/// 還是字串會讓同一格的輸入時而是數字時而是字串。
///
/// **路徑走不通就回傳原文件不變。** 路徑來自編輯器自己剛投影出來的 `allRules`，
/// 走不通代表投影與文件不同步——那是 bug，但這一層吞掉它：編輯器當掉的話使用者
/// 剛打的字連同整個 session 一起沒了，而少一次編輯他看得見、可以再按一次。
/// `JSONPath` 那側刻意 throw（不像 jq `setpath` 會補洞），要不要吞是呼叫端的決定，
/// 這裡就是那個呼叫端。
public extension LayoutDocument {
    /// 新增規則的預設 label 字根。`auto` 那條保留字規則管的是地點與 profile 名，
    /// 不管 label；label 也可以含空白（兩者 2026-08-19 用 `__diff validate` 實測）。
    private static let newRuleStem = "新規則"

    func settingRuleField(_ scope: RuleScope, index: Int, field: RuleField,
                          to text: String) -> LayoutDocument
    {
        let rulePath = scope.windowsPath + [.index(index)]
        switch field {
        case .label:
            // 改 label 與刪規則是同源的破壞：樹裡還是舊名字，⌘S 被擋，訊息一樣。
            // 差別是這一半**無損**——把樹裡的舊名字換成新的，版面完整保留。
            // 判準與刪除共用 `profilesLosing`（舊 label 不再生效的那些 profile）。
            let old = JSONPath.get(root, rulePath + [.key("label")])
            let renamed = setting(rulePath + [.key("label")], to: .string(text))
            guard let old, renamed != self else { return renamed }
            var out = renamed
            for hit in profilesLosing(old, comparedTo: renamed) {
                out = out.renamingLabelInTrees(from: old, to: .string(text),
                                               location: hit.location,
                                               profile: hit.profile)
            }
            return out
        case .matchKind:
            return settingPairSlot(rulePath, key: "match", slot: 0, to: text)
        case .matchValue:
            return settingPairSlot(rulePath, key: "match", slot: 1, to: text)
        case .fallbackKind:
            return settingPairSlot(rulePath, key: "fallback", slot: 0, to: text)
        case .fallbackValue:
            return settingPairSlot(rulePath, key: "fallback", slot: 1, to: text)
        case .launch:
            // **空字串是刪掉整個鍵**，不是寫 `"launch": ""`。那兩者在執行時等價
            // （`LaunchableApps.named` 對空字串往下推回 `match`），所以留一個空的
            // 只是檔案裡一個看不出效果的鍵——而表格是使用者唯一能把它清掉的地方。
            // 其他五個欄位不這樣做：`match` 的兩格是陣列的位置，刪掉會讓陣列長度
            // 不是 2 而產品路徑讀不到 `match[1]`。
            let launchPath = rulePath + [.key("launch")]
            guard !text.isEmpty else {
                return rebuilt(try? JSONPath.delete(root, launchPath))
            }
            return setting(launchPath, to: .string(text))
        }
    }

    /// 兩個位置都給空字串而類型給 `app`：理由與 `insertingRule` 的 `match` 同一條
    /// ——未知的類型 `validate` 不擋（實測 rc=0），所以它是留給使用者的陷阱而不是
    /// 會被攔下來的錯字。
    func addingFallback(_ scope: RuleScope, index: Int) -> LayoutDocument {
        setting(scope.windowsPath + [.index(index), .key("fallback")],
                to: .array([.string("app"), .string("")]))
    }

    /// 整個鍵拿掉，不是設成 `null`：`RuleRow` 看的是**鍵存不存在**
    /// （`LayoutDocument.row`），設成 null 那一列會變成「有 fallback 但兩格是 null」。
    func removingFallback(_ scope: RuleScope, index: Int) -> LayoutDocument {
        let path = scope.windowsPath + [.index(index), .key("fallback")]
        return rebuilt(try? JSONPath.delete(root, path))
    }

    /// `to` 是**移除之後**的目標索引，與 `JSONPath.move` 同一個語意。
    func movingRule(_ scope: RuleScope, from: Int, to target: Int) -> LayoutDocument {
        rebuilt(try? JSONPath.move(root, scope.windowsPath, from: from, to: target))
    }

    /// 刪一列規則，並把引用它的窗格從樹裡掃掉。
    ///
    /// **連動塞在這裡而不是交給呼叫端串**：忘了串的症狀是使用者刪完規則、⌘S 被擋，
    /// 而錯誤訊息指著一棵他沒動過的樹。`LabelSweep.swift` 檔頭有整套理由。
    ///
    /// 讀不出 `label`（畸形 entry，例如 `windows` 裡放的是純量）就只刪那一列——
    /// 那種列本來就每個編輯動作都走不通，不該讓刪除也跟著失敗。
    func deletingRule(_ scope: RuleScope, index: Int) -> LayoutDocument {
        let rulePath = scope.windowsPath + [.index(index)]
        let label = JSONPath.get(root, rulePath + [.key("label")])
        let deleted = rebuilt(try? JSONPath.delete(root, rulePath))
        guard let label, deleted != self else { return deleted }
        var out = deleted
        for hit in profilesLosing(label, comparedTo: deleted) {
            out = out.sweepingLabel(label, location: hit.location, profile: hit.profile)
        }
        return out
    }

    /// 接在那一層的尾端。**預設 label 不能固定也不能留空**：`validate` 對 label
    /// 重複回 rc=1，而且算的是合併後的生效集合（實測：共用層一條 `A` 加地點層一條
    /// `A` 就紅，兩條空 label 也算重複）。固定字串的話使用者按第二次新增就撞名，
    /// 症狀是存檔被閘門擋下而畫面上看不出為什麼。
    func insertingRule(_ scope: RuleScope) -> LayoutDocument {
        insertingRule(scope, label: Self.newRuleStem, match: ("app", ""))
    }

    /// 帶著值新增（「從視窗建立」走這一支）。
    ///
    /// `match` 是一對而不是 `[String]`：陣列長度不是 2 的話寫出來的規則
    /// `LayoutQuery` 讀不到 `match[1]`（`LayoutQuery.swift:129`），而型別擋得掉那件事。
    ///
    /// **`label` 是想要的字根不是最終值**：被用掉就變成 `Zed 2`、`Zed 3`……
    /// 與無參數那支共用同一支挑選器，所以「從視窗建立」與「手動新增」不會有一個
    /// 避開撞名、另一個不避。
    ///
    /// **不給 `fallback` 鍵**（與無參數那支同一條）：`nil` 與空字串在檔案裡是兩件事。
    func insertingRule(_ scope: RuleScope, label: String,
                       match: (kind: String, value: String)) -> LayoutDocument
    {
        guard case let .array(items)? = JSONPath.get(root, scope.windowsPath) else {
            return self
        }
        let entry = JSONValue.object([
            JSONMember(key: "label", value: .string(unusedLabel(basedOn: label))),
            JSONMember(key: "match", value: .array([.string(match.kind),
                                                    .string(match.value)])),
        ])
        return rebuilt(try? JSONPath.insert(root, scope.windowsPath,
                                            at: items.count, entry))
    }

    /// 這一層收不收得下新規則。**判斷放這裡不放 view**：`WorkmodeEditorUI` 那層零測試
    /// （`DependencyRuleTests` 的三條禁令就是為了讓判斷寫不進去），而這個條件寫錯的
    /// 症狀是「按鈕永遠可按但按了沒反應」或「永遠不能按」，畫面上分不出來。
    ///
    /// **沒有 `windows` 陣列的層回 false，而不是幫它建一個。** 兩種失敗不對稱：在
    /// profile 層建出這個鍵會把語意從「共用 ++ 地點」翻成「只有這個 profile 的清單」
    /// （實測見 `RuleScope` 的表），等於一次按鈕就靜默停掉使用者現有全部生效規則。
    /// 明擺著拒絕只是輕微不便。要讓某個 profile 改成覆寫，那是另一個明確的動作。
    ///
    /// **phase 2c 之後這個 false 分支到得了了。** `RuleTableView` 的新增按鈕現在是一個
    /// 列出 `ruleLayers` 每一層的選單，而那份清單包含沒有宣告 `windows` 的 profile 層
    /// ——使用者那份設定三個 profile 全都沒有，所以選單一打開就有三個灰的項目。
    /// 這一段原本寫「目前的 UI 到不了」，那句話從 `a799bb9` 起為假。
    /// `RuleTableView.refusal(for:)` 的三句訊息也在同一個 commit 之後全部到得了。
    ///
    /// 條件與 `insertingRule` 的 guard 是同一個，抄兩份會漂移，所以
    /// `insertingAgreesWithCanInsertRule` 把兩支綁在一起驗。
    func canInsertRule(_ scope: RuleScope) -> Bool {
        if case .array? = JSONPath.get(root, scope.windowsPath) {
            return true
        }
        return false
    }

    // MARK: - 內部

    private func setting(_ path: [JSONPath.Step], to value: JSONValue) -> LayoutDocument {
        rebuilt(try? JSONPath.set(root, path, to: value))
    }

    /// `match`／`fallback` 是兩元素陣列時只換被指到的那一格（另一格的字面值原樣留著）；
    /// **不是的時候先正規化成兩元素再設，不要拒絕編輯**——畸形的列正是使用者開編輯器
    /// 要修的那些，編不動的話他只剩下去改檔案這條路。
    ///
    /// **正規化是兩元素，所以三元素以上會被截掉尾巴**（實測 `["app","X","額外"]` 改值
    /// 之後是 `["app","Y"]`；`editingRepairsAMalformedMatch` 釘著）。這與檔頭那句
    /// 「其餘位元組原樣帶過」有出入，寫在這裡而不是假裝沒有：那句話講的是**這一列的
    /// 其他鍵**，管不到被指名的這個陣列裡多出來的元素。
    ///
    /// 截斷算修復不算破壞的理由是產品路徑讀不到第三個元素——`LayoutQuery.windowRules`
    /// 照 jq 的 `[.label, .match[0], .match[1], …]` 只取 `[0]` 與 `[1]`
    /// （`LayoutQuery.swift:129-130`），表格也只有兩格。留著它等於讓一個沒有任何
    /// 消費端的欄位跟著一條剛被修好的規則走，而下一個看到檔案的人會以為它有意義。
    private func settingPairSlot(_ rulePath: [JSONPath.Step], key: String,
                                 slot: Int, to text: String) -> LayoutDocument
    {
        let pairPath = rulePath + [.key(key)]
        let current = JSONPath.get(root, pairPath)
        if case let .array(items)? = current, items.count == 2 {
            return setting(pairPath + [.index(slot)], to: .string(text))
        }
        var repaired = Self.twoElements(current)
        repaired[slot] = .string(text)
        return setting(pairPath, to: .array(repaired))
    }

    /// 取得到的那幾格留著（使用者只是漏了一格，不必連帶洗掉另一格），取不到的補空字串。
    private static func twoElements(_ value: JSONValue?) -> [JSONValue] {
        guard case let .array(items)? = value else { return [.string(""), .string("")] }
        return [items.first ?? .string(""),
                items.count > 1 ? items[1] : .string("")]
    }

    /// 第一個沒被用過的 `<字根>`／`<字根> 2`／`<字根> 3`…
    ///
    /// **從所有層蒐集**（`allRules` 走共用、每個地點、每個地點的每個 profile），
    /// 因為重複檢查算的是合併後的集合，只避開同一層的還是會撞。
    /// 比對的是 `RuleRow.label`，也就是 `JQPrint.interpolate` 之後的字串——它比
    /// jq 的 `==` 寬（數字 `7` 與字串 `"7"` 在這裡算同一個、在 validate 眼裡不算），
    /// 而寬的那個方向只會讓候選往後跳一號，不會漏掉真的撞名。
    ///
    /// **字根是參數**：手動新增給「新規則」，從視窗建立給 app 名稱。抄第二份遞增
    /// 邏輯的那一份不會有東西驗它。
    private func unusedLabel(basedOn stem: String) -> String {
        let used = Set(allRules.map(\.row.label))
        var candidate = stem
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(stem) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// 六個動作共用的收尾：`JSONPath` 丟出來（呼叫端的 `try?` 已經把它變成 nil）
    /// 就當作投影與文件不同步，回原文件。
    ///
    /// 沒有 `private`：`TreeEdit.swift` 共用同一支。抄第二份的那一份不會有東西驗它，
    /// 而它的內容正是「編輯失敗就回原文件」這個約定（C8）。
    func rebuilt(_ edited: JSONValue?) -> LayoutDocument {
        guard let edited else { return self }
        return LayoutDocument(root: edited)
    }
}
