import WorkmodeDomain

/// 一份 `layout.json` 的可編輯表示。
///
/// 內部持有 `JSONValue` 而不是自己的 struct：`JSONValue.object` 是有序的
/// `[JSONMember]`，`JSONWriter` 照來源鍵序輸出、數字保留字面值。若這裡改成自己的
/// 型別，存檔時整份會照那個型別的鍵序重印——一個 ratio 的改動變成整檔 diff，
/// 而且**這個型別不認得的鍵會直接消失**。
///
/// 底下全部是唯讀投影：每次從 `root` 算出來，不快取。整份設定 118 行，
/// 快取要處理失效而算一次不用。
///
/// 共同的規矩（與 `PaneNode` 同一條）：投影不得對 `LayoutValidator` 看得到的東西
/// 下不同的判斷。凡是「這個鍵算不算數」的問題一律照 validator 的判準，
/// 否則同一份檔會得到兩種互相矛盾的說法，而畫面上零訊號。
public struct LayoutDocument: Equatable, Sendable {
    public private(set) var root: JSONValue

    public init(root: JSONValue) {
        self.root = root
    }

    private var members: [JSONMember] {
        guard case let .object(members) = root else { return [] }
        return members
    }

    /// 最外層除了共用視窗總表以外的鍵都是地點，與 `LayoutValidator` 一致——
    /// 那個鍵名是 `LayoutQuery.reservedKey`（bash 的 `keys_unsorted - ["windows"]`），
    /// 全系統只有那一份宣告，抄第二份就沒有東西會在兩份分歧時出聲。
    ///
    /// **不是**用「有沒有 displays」分辨：那會讓一個缺 displays 的地點從側欄消失，
    /// 而 validator 正在對它報「缺 displays.main」——使用者看得到抱怨卻找不到要修的
    /// 東西。順序照來源，不排序：側欄的順序要與檔案一致，否則使用者對不起來。
    public var locations: [String] {
        members.map(\.key).filter { $0 != LayoutQuery.reservedKey }
    }

    public func profiles(in location: String) -> [String] {
        guard case let .object(profiles)? = root[location]?["profiles"] else { return [] }
        return profiles.map(\.key)
    }

    public func roles(location: String, profile: String) -> [String] {
        guard case let .object(trees)? =
            root[location]?["profiles"]?[profile]?["trees"] else { return [] }
        return trees.map(\.key)
    }

    /// 路徑不存在時回 `.empty` 而不是 nil：UI 只要畫得出「未指定」就夠，
    /// 不必替「沒有這個角色」與「這個角色是畸形節點」分兩種畫法。
    public func tree(location: String, profile: String, role: String) -> PaneNode {
        guard let node = root[location]?["profiles"]?[profile]?["trees"]?[role] else {
            return .empty
        }
        return PaneNode(node)
    }

    public func displayRoles(in location: String) -> [String] {
        guard case let .object(displays)? = root[location]?["displays"] else { return [] }
        return displays.map(\.key)
    }

    /// nil 只代表「沒定義」。非字串的 uuid（誤打成數字）照樣印出來而不是當成沒定義，
    /// 與 `LayoutQuery.locationDisplay` 的 `// empty` 同一條：假值只有 null 與 false。
    public func displayUUID(location: String, role: String) -> String? {
        guard let value = root[location]?["displays"]?[role] else { return nil }
        switch value {
        case .null, .bool(false): return nil
        default: return JQPrint.interpolate(value)
        }
    }

    /// 這個 profile 的 `spaceTrees` 有樹的角色，照來源鍵序。
    ///
    /// **不是 `roles(...)`**（那支讀 `trees`）：2026-08-30 之後編輯器只編
    /// `spaceTrees`，`trees` 是 `workmode` 那條路徑套的、編輯器碰不到的一半。
    public func spaceTreeRoles(location: String, profile: String) -> [String] {
        guard case let .object(roles)? =
            root[location]?["profiles"]?[profile]?["spaceTrees"] else { return [] }
        return roles.map(\.key)
    }

    /// 畫布要畫的格子：先是這個地點的 display 角色（照來源順序），再接上「這個
    /// profile 的 spaceTrees 有、但 displays 沒有」的角色（同樣照來源順序）。
    ///
    /// 這個集合運算放在 Model 而不是 view body：`WorkmodeEditorUI` 沒有任何測試
    /// 驗得到（`DependencyRuleTests` 的三條禁令就是為了讓判斷寫不進去），而漏掉
    /// 第二段的症狀正是「那棵樹在畫面上不存在」——零訊號。
    ///
    /// 為什麼第二段非有不可：見 `CanvasRole`。
    public func canvasRoles(location: String, profile: String) -> [CanvasRole] {
        let displays = displayRoles(in: location)
        let known = Set(displays)
        return displays.map { CanvasRole(role: $0, hasDisplay: true) }
            + spaceTreeRoles(location: location, profile: profile)
            .filter { !known.contains($0) }
            .map { CanvasRole(role: $0, hasDisplay: false) }
    }

