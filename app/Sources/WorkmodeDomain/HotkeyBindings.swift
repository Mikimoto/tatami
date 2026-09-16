/// 一條綁定：一組鍵、一個動作、一個可以關掉它的開關。
public struct HotkeyBinding: Hashable, Sendable {
    public let hotkey: Hotkey
    public let action: HotkeyAction
    /// 關掉的綁定留在檔案裡但不註冊。刪掉與關掉是兩件事——關掉之後
    /// 使用者還看得到它本來綁什麼，而那正是「這個鍵怎麼沒反應」的答案。
    public let isEnabled: Bool

    public init(hotkey: Hotkey, action: HotkeyAction, isEnabled: Bool = true) {
        self.hotkey = hotkey
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// `hotkeys.json` 的整份內容：綁定加上 float 清單。
///
/// 兩個欄位一起讀寫而不是各自一支函式，理由是**編輯器的存檔**：它寫回的是
/// `write` 的輸出，read/write 少收哪個欄位，那個欄位就會在使用者按 ⌘S 的
/// 那一刻無聲消失。
public struct HotkeyDocument: Equatable, Sendable {
    public var bindings: [HotkeyBinding]
    /// 滑鼠拖曳（fn ＋ 拖曳）。取代 yabai 最後一個還在做的工作。
    public var mouse: MouseSettings
    /// balance／rotate／gaps 跳過的 app 名（`app` 欄位的精確比對）。
    /// 對應 yabai 的 `manage=off`：那邊是「不要 tile 我」的退出，這邊是
    /// 「這三個掃整個 space 的動作別碰我」——`--space` 不在此列，樹本來就是
    /// 明確加入的。
    public var floatApps: [String]
    /// 每台螢幕的格線設定（display uuid → 格數與間距）。空的＝全部用預設。
    public var grids: [String: GridConfig]
    /// 位置庫：面板第二個模式那一面縮圖牆，每一格是一個存下來的視窗位置。
    public var zones: [GridZone]

    public init(bindings: [HotkeyBinding], floatApps: [String],
                mouse: MouseSettings = .defaults,
                grids: [String: GridConfig] = [:],
                zones: [GridZone] = [])
    {
        self.bindings = bindings
        self.floatApps = floatApps
        self.mouse = mouse
        self.grids = grids
        self.zones = zones
    }
}

/// `hotkeys.json` 與 `[HotkeyBinding]` 之間的投影。
///
/// **不放進 `layout.json`**：那個檔有 `LayoutValidator` 與 2257 組凍結語料在守，
/// 多一個 top-level 鍵要動 validator，而換來的只是少一個檔案。
public enum HotkeyBindings {
    /// 解得出來的收下，解不出來的**逐條說出來**再跳過。
    ///
    /// 整份拒絕會讓一個打錯的字關掉全部快捷鍵；安靜跳過則讓那一條變成「按了沒反應」，
    /// 而那是這個功能最難查的失效樣子。所以兩者都不做：跳過並回報。
    public static func read(_ json: JSONValue) -> (document: HotkeyDocument, problems: [String]) {
        guard case let .object(members) = json, let rows = bindingRows(in: json)
        else {
            return (HotkeyDocument(bindings: [], floatApps: []),
                    ["hotkeys.json 沒有 bindings 陣列"])
        }
        var bindings: [HotkeyBinding] = []
        var problems: [String] = []
        for (index, row) in rows.enumerated() {
            switch decode(row) {
            case let .accepted(binding): bindings.append(binding)
            case let .rejected(reason): problems.append("第 \(index + 1) 條：\(reason)")
            }
        }
        let mouse = MouseSettings.read(members.first(where: { $0.key == "mouse" })?.value)
        if let problem = mouse.problem {
            problems.append(problem)
        }
        let parsed = grids(in: members)
        problems += parsed.problems
        let library = zones(in: members)
        problems += library.problems
        return (HotkeyDocument(bindings: bindings, floatApps: floatApps(in: members),
                               mouse: mouse.settings, grids: parsed.table,
                               zones: library.list), problems)
    }

    /// 這份 JSON 是不是一份 hotkeys 文件——最外層是物件，而且它有一個
    /// `bindings` 陣列。
    ///
    /// 存在的理由是 `read` **分不出**兩件事：一份沒有綁定的文件，與一份根本不是
    /// hotkeys 文件的 JSON（把 `bindings` 打成 `binding`、或最外層是個陣列），
    /// 兩者它都回一份空文件加同一句 problem。只是**讀**的話那個混淆無害
    /// （少列幾條，而那句話就在旁邊）；要拿讀出來的東西**覆寫**回去就不是了
    /// ——把使用者整份設定換成一份空的，零訊息。所以覆寫那條路先問這一句。
    ///
    /// 與 `read` 共用同一支 `bindingRows`：抄成兩份的話，兩邊對「什麼算 hotkeys
    /// 文件」漂移的那一刻，`canSave` 守的就不是 `read` 實際會做的事了。
    public static func isDocument(_ json: JSONValue) -> Bool {
        bindingRows(in: json) != nil
    }

    private static func bindingRows(in json: JSONValue) -> [JSONValue]? {
        guard case let .object(members) = json,
              case let .array(rows)? = members.first(where: { $0.key == "bindings" })?.value
        else { return nil }
        return rows
    }

    /// `float` 清單：balance／rotate／gaps 三個動作跳過的 app 名（精確比對，
    /// 不是 regex——退役前 `yabairc` 那 29 條 `manage=off` 全部是 `^名字$` 的
    /// 錨定形式，零真 pattern，所以存純名字是逐字等價的搬移）。
    ///
    /// 不是字串的元素**跳過並算進 problems 之外**——這裡刻意安靜：清單裡一個
    /// 打錯的型別讓那一個失效就好，它不像綁定有「按了沒反應」那種難查的症狀
    /// （症狀是那個 app 被排進版面，看得見）。
    private static func floatApps(in members: [JSONMember]) -> [String] {
        guard case let .array(items)? = members.first(where: { $0.key == "float" })?.value
        else { return [] }
        return items.compactMap {
            guard case let .string(name) = $0 else { return nil }
            return name
        }
    }

    /// `grids`：display uuid → 格數與間距。
    ///
    /// 壞掉的**單一台**跳過並說一句，與綁定同一條慣例——一個打錯的字不該關掉
    /// 全部螢幕的設定，而安靜跳過會讓那一台變成「我設了 4×4 卻還是 6×4」。
    private static func grids(in members: [JSONMember])
        -> (table: [String: GridConfig], problems: [String])
    {
        guard case let .object(rows)? = members.first(where: { $0.key == "grids" })?.value
        else { return ([:], []) }
        var table: [String: GridConfig] = [:]
        var problems: [String] = []
        for row in rows {
            guard case let .object(fields) = row.value else {
                problems.append("grids「\(row.key)」不是物件")
                continue
            }
            func number(_ key: String) -> Double? {
                guard case let .number(text)? = fields.first(where: { $0.key == key })?.value
                else { return nil }
                return Double(text)
            }
            // 缺欄位用預設值而不是 0：一份只寫了 columns 的設定，使用者的意圖是
            // 「其餘照舊」，而 0 會讓那台螢幕的間距消失。
            table[row.key] = GridConfig(
                columns: number("columns").map { Int($0) } ?? GridConfig.defaults.columns,
                rows: number("rows").map { Int($0) } ?? GridConfig.defaults.rows,
                gap: number("gap") ?? GridConfig.defaults.gap
            )
        }
        return (table, problems)
    }

    /// `zones`：位置庫。壞掉的單一條逐條說出來再跳過。
    private static func zones(in members: [JSONMember])
        -> (list: [GridZone], problems: [String])
    {
        guard case let .array(rows)? = members.first(where: { $0.key == "zones" })?.value
        else { return ([], []) }
        var list: [GridZone] = []
        var problems: [String] = []
        for (index, row) in rows.enumerated() {
            guard case let .object(fields) = row else {
                problems.append("zones 第 \(index + 1) 個不是物件")
                continue
            }
            func text(_ key: String) -> String? {
                guard case let .string(value)? = fields.first(where: { $0.key == key })?.value
                else { return nil }
                return value
            }
            guard let name = text("name"), !name.isEmpty else {
                problems.append("zones 第 \(index + 1) 個缺 name")
                continue
            }
            // 補回 `grid:` 前綴整支重用 `HotkeyAction.parse`——這裡零個新 parser。
            guard let gridText = text("grid"),
                  case let .placeGrid(rows, columns, originX, originY, width, height)? =
                  HotkeyAction.parse("grid:\(gridText)")
            else {
                problems.append("zones「\(name)」的 grid 認不得")
                continue
            }
            var hotkey: Hotkey?
            if let keyText = text("key") {
                guard let parsed = Hotkey.parse(keyText), parsed.isSafeAsGlobalShortcut else {
                    problems.append("zones「\(name)」的按鍵「\(keyText)」不能用"
                        + "（至少要有一個 cmd／ctrl／alt）")
                    continue
                }
                hotkey = parsed
            }
            list.append(GridZone(name: name,
                                 spec: .init(rows: rows, columns: columns, originX: originX,
                                             originY: originY, width: width, height: height),
                                 hotkey: hotkey))
        }
        return (list, problems)
    }

    /// `Result` 的 failure 要 conform `Error`，而這裡的失敗就是一句給人看的話。
    private enum Decoded {
        case accepted(HotkeyBinding)
        case rejected(String)
    }

    private static func decode(_ row: JSONValue) -> Decoded {
        guard case let .object(fields) = row else { return .rejected("不是物件") }
        func text(_ key: String) -> String? {
            guard case let .string(value)? = fields.first(where: { $0.key == key })?.value
            else { return nil }
            return value
        }
        guard let keyText = text("key") else { return .rejected("缺 key") }
        guard let hotkey = Hotkey.parse(keyText) else { return .rejected("認不得按鍵「\(keyText)」") }
        guard let actionText = text("action") else { return .rejected("缺 action") }
        guard let action = HotkeyAction.parse(actionText) else {
            return .rejected("認不得動作「\(actionText)」")
        }
        var isEnabled = true
        if case let .bool(value)? = fields.first(where: { $0.key == "enabled" })?.value {
            isEnabled = value
        }
        return .accepted(HotkeyBinding(hotkey: hotkey, action: action, isEnabled: isEnabled))
    }

    /// 寫回去。`enabled` 只在它是 false 的時候寫出來，`float` 只在非空的時候
    /// 寫出來——預設值寫進檔案只是雜訊，而這個檔是給人看的。
    public static func write(_ document: HotkeyDocument) -> JSONValue {
        let rows = document.bindings.map { binding -> JSONValue in
            var fields = [
                JSONMember(key: "key", value: .string(binding.hotkey.description)),
                JSONMember(key: "action", value: .string(binding.action.text)),
            ]
            if !binding.isEnabled {
                fields.append(JSONMember(key: "enabled", value: .bool(false)))
            }
            return .object(fields)
        }
        var members = [JSONMember(key: "bindings", value: .array(rows))]
        if !document.floatApps.isEmpty {
            members.append(JSONMember(key: "float",
                                      value: .array(document.floatApps.map { .string($0) })))
        }
        if let mouse = document.mouse.member {
            members.append(mouse)
        }
        // 與預設相同的螢幕不寫出來，與 `mouse` 同一條：預設值寫進檔案只是雜訊。
        let listed = document.grids.filter { $0.value != GridConfig.defaults }
        if !listed.isEmpty {
            members.append(JSONMember(key: "grids", value: .object(
                // 鍵序排過：字典沒有順序，不排的話同一份設定每次存檔都可能換行序，
                // 而那是一個沒有內容的 diff。
                listed.keys.sorted().map { uuid in
                    let config = listed[uuid] ?? GridConfig.defaults
                    return JSONMember(key: uuid, value: .object([
                        JSONMember(key: "columns", value: .number("\(config.columns)")),
                        JSONMember(key: "rows", value: .number("\(config.rows)")),
                        JSONMember(key: "gap", value: .number(JQNumber.text(config.gap))),
                    ]))
                }
            )))
        }
        if !document.zones.isEmpty {
            members.append(JSONMember(key: "zones", value: .array(
                document.zones.map { zone in
                    var fields = [JSONMember(key: "name", value: .string(zone.name)),
                                  JSONMember(key: "grid", value: .string(zone.gridText))]
                    if let hotkey = zone.hotkey {
                        fields.append(JSONMember(key: "key",
                                                 value: .string(hotkey.description)))
                    }
                    return .object(fields)
                }
            )))
        }
        return .object(members)
    }

    /// 同一組鍵綁了兩個動作時，回那幾組鍵。
    ///
    /// 註冊時先來的贏（`RegisterEventHotKey` 對重複的組合回錯誤），所以後面那條
    /// 會安靜地不生效——這支就是為了讓 UI 說得出「這個鍵已經被用掉了」。
    /// 只看啟用的：關掉的那條不會去搶註冊。
    public static func conflicts(in bindings: [HotkeyBinding]) -> [Hotkey] {
        var seen: Set<Hotkey> = []
        var clashing: [Hotkey] = []
        for binding in bindings where binding.isEnabled {
            if !seen.insert(binding.hotkey).inserted, !clashing.contains(binding.hotkey) {
                clashing.append(binding.hotkey)
            }
        }
        return clashing
    }
}
