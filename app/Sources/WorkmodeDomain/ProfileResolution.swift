/// 這次用哪個 profile，以及把結果寫回設定。bash 對應：`workmode.sh:197-234` 的
/// `resolve_profile` 與 `:437-447` 的 `merge_profile`，外加前者依賴的
/// `:157-171` `state_get`。
///
/// 三支放同一個檔，是因為 `resolve_profile` 讀不到 `state_get` 就不完整，而
/// `merge_profile` 是同一個決定的另一半（選了哪個 profile → 存回哪裡）。
///
/// 下面每一條都是拿 bash 實跑出來的，不是照語意推的：
///
/// - 命令列參數打錯字是**硬失敗**；狀態檔失效只退讓並回報；`default` 與
///   「第一個 key」兩層完全不檢查（`validate_layout` 已保證，走不到的分支等於
///   沒測過的分支）
/// - `profile_names_in` 與 `default` 那兩個 jq 呼叫的 runtime error **被命令替換
///   吃掉**，於是壞掉的設定不是失敗而是靜默退到 first
/// - jq 的 `//` 假值只有 null 與 false，但 `default` 那層真正決定去留的是 bash 的
///   `[ -n "$dflt" ]`——它看的是命令替換**砍掉尾端換行之後**的字串，所以 `""` 與
///   `"\n"` 在 jq 是真值、在 bash 是空
/// - bash 的 `case`／`awk` 比的是**位元組**，不是 Unicode 正規化後的等價
/// - `merge_profile` 的落點看目標 profile 有沒有自己的 `windows`（`[]` 也算有）
/// - jq 的 `+` 對 null 是單位元素、對兩個字串是接起來、對兩個物件是合併
public enum ProfileResolution {
    /// 四個來源。bash 那側是輸出的第二欄。
    public enum Source: String, Sendable {
        case arg, memory, `default`, first
    }

    /// 決定這次用哪個 profile。
    ///
    /// `renderRaw` 是 jq `-r` 的印法，由呼叫端注入而不是在這裡實作：容器要印
    /// **縮排**格式，那需要 `WorkmodeWire` 的 JSONWriter，而 Domain 不能依賴外層
    /// （`WorkmodeArchitectureTests` 會擋）。它只在 `default` 是容器時才真的重要，
    /// 純量那幾種怎麼印是固定的。
    public static func resolve(location: String, want: String, state: String,
                               in config: JSONValue,
                               renderRaw: (JSONValue) -> String) throws -> ProfileChoice
    {
        // `names=" $(profile_names_in …) "`：前後各補一個空白，讓成員判斷可以用
        // 「含有 ` name ` 這個子字串」一句話寫完。命令替換砍掉尾端換行，jq 的
        // runtime error 則讓它整個變空——兩者都不是失敗。
        let namesText = stripTrailingNewlines((try? LayoutQuery.profileNames(
            inLocation: location, in: config
        )) ?? "")
        let names = " " + namesText + " "

        if !want.isEmpty {
            if containsBytes(names, " " + want + " ") {
                return ProfileChoice(name: want, source: .arg, ignoredMemory: "")
            }
            throw ProfileResolutionError.unknownProfile(
                want: want, location: location, available: namesText
            )
        }

        var stale = ""
        let remembered = StateFile.value(forKey: "profile." + location, in: state)
        if !remembered.isEmpty {
            if containsBytes(names, " " + remembered + " ") {
                return ProfileChoice(name: remembered, source: .memory, ignoredMemory: "")
            }
            stale = remembered
        }

        // `jq -r '.[$l].default // empty'`。錯誤同樣被命令替換吃掉，所以 `try?`。
        let raw = try? member(member(config, location), "default")
        if let raw, isTruthy(raw) {
            let text = stripTrailingNewlines(renderRaw(raw))
            // 這個非空判斷是 **bash** 的 `[ -n ]`，不是 jq 的真值——`""` 與 `"\n"`
            // 通得過 `//` 卻過不了這裡。
            if !text.isEmpty {
                return ProfileChoice(name: text, source: .default, ignoredMemory: stale)
            }
        }

        return ProfileChoice(name: firstFields(of: names), source: .first,
                             ignoredMemory: stale)
    }

    // MARK: - bash 的零件

    /// `printf '%s' "$names" | awk '{print $1}'`，再讓命令替換砍掉尾端換行。
    ///
    /// awk 是**逐行**印第一個欄位的，所以 profile 名稱含換行時輸出也是多行的
    /// （實測 `{"a\nb":{},"C":{}}` 回 `a\nb`）。
    private static func firstFields(of names: String) -> String {
        stripTrailingNewlines(
            splitOnNewlineBytes(names).map(firstField).joined(separator: "\n")
        )
    }