    /// 這個 profile 上可以拖到畫布的 label。
    ///
    /// 與 `allRules` 不同：那張表是「檔案裡有哪些」，這一份是「**這個 profile 生效的
    /// 是哪些**」——profile 自己有 `windows` 就整塊取代。拿 `allRules` 當來源會讓
    /// 「自己有 windows」的 profile 列出共用層的 label，拖進去必定存不了檔。
    public func paletteLabels(location: String, profile: String) -> [LabelChoice] {
        (LayoutQuery.effectiveLabels(location: location, profile: profile, in: root) ?? [])
            .map(LabelChoice.init(value:))
    }

    /// 檔案裡的全部視窗規則，每一條帶著它寫在哪一層。
    ///
    /// **三層都要列。** 只讀最外層的話，寫在地點層或 profile 層的規則在編輯器裡
    /// 完全看不到——而畫布上那格的 label 正是從那些層來的，使用者看得到那個名字、
    /// 想查它怎麼匹配，表格裡卻沒有。使用者現在那份檔實測就有兩條在地點層
    /// （`office` 的一條、`home` 的一條），只讀最外層會漏掉三分之一。
    ///
    /// 這張表是「檔案裡有哪些」，不是「這個 profile 生效的是哪些」——後者是
    /// `LayoutQuery.windowRules` 的取代規則（見 `RuleScope` 的實測），要選定
    /// profile 才算得出來。
    ///
    /// 順序照檔案：共用 →（每個地點：它自己的 → 它每個 profile 的），地點與 profile
    /// 都照來源鍵序。不排序的理由與 `locations` 同一條：順序本身有意義（前面的規則
    /// 先認領視窗），而且使用者要對得回檔案。
    /// 索引**每層各自從 0 起算**（`enumerated` 收在每一層的 `rows` 上），不是在這張
    /// 扁平清單裡的位置：它的用途是組出 `scope.windowsPath + [.index(index)]`，
    /// 那條路徑指的是那一層的 `windows` 陣列，跨層累加的計數器對不回檔案。
    public var allRules: [ScopedRule] {
        var out = Self.rows(at: root[LayoutQuery.reservedKey])
            .enumerated().map { ScopedRule(scope: .shared, index: $0.offset, row: $0.element) }
        for location in locations {
            let value = root[location]
            out += Self.rows(at: value?[LayoutQuery.reservedKey])
                .enumerated().map {
                    ScopedRule(scope: .location(location), index: $0.offset, row: $0.element)
                }
            for profile in profiles(in: location) {
                let scope = RuleScope.profile(location: location, profile: profile)
                out += Self.rows(at: value?["profiles"]?[profile]?[LayoutQuery.reservedKey])
                    .enumerated().map {
                        ScopedRule(scope: scope, index: $0.offset, row: $0.element)
                    }
            }
        }
        return out
    }

    /// 每一層各一列的清點，順序與 `allRules` 的分層順序相同：共用 →（每個地點：
    /// 它自己的 → 它每個 profile 的）。**每個地點與每個 profile 都會有一列**，
    /// 沒宣告的 `declaresRules` 是 false——這一支問的不是「有哪些列」而是
    /// 「哪一層宣告了什麼」，所以不能從 `allRules` group 出來（那裡面沒有列的
    /// 層根本不存在，而「宣告了卻沒有列」正是要抓的東西，見 `RuleLayer`）。
    public var ruleLayers: [RuleLayer] {
        var out = [Self.layer(scope: .shared, value: root[LayoutQuery.reservedKey])]
        for location in locations {
            let value = root[location]
            out.append(Self.layer(scope: .location(location),
                                  value: value?[LayoutQuery.reservedKey]))
            for profile in profiles(in: location) {
                out.append(Self.layer(
                    scope: .profile(location: location, profile: profile),
                    value: value?["profiles"]?[profile]?[LayoutQuery.reservedKey]
                ))
            }
        }
        return out
    }

    /// 有沒有哪個 profile 層宣告了 `windows`。有的話那個 profile 底下共用層與地點層
    /// 那幾列一條都不生效，UI 要提示。**條件是「宣告了」而不是「有列」**：
    /// `"windows": []` 照樣取代，而它在 `allRules` 裡一列都沒有。
    ///
    /// 兩個條件合起來的地方在 Model 不在 view body：`ruleLayers` 對每個 profile 都
    /// 產一列，UI 若寫成 `contains(where: \.scope.isProfileScoped)`，那行提示會
    /// 永遠出現，而 `WorkmodeEditorUI` 沒有任何測試驗得到。
    public var anyProfileLayerDeclaresRules: Bool {
        ruleLayers.contains { $0.scope.isProfileScoped && $0.declaresRules }
    }

    /// 寫了空 `windows` 而**會把前面兩層整組取代掉**的 profile 層。
    ///
    /// **只有 profile 層。** 共用層與地點層之間永遠是疊加（`ScopedRule.swift`
    /// 檔頭的實測），所以它們寫空陣列等於什麼都沒做——把它們也算進來的那個版本
    /// 讓使用者看到「有 2 層…取代成零條」，而實測他那六條規則全部生效
    /// （2026-08-29）。一句對一半的警示比不警示更糟：它會叫人去改一個沒問題的地方。
    public var profileLayersReplacingWithNothing: [RuleLayer] {
        ruleLayers.filter {
            $0.scope.isProfileScoped && $0.declaresRules && $0.declaresArray
                && $0.ruleCount == 0
        }
    }

