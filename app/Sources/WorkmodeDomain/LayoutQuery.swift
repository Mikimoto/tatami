/// 設定的查詢。bash 對應：`workmode.sh:133-150` 與 `:246-259` 的六支純函式
/// （`location_desc`／`location_display`／`location_names_from`／`profile_names_in`／
/// `exile_for`／`windows_for`）。
///
/// 吃 JSONValue 而不是一個解析好的 Config 型別，理由與 LayoutValidator、LayoutTree
/// 相同：對照組是 jq，而 jq 對「不合設定形狀」的輸入有它自己的一套行為（見下），
/// 先轉成強型別就等於在移植之前先改掉那些行為。
///
/// 下面每一條都是拿 jq 1.8.2 對 `scripts/workmode.sh` 實跑出來的，不是照語意推的：
///
/// - `//` 的假值**只有** `null` 與 `false`。`0`、`""`、`[]`、`{}` 全是真值，
///   所以 `"exile": []` 真的會取代地點層，而 `"exile": false` 會被跳過退回去
/// - `//` **不吞左邊的例外**：`.h.profiles["P"]` 在 profiles 是字串時直接報錯，
///   右邊有 fallback 也救不了（實測 rc=5）
/// - `null` 索引出 `null` 而不是錯，所以地點不存在時整條路徑安靜地收斂成空的
/// - `keys_unsorted` 對**陣列**回的是索引（`[10,20]` → `0 1`），對純量才報錯
/// - `join` 走的是 `.[]`：物件會 join 它的**值**；null 元素變空字串、數字用字面值、
///   布林用 `true`/`false`；元素是容器就報錯
/// - `+` 對兩個物件是**合併**（左邊鍵序保留、右邊同名的值蓋過去），不是錯
///
/// 五欄的 TSV 轉義**不在這裡**：這一層回的是 JSONValue，怎麼印是呼叫端的事。
public enum LayoutQuery {
    /// 視窗規則表在設定檔裡的鍵名。三層都叫這個名字：最外層是共用總表（也因此它
    /// 不是地點，bash 是 `keys_unsorted - ["windows"]`），地點層與 profile 層是覆寫
    /// （`LayoutQuery.swift:111,118-119`、`ProfileResolution.swift:158,166`、
    /// `LayoutValidatorJQ.swift:43`）。全系統只有這一份宣告——抄第二份的話，
    /// 兩份分歧時不會有任何東西出聲。
    public static let reservedKey = "windows"

    // MARK: - location_desc（workmode.sh:133-135）

    /// 地點的人看描述。回 nil 代表 jq 的 `empty`——**零位元組**，不是空行。
    ///
    /// nil 與 `.string("")` 是兩種不同的輸出，不能合併：命令替換會把兩者都吃成
    /// 空字串，但差分比的是位元組（實測缺欄位是 0 個位元組，`"desc":""` 是 `0a`）。
    public static func locationDescription(_ location: String,
                                           in config: JSONValue) throws -> JSONValue?
    {
        try alternative(member(member(config, location), "desc"))
    }

    // MARK: - location_display（workmode.sh:138-140）

    /// 地點裡某個螢幕角色的 uuid。回 nil 代表沒定義。
    public static func locationDisplay(_ location: String, role: String,
                                       in config: JSONValue) throws -> JSONValue?
    {
        try alternative(member(member(member(config, location), "displays"), role))
    }

    // MARK: - location_names_from（workmode.sh:143-145）

    /// 全部地點名稱，空白分隔，維持設定檔裡的順序。
    public static func locationNames(in config: JSONValue) throws -> String {
        let names = try keysUnsorted(config).filter { $0 != .string(reservedKey) }
        return try join(names)
    }

    // MARK: - profile_names_in（workmode.sh:148-150）

    /// 某個地點底下的 profile 名稱，空白分隔，維持設定檔裡的順序。
    /// 地點不存在時是空字串（印出來是一個空行）而不是錯。
    public static func profileNames(inLocation location: String,
                                    in config: JSONValue) throws -> String
    {
        let profiles = try member(member(config, location), "profiles")
        // `// {}`：不存在、null、false 三種都退到空物件。
        return try join(keysUnsorted(isTruthy(profiles) ? profiles : .object([])))
    }

    // MARK: - exile_for（workmode.sh:256-259）

    /// 某個 profile 生效的清場螢幕角色，空白分隔。
    ///
    /// 繼承只有兩層而且是「整塊取代」：profile 寫了就用它的，沒寫才用地點層的。
    /// windows_for 那支多一層最外層的共用總表，這支**沒有**——清場角色是地點的
    /// 螢幕配置，跨地點共用沒有意義。
    public static func exile(location: String, profile: String,
                             in config: JSONValue) throws -> String
    {
        let locationValue = try member(config, location)
        let fromProfile = try member(
            member(member(locationValue, "profiles"), profile), "exile"
        )
        if isTruthy(fromProfile) {
            return try join(iterate(fromProfile))
        }
        let fromLocation = try member(locationValue, "exile")
        if isTruthy(fromLocation) {
            return try join(iterate(fromLocation))
        }
        return ""
    }