    /// awk 的預設欄位切法：跳過開頭的空白，取到下一個空白為止。空白只有空格與
    /// tab——`join(" ")` 的分隔符是空格，而名稱裡的 tab 因此會被切開。
    private static func firstField(_ line: String) -> String {
        var bytes = line.utf8[...]
        while let first = bytes.first, first == 0x20 || first == 0x09 {
            bytes = bytes.dropFirst()
        }
        var end = bytes.startIndex
        while end < bytes.endIndex, bytes[end] != 0x20, bytes[end] != 0x09 {
            end = bytes.index(after: end)
        }
        return String(decoding: bytes[bytes.startIndex ..< end], as: UTF8.self)
    }
}

/// 選出來的 profile。bash 那側是一行三欄的 TSV，欄位分隔是裸 tab、**沒有轉義**
/// （`printf` 而不是 `@tsv`），所以名字裡的 tab 會讓欄位數變多——照做。
public struct ProfileChoice: Equatable, Sendable {
    public let name: String
    public let source: ProfileResolution.Source
    /// 只在記憶失效時才有值，其餘都是空字串（第三欄照樣印，只是空的）。
    public let ignoredMemory: String

    public init(name: String, source: ProfileResolution.Source, ignoredMemory: String) {
        self.name = name
        self.source = source
        self.ignoredMemory = ignoredMemory
    }
}

/// 唯一的硬失敗：命令列參數指名了一個不存在的 profile（bash rc=2）。
///
/// 帶著 `available` 是因為 bash 的錯誤訊息會把可用清單印出來，而那份清單是
/// 這裡算好的——讓呼叫端再算一次就多一個會漂移的地方。
public enum ProfileResolutionError: Error, Equatable, Sendable {
    case unknownProfile(want: String, location: String, available: String)
}

// state_get 搬到 StateFile.swift，與 state_set 放一起。

// MARK: - merge_profile（workmode.sh:437-447）

/// 把新的 trees 與新產生的視窗規則合併回設定。
///
/// jq 那側是兩段接起來的：
/// ```
/// (if (.[$l].profiles[$p].windows | type) == "array"
///  then .[$l].profiles[$p].windows += $r
///  else .[$l].windows += $r end)
/// | .[$l].profiles[$p].trees = ((.[$l].profiles[$p].trees // {}) + $t)
/// ```
/// 兩段的先後看得出來：路徑不存在時 `windows` 先被建出來、`profiles` 後
/// （實測空設定回 `{"h":{"windows":[],"profiles":{…}}}`），而鍵序是寫回
/// `layout.json` 時唯一的依據，不能倒過來。
public enum ProfileMerge {
    /// **bash 的那一支，逐位元組對齊，只有 `__diff merge_profile` 在用。**
    ///
    /// 2026-08-30 之前 `--save` 也走它；現在 `--save` 走的是下面的 `mergeSpaceTrees`
    /// （存的是「這個 space 的版面」而不是「這個角色的版面」）。**這一支留著不是
    /// 死碼**：`tests/golden/` 有 36 組 `merge_profile` 的凍結語料，錄的是 bash 當時
    /// 的輸入與輸出，改它等於把那 36 組的差分基準換成 Swift 自己的輸出——那之後
    /// 它們就只是恆真的自我快照。`__diff` 的整個存在理由就是鏡射 bash。
    ///
    /// `trees` 用 `+` 疊上去而不是整個換掉：沒接到的螢幕角色要保留舊 profile 那棵樹，
    /// 單螢幕存一次不該把另一台的設定洗掉。
    ///
    /// 規則的落點看目標 profile 有沒有自己的 `windows`：有的話它整塊取代
    /// （連最外層那份共用總表一起，`windows_for` 的語意），新規則寫到地點層就
    /// 不會生效，樹引用的 label 於是不在生效清單裡而被 `validate_layout` 擋下。
    /// 不寫進最外層那份共用總表：它是手工維護的，兩個地點都會吃到。
    ///
    /// `--argjson` 的解析失敗**不在這裡**——jq 在讀 stdin 之前就先解析命令列，
    /// 那條的 exit code 是 2 而不是 5，所以由 CLI 在呼叫之前擋。
    public static func merge(_ config: JSONValue, location: String, profile: String,
                             trees: JSONValue, rules: JSONValue) throws -> JSONValue
    {
        var out = try mergeRules(config, location: location, profile: profile, rules: rules)
        let treesPath = [location, "profiles", profile, "trees"]

        // `//` 的假值只有 null 與 false，所以 `"trees": []` 是真值、拿去跟物件
        // 相加會報錯，而 `"trees": false` 會退到空物件。
        let base = try getPath(out, treesPath)
        out = try setPath(out, treesPath,
                          to: add(isTruthy(base) ? base : .object([]), trees))
        return out
    }