    /// `windows` 寫了一個不是陣列的值的層。**與層無關**：`windows_for` 對它是
    /// rc=5 的硬錯（`RuleLayer` 檔頭的實測），也就是這份檔存得下去、`workmode`
    /// 跑起來會壞，而表格對那一層一列都不畫。`validate` 一樣 rc=0。
    public var layersWithNonArrayRules: [RuleLayer] {
        ruleLayers.filter { $0.declaresRules && !$0.declaresArray }
    }

    private static func layer(scope: RuleScope, value: JSONValue?) -> RuleLayer {
        RuleLayer(scope: scope, declaresRules: declares(value),
                  ruleCount: rows(at: value).count,
                  declaresArray: isArray(value))
    }

    /// 宣告的值是不是陣列。`declares` 為真而這裡為假 ＝ 那一層寫了一個
    /// `windows_for` 吞不下的值。
    private static func isArray(_ value: JSONValue?) -> Bool {
        if case .array = value {
            return true
        }
        return false
    }

    /// jq 的 `//` 判假：只有 null 與 false，缺鍵同理。**不是**看鍵在不在——
    /// `"windows": null` 的效果與缺鍵逐字相同（實測），照鍵存在算會讓一份完全
    /// 正常的設定被指控「宣告了卻看不到」。
    private static func declares(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null, .bool(false): return false
        default: return true
        }
    }

    /// 不是陣列就零列。**這不是與產品路徑同一個結果**：`LayoutQuery.windowRules`
    /// 對非陣列是 runtime error（實測 `__diff windows_for` 回 **rc=5**），而這一層
    /// 沒有「中止」可言——投影一旦丟出去，整個表格就畫不出來。所以刻意分歧，代價
    /// 由 `ruleLayers` 補：那一層的 `declaresRules` 為真、`ruleCount` 為 0，UI 據此
    /// 出聲。少了那句話這裡就真的是靜默的——`__diff validate` 對非陣列實測 rc=0。
    private static func rows(at value: JSONValue?) -> [RuleRow] {
        guard case let .array(items)? = value else { return [] }
        return items.map(row)
    }

    /// 不丟掉任何一列。`__diff validate` 實測四組：兩筆缺 label 的**物件** entry 會被
    /// 算進 label 清單並報「windows 的 label 重複（）」rc=1；只要混進一筆**純量** entry
    /// （`"糟糕"`），整份設定就變成 rc=0 零輸出，連同一份檔裡不相關的違規（樹指到
    /// 不存在的 label）也一起被吞掉——成因是 `jqMapLabel` 只收物件與 null，其餘回 nil
    /// 讓整個串流中止（`LayoutValidatorJQ.swift:104-106`）。
    /// 所以：物件與 null 的畸形 entry validator 還看得到，純量 entry 它完全不出聲，
    /// 這張表格是使用者唯一看得到那一列的地方。
    /// 非字串的值走 `JQPrint.interpolate`，與 validator 的訊息用同一支。
    private static func row(_ value: JSONValue) -> RuleRow {
        let match = value["match"]
        var fallbackKind: String?
        var fallbackValue: String?
        // 看鍵存不存在，不看它的形狀：`"fallback": 7` 印成 null／null 而不是「沒有
        // fallback」——後者讓那個要修的東西從表格上消失，與畸形的規則不能丟掉同一個理由。
        // bash 在同一條路徑上印的是 `-` 佔位符，出處是 `windows_for`
        // （`bash-oracle:245-253`，理由寫在 `:237`：讓 `read` 的欄位數固定），
        // 不是 `report_rules`（`:664-676`，那支印的是 label 加 yabai frame，沒有
        // fallback 欄）。這裡刻意不照抄：表格分得出「沒有」與「壞掉」，那條輸出分不出。
        if let fallback = value["fallback"] {
            fallbackKind = JQPrint.interpolate(element(fallback, 0))
            fallbackValue = JQPrint.interpolate(element(fallback, 1))
        }
        return RuleRow(label: JQPrint.interpolate(value["label"] ?? .null),
                       matchKind: JQPrint.interpolate(element(match, 0)),
                       matchValue: JQPrint.interpolate(element(match, 1)),
                       fallbackKind: fallbackKind, fallbackValue: fallbackValue,
                       // 與 fallback 同樣看鍵存不存在。`"launch": 7` 投影成 `"7"`
                       // 而不是「沒有」——要修的東西不該從表格上消失。
                       launch: value["launch"].map(JQPrint.interpolate))
    }

    /// `.[n]`：越界、不是陣列、根本不存在都是 `null`，與 jq 一致
    /// （jq 對非陣列是 runtime error，但這一層沒有「中止」可言，印 null 才畫得出來）。
    private static func element(_ value: JSONValue?, _ index: Int) -> JSONValue {
        guard case let .array(items)? = value, index < items.count else { return .null }
        return items[index]
    }
}