    // MARK: - windows_for（workmode.sh:246-253）

    /// 某個 profile 生效的視窗規則，維持設定檔裡的順序。
    ///
    /// 繼承是兩段不同的規則：profile 層是「整塊取代」——合併要定義同 label 怎麼疊，
    /// 那是額外的規則，取代的行為一眼看完；地點層則是「接在最外層那份共用總表後面」，
    /// 因為兩個地點只差一兩條，取代語意會逼人把共用的再抄一次。
    ///
    /// 收 callback 而不是回陣列：bash 那側 jq 是邊算邊印的，runtime error 之前印出去
    /// 的行留在 stdout 上（實測 label 是物件時第一行照樣印出來才 rc=5）。回陣列的話
    /// 失敗時輸出會從一行變成零行。
    public static func windowRules(location: String, profile: String, in config: JSONValue,
                                   emit: (WindowRule) throws -> Void) throws
    {
        let locationValue = try member(config, location)
        let fromProfile = try member(
            member(member(locationValue, "profiles"), profile), Self.reservedKey
        )

        let source: JSONValue
        if isTruthy(fromProfile) {
            source = fromProfile
        } else {
            let shared = try member(config, Self.reservedKey)
            let local = try member(locationValue, Self.reservedKey)
            source = try add(isTruthy(shared) ? shared : .array([]),
                             isTruthy(local) ? local : .array([]))
        }

        for entry in try iterate(source) {
            // 求值順序照抄 jq 的 `[.label, .match[0], .match[1], …]`：陣列是左到右
            // 建起來的，所以 match 壞掉時的錯誤先於 fallback 的。
            let label = try member(entry, "label")
            let match = try member(entry, "match")
            let matchKind = try element(match, 0)
            let matchValue = try element(match, 1)
            let fallback = try member(entry, "fallback")
            // 讀在 fallback **之後**：`member` 對非物件會 throw，而 jq 那側建陣列是
            // 左到右的，所以錯誤的先後順序是差分基準的一部分。走到這裡 entry 已經
            // 通過 `.label` 那次索引，所以這一行不可能是新的錯誤來源。
            let launch = try member(entry, "launch")
            try emit(WindowRule(
                label: label,
                matchKind: matchKind,
                matchValue: matchValue,
                // 缺 fallback 的欄位填 "-"，讓 read 的欄位數固定。`//` 的假值只有
                // null 與 false，所以 `""` 與 `0` 會原樣留下、不會變成 "-"。
                fallbackKind: alternative(element(fallback, 0)) ?? .string("-"),
                fallbackValue: alternative(element(fallback, 1)) ?? .string("-"),
                launch: launch
            ))
        }
    }

    // MARK: - effective_labels（LayoutValidator.treeChecks 的生效清單）

    /// 一個 profile 生效的 label 清單，語意與 `LayoutValidator` 的樹檢查逐字相同。
    ///
    /// **委派給 `LayoutValidator.effectiveLabels` 而不是自己算**：編輯器可以拖的
    /// label 與 validator 認的 label 一旦漂移，症狀是「拖進去、⌘S 被擋、而畫面上兩個
    /// 名字長得一模一樣」，沒有任何測試會發現那個漂移。
    ///
    /// 回 nil 代表 jq 在這裡會 runtime error（`map(.label)` 撞到非物件的 entry）,
    /// 與 validator 的「整個串流結束」同一個語意。
    public static func effectiveLabels(location: String, profile: String,
                                       in config: JSONValue) -> [JSONValue]?
    {
        guard let locationValue = config[location] else { return [] }
        let profileValue = locationValue["profiles"]?[profile] ?? .null
        return LayoutValidator.effectiveLabels(profile: profileValue,
                                               location: locationValue,
                                               root: config)
    }

    // MARK: - jq 的零件

    /// `X // empty`：假值（null 與 false）與不存在都收斂成 nil。
    ///
    /// 例外不在這裡處理——jq 的 `//` 不吞左邊的例外，所以 throw 要一路傳上去。
    private static func alternative(_ value: JSONValue) -> JSONValue? {
        isTruthy(value) ? value : nil
    }