    /// `--save` 走的那一支：寫 `spaceTrees[角色][space uuid]`。**沒有 bash 對應**
    /// （2026-08-30 新增），所以這裡沒有「照抄 jq 行為」的義務，只有第一段的規則
    /// 落點與上面那支共用（那一段仍然是 bash 的語意）。
    ///
    /// **合併是兩層深的，而那個深度就是這一支存在的理由。**
    /// 上面那支對 `trees`（`{角色: 樹}`）用淺層的 `+` 剛好夠用，因為角色就是最後
    /// 一層。同一個淺層的 `+` 套到 `spaceTrees`（`{角色: {space uuid: 樹}}`）上就
    /// **無聲吃掉資料**：新的 `{main: {U-新: 樹}}` 加上舊的
    /// `{main: {U-舊: 樹, U-其他: 樹}}`，`main` 這個鍵整個被右邊取代，
    /// `U-舊` 與 `U-其他` 就消失了。所以角色那一層要逐鍵下去，只在 uuid 那一層讓
    /// 同名的被新的蓋過——那正是「我重排了這個 space，存起來」。
    public static func mergeSpaceTrees(_ config: JSONValue, location: String, profile: String,
                                       spaceTrees: JSONValue, rules: JSONValue) throws
        -> JSONValue
    {
        var out = try mergeRules(config, location: location, profile: profile, rules: rules)

        // **`trees` 這個鍵必須存在。** `LayoutValidator.swift:245,248` 對缺 `trees`
        // 的 profile 報「缺 trees」，而 `SaveLayout.build` 會拿 merge 的結果去跑
        // `LayoutValidator.validate`——不補的話，對一個沒有 `trees` 的 profile 存檔
        // 會在那道閘門被打回票（`saveMergedInvalid`），而訊息指的是一個使用者沒動過
        // 的鍵。補在 `spaceTrees` **之前**：既有檔案裡 `trees` 排在前面，而鍵序是
        // 寫回 layout.json 時唯一的依據。
        let legacy = [location, "profiles", profile, "trees"]
        if case .null = try getPath(out, legacy) {
            out = try setPath(out, legacy, to: .object([]))
        }

        let path = [location, "profiles", profile, "spaceTrees"]
        // 假值只有 null 與 false，與上面那支同一條：`"spaceTrees": false` 退到空物件。
        let base = try getPath(out, path)
        let baseObject = isTruthy(base) ? base : .object([])
        // 非物件的 base 在這裡就報，不留給下面的 `getPath` 去撞：incoming 是空物件時
        // 那個迴圈根本不跑，錯就消失了（上面那支的 `add` 是無條件的，沒有這個縫）。
        guard case .object = baseObject else { throw ProfileMergeError.runtime }

        var roles = baseObject
        switch spaceTrees {
        case let .object(incoming):
            for role in incoming {
                let existing = try getPath(baseObject, [role.key])
                let combined = try add(isTruthy(existing) ? existing : .object([]),
                                       role.value)
                roles = try setPath(roles, [role.key], to: combined)
            }
        // jq 的 `+` 對 null 是單位元素（兩個方向都是），與上面那支一致。
        case .null:
            break
        default:
            throw ProfileMergeError.runtime
        }
        return try setPath(out, path, to: roles)
    }

    /// 兩支共用的第一段：把新規則接到對的那份 `windows` 上。
    ///
    /// 抽出來不是為了少打字——兩份會漂，而漂掉的症狀是「規則寫到地點層卻不生效，
    /// 樹引用的 label 於是被 validate 擋下」，離改動點很遠。
    private static func mergeRules(_ config: JSONValue, location: String, profile: String,
                                   rules: JSONValue) throws -> JSONValue
    {
        let profileWindows = [location, "profiles", profile, LayoutQuery.reservedKey]
        // `if` 的條件先求值，所以 profiles 壞掉時是它先炸，輪不到地點層那條。
        let existing = try getPath(config, profileWindows)
        let windowsPath: [String] = if case .array = existing {
            profileWindows
        } else {
            [location, LayoutQuery.reservedKey]
        }
        return try setPath(config, windowsPath,
                           to: add(getPath(config, windowsPath), rules))
    }

    /// `.a.b.c` 的讀取。null 一路傳染下去（不是錯），物件取成員，其餘報錯。
    private static func getPath(_ root: JSONValue, _ path: [String]) throws -> JSONValue {
        var cursor = root
        for key in path {
            switch cursor {
            case .null: return .null
            case .object: cursor = cursor[key] ?? .null
            default: throw ProfileMergeError.runtime
            }
        }
        return cursor
    }