    private static func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case let .bool(flag): flag
        default: true
        }
    }

    /// `.[key]`。null 索引出 null（不是錯），物件取成員（沒有就 null），
    /// 其餘型別報錯（`Cannot index number with string`）——**陣列也不行**，
    /// 字串索引只對物件成立。
    private static func member(_ value: JSONValue, _ key: String) throws -> JSONValue {
        switch value {
        case .null: return .null
        case .object: return value[key] ?? .null
        default: throw LayoutQueryError.runtime
        }
    }

    /// `.[n]`。null 與越界都是 null，陣列以外的型別報錯
    /// （`Cannot index string with number`）。
    private static func element(_ value: JSONValue, _ index: Int) throws -> JSONValue {
        switch value {
        case .null: return .null
        case let .array(items): return index < items.count ? items[index] : .null
        default: throw LayoutQueryError.runtime
        }
    }

    /// `.[]`。物件走的是它的**值**；純量報錯（`Cannot iterate over number`）。
    private static func iterate(_ value: JSONValue) throws -> [JSONValue] {
        switch value {
        case let .array(items): return items
        case let .object(members): return members.map(\.value)
        default: throw LayoutQueryError.runtime
        }
    }

    /// `keys_unsorted`。物件回鍵（維持來源順序，不排序），陣列回**索引**，
    /// 純量報錯（`null (null) has no keys`）。
    private static func keysUnsorted(_ value: JSONValue) throws -> [JSONValue] {
        switch value {
        case let .object(members): return members.map { .string($0.key) }
        case let .array(items): return (0 ..< items.count).map { .number(String($0)) }
        default: throw LayoutQueryError.runtime
        }
    }

    /// `join(" ")`。null 是空字串，數字用**字面值**（`2.50` 不會變 `2.5`），
    /// 布林用 `true`/`false`，元素是容器就報錯
    /// （`string ("") and object ({}) cannot be added`）。
    private static func join(_ values: [JSONValue]) throws -> String {
        try values.map(scalarText).joined(separator: " ")
    }

    private static func scalarText(_ value: JSONValue) throws -> String {
        switch value {
        case .null: return ""
        case let .bool(flag): return flag ? "true" : "false"
        case let .number(literal): return literal
        case let .string(text): return text
        case .array, .object: throw LayoutQueryError.runtime
        }
    }

    /// `+`。兩個陣列接起來，兩個物件合併（左邊鍵序保留、右邊同名的值蓋過去）。
    ///
    /// 其餘組合一律 throw。jq 對 `"a" + "b"` 與 `1 + 2` 其實是成功的，但緊接著的
    /// `.[]` 對純量必定報錯，所以兩條路的可觀測結果相同（rc=5、零位元組）——
    /// 把它們提前在這裡擋下不會讓輸出漂掉。型別不一致（如 `[] + {}`）在 jq 本來
    /// 就是錯。
    private static func add(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        switch (lhs, rhs) {
        case let (.array(left), .array(right)):
            return .array(left + right)
        case let (.object(left), .object(right)):
            var merged = left
            for member in right {
                if let index = merged.firstIndex(where: { $0.key == member.key }) {
                    merged[index] = member
                } else {
                    merged.append(member)
                }
            }
            return .object(merged)
        default:
            throw LayoutQueryError.runtime
        }
    }
}

/// 一條視窗規則。bash 那側是 `@tsv` 的五個欄位，所以這裡也是五個——
/// 欄位數固定是刻意的，讓 `read` 的呼叫端不必分辨有沒有 fallback。
///
/// 存的是 JSONValue 而不是 String：`.label` 可能是數字甚至容器（容器在 `@tsv`
/// 那一步才報錯），提前轉成字串就把「哪一步報錯」這件事改掉了。
public struct WindowRule: Equatable, Sendable {
    public let label: JSONValue
    public let matchKind: JSONValue
    public let matchValue: JSONValue
    /// 缺的時候是 `.string("-")`，不是 nil——那個占位符是 bash 輸出的一部分。
    public let fallbackKind: JSONValue
    public let fallbackValue: JSONValue
    /// `--launch` 要開哪個 app。**bash 沒有這個欄位**，所以它不進 `@tsv`——
    /// 那五個欄位是差分基準，多印一欄會讓 2257 組語料全紅。缺的時候是 `.null`。
    ///
    /// 存在的理由：`url-*` 與 `title-regex` 的 `matchValue` 是網址或標題 regex，
    /// 裡面沒有任何東西可以餵給 `open -a`（一個 `url-contains` 規則要的視窗可能屬於
    /// Safari、Chrome 或任何瀏覽器，設定檔一個字都沒說）。這個欄位就是那句沒說的話。
    public let launch: JSONValue

    public init(label: JSONValue, matchKind: JSONValue, matchValue: JSONValue,
                fallbackKind: JSONValue, fallbackValue: JSONValue,
                launch: JSONValue = .null)
    {
        self.label = label
        self.matchKind = matchKind
        self.matchValue = matchValue
        self.fallbackKind = fallbackKind
        self.fallbackValue = fallbackValue
        self.launch = launch
    }
}

/// jq 的 runtime error：字串索引碰到非物件、`.[0]` 碰到非陣列、`.[]` 碰到純量、
/// `keys_unsorted` 碰到純量、`join` 碰到容器元素、`+` 碰到型別不一致。
/// bash 那側的 exit code 是 5。
///
/// 不共用 `LayoutTreeError`：那個型別多一個 `nonTerminating`，而設定查詢沒有
/// 會無限遞迴的輸入——共用會讓呼叫端以為要處理一個永遠不會發生的情況。
public enum LayoutQueryError: Error, Equatable, Sendable {
    case runtime
}