    /// jq 的 `setpath`：不存在的中繼節點一路建成物件（連根是 null 也一樣），
    /// 既有的鍵原地更新、新的鍵接在尾端。非物件的中繼節點報錯。
    ///
    /// 走訪本體在 `JSONPath` —— 這裡原本有一份自己的複製品，兩份走同一棵樹而只有
    /// 一份會被改到。丟出來的形狀錯誤因此是 `JSONPath.Failure` 而不是
    /// `ProfileMergeError.runtime`；兩者在 CLI 都走 `exitLikeJQ` 收成 rc=5，而且
    /// `merge` 走不到它——同一條路徑的 `getPath` 排在前面，非物件的中繼節點在那裡
    /// 就先報錯了。
    private static func setPath(_ root: JSONValue, _ path: [String],
                                to newValue: JSONValue) throws -> JSONValue
    {
        try JSONPath.setCreatingMissingObjects(root, path.map { .key($0) }, to: newValue)
    }

    /// jq 的 `+`。null 是單位元素（兩個方向都是），兩個陣列接起來，兩個物件合併
    /// （左邊鍵序保留、右邊同名的值蓋過去），兩個字串接起來。
    ///
    /// **兩個數字相加沒有實作**，那是本檔唯一已知的分歧：jq 會算出和並用它自己的
    /// 浮點印法輸出（實測 `2.50 + 1` → `3.5`），而 JSONValue 存的是**字面值**，
    /// 複製那個印法等於再移植一個 jq 的數字格式器。產品路徑走不到（`$r` 一定是
    /// 呼叫端產生的陣列），所以這裡報錯並把它排除在差分語料之外，見
    /// `tests/diff_bash_swift.sh` 該節的註解。
    private static func add(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
        switch (lhs, rhs) {
        case (.null, _): return rhs
        case (_, .null): return lhs
        case let (.array(left), .array(right)): return .array(left + right)
        case let (.string(left), .string(right)): return .string(left + right)
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
            throw ProfileMergeError.runtime
        }
    }
}

/// jq 的 runtime error：非物件的中繼節點、型別對不上的 `+`。bash 那側是 exit 5。
///
/// 不共用 `LayoutQueryError`：那支守的是唯讀查詢，而這裡多一條「寫回去」的路徑，
/// 兩者將來要分別加 case 時共用會互相牽動。
public enum ProfileMergeError: Error, Equatable, Sendable {
    case runtime
}

// MARK: - 共用的位元組零件

//
// 全部走 UTF-8 位元組而不是 Swift 的 Character，理由有兩個而且都咬過人：
//   1. `\r\n` 在 Swift 是**一個** Character，用 `split(separator: "\n")` 切不開，
//      用 `hasSuffix("\n")` + `dropLast()` 會把 `\r` 一起砍掉——bash 兩者都只看
//      0x0A 那一個位元組。
//   2. Swift 的 `String ==`／`contains` 做 Unicode 正規化等價，NFC 的 `café`
//      等於 NFD 的 `café`；bash 的 `case` 與 `LC_ALL=C awk` 都不是（實測 rc=2）。

/// 以 0x0A 切開，空的片段保留（awk 的 record 就是這樣切的）。
/// StateFile.swift 也用它。
func splitOnNewlineBytes(_ text: String) -> [String] {
    var out: [String] = []
    var current: [UInt8] = []
    for byte in text.utf8 {
        if byte == 0x0A {
            out.append(String(decoding: current, as: UTF8.self))
            current = []
        } else {
            current.append(byte)
        }
    }
    out.append(String(decoding: current, as: UTF8.self))
    return out
}

/// 命令替換 `$(...)` 砍掉尾端**全部**的換行，不是一個。
private func stripTrailingNewlines(_ text: String) -> String {
    var bytes = Array(text.utf8)
    while bytes.last == 0x0A {
        bytes.removeLast()
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// 子字串搜尋，位元組層級。對應 bash 的 `case "$names" in *" $want "*`——
/// `$want` 在雙引號裡，所以 glob 字元是字面的，不需要跳脫處理。
private func containsBytes(_ haystack: String, _ needle: String) -> Bool {
    let hay = Array(haystack.utf8)
    let pin = Array(needle.utf8)
    guard !pin.isEmpty, hay.count >= pin.count else { return pin.isEmpty }
    for start in 0 ... (hay.count - pin.count) where Array(hay[start ..< start + pin.count]) == pin {
        return true
    }
    return false
}

/// `//` 的假值只有 null 與 false。`0`、`""`、`[]`、`{}` 全是真值。
private func isTruthy(_ value: JSONValue) -> Bool {
    switch value {
    case .null: false
    case let .bool(flag): flag
    default: true
    }
}

/// `.[key]`。null 索引出 null（不是錯），物件取成員，其餘報錯。
/// `resolve_profile` 的 `default` 那條用它——錯誤會被呼叫端 `try?` 吃掉，
/// 正如 bash 那側被命令替換吃掉。
private func member(_ value: JSONValue, _ key: String) throws -> JSONValue {
    switch value {
    case .null: return .null
    case .object: return value[key] ?? .null
    default: throw ProfileMergeError.runtime
    }
}
