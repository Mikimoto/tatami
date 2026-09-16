/// 一則設定問題。分成兩類是因為 bash 版把它們印成**兩段不同格式**的輸出：
/// 缺欄位那段用空白接成一行，結構那段一行一條、每行縮 4 格。
public enum LayoutProblem: Equatable, Sendable {
    case missingField(String)
    case structural(String)
}

/// `validate_layout`（workmode.sh:35-102）的 Swift 版。
///
/// 純規則：不讀檔、不碰 yabai、不解析 JSON——輸入已經是解析好的 JSONValue。
///
/// 回傳順序就是 bash 版的輸出順序，呼叫端照順序印即可。順序由 jq 的串流語意決定：
/// 最外層依來源鍵序（跳過保留字 windows），地點內依檢查的宣告順序。
public enum LayoutValidator {
    public static func validate(_ root: JSONValue) -> [LayoutProblem] {
        guard case let .object(top) = root else { return [] }

        // bash 版是兩個獨立的 jq 呼叫：缺欄位那段有問題就印完直接 return 1，
        // 根本不會執行結構那段。所以這裡也要分段，兩類問題不會同時出現。
        var missing: [LayoutProblem] = []
        for member in top where member.key != LayoutQuery.reservedKey {
            let step = missingFields(location: member.key, value: member.value, root: root)
            missing += step.problems
            // 與結構那段同一種中止：地點的值不是物件時 jq 在 `$lv.desc` 就 runtime
            // error，整個串流結束。實測 {"aaa":合法,"home":"字串","z z":有空白}
            // 回 rc=0 且零輸出——連 z z 的違規都被吞掉。
            if !step.continues {
                break
            }
        }
        if !missing.isEmpty {
            return missing
        }

        var structural: [LayoutProblem] = []
        for member in top where member.key != LayoutQuery.reservedKey {
            let step = locationStructure(location: member.key, value: member.value, root: root)
            structural += step.problems
            // jq 的 runtime error 中止的是**整個串流**：已經吐出來的留著，後面的
            // 地點一條都不檢查。實測 `default: 3` 會把下一個地點的空白違規吞掉。
            if !step.continues {
                break
            }
        }
        return structural
    }

    /// 缺欄位那三條（workmode.sh:42-50）。
    ///
    /// `continues` 為 false 代表 jq 在這裡會 runtime error、整個串流結束。
    /// 實測哪些型別會中止：字串／陣列／數字／布林都會（`.desc` 無法索引），
    /// **null 不會**（`null.desc` 在 jq 是合法的，回 null）。
    private static func missingFields(location: String,
                                      value: JSONValue,
                                      root: JSONValue)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        switch value {
        case .object, .null: break
        default: return ([], false)
        }
        var out: [LayoutProblem] = []

        // desc 要是非空字串。空字串也算缺——下游拿「desc 非空」當地點存在的判準。
        var hasDesc = false
        if case let .string(desc) = value["desc"] {
            hasDesc = !desc.isEmpty
        }
        if !hasDesc {
            out.append(.missingField("\(location).desc（要非空字串）"))
        }

        // 實測 jq：displays 不是物件時，`objects` 讓整條產生 empty，**else 不會走**，
        // 所以那種設定在這條檢查上不報錯。保留這個行為，不要「修正」它。
        if case .object = value["displays"], value["displays"]?["main"] == nil {
            out.append(.missingField("\(location).displays.main"))
        }

        if value[LayoutQuery.reservedKey] == nil, root[LayoutQuery.reservedKey] == nil {
            out.append(.missingField("\(location).windows"))
        }
        return (out, true)
    }

    /// `.default` 指到的 profile 存不存在。
    ///
    /// 三條路都是 jq 的 `has()` 決定的：null／false 跳過這條檢查，字串才查，
    /// 其餘型別（數字、陣列、物件、true）是 runtime error＝串流中止。
    /// profiles 不是物件時 `has()` 也中止，所以那條在字串分支裡。
    private static func defaultProfileCheck(location: String, value: JSONValue,
                                            profiles: JSONValue)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        switch alternative(value["default"], .null) {
        case .null:
            ([], true) // 不存在／null／false 都落到這裡，該條跳過。
        case let .string(name):
            if case let .object(members) = profiles {
                members.contains(where: { $0.key == name })
                    ? ([], true)
                    : ([.structural("\(location).default「\(name)」不是這個地點的 profile")], true)
            } else {
                ([], false)
            }
        default:
            ([], false)
        }
    }

    /// 每個 profile 各跑一次那四條。任何一個中止就整批停下。
    private static func allProfileChecks(location: String, value: JSONValue,
                                         profiles: JSONValue, root: JSONValue)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        guard let entries = jqToEntries(profiles) else { return ([], false) }
        var out: [LayoutProblem] = []
        for entry in entries {
            let step = profileChecks(location: location, key: entry.key, value: entry.value,
                                     locationValue: value, root: root)
            out += step.problems
            if !step.continues {
                return (out, false)
            }
        }
        return (out, true)
    }

    /// 地點層的五條結構檢查（workmode.sh:74-84），順序就是 jq 裡的宣告順序。
    ///
    /// `continues` 為 false 代表 jq 在這裡會 runtime error。那不是「跳過這一條」，
    /// 而是整個串流當場結束——呼叫端必須跟著停，見 validate。
    private static func locationStructure(location: String,
                                          value: JSONValue,
                                          root: JSONValue)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        // 與缺欄位那段同一種中止：`$lv | has("trees")` 對非物件 runtime error。
        // null 走不到這裡——它在缺欄位那段就會報 desc 與 windows 並提前回傳。
        guard case .object = value else { return ([], false) }
        var out: [LayoutProblem] = []

        if value["trees"] != nil {
            out.append(.structural(
                "\(location)：trees 不能放在地點層，要搬進 profiles.<名稱>.trees"
            ))
        }

        // 與上面那條同一個成因：放錯層的後果是**靜默無效**——`--space` 會永遠查不到樹，
        // 而設定看起來寫好了。
        if value["spaceTrees"] != nil {
            out.append(.structural(
                "\(location)：spaceTrees 不能放在地點層，要搬進 profiles.<名稱>.spaceTrees"
            ))
        }

        out += spacesChecks(location: location, value: value)

        let profiles = alternative(value["profiles"], .object([]))
        guard let isEmpty = jqLengthIsZero(profiles) else { return (out, false) }
        if isEmpty {
            out.append(.structural("\(location)：profiles 不存在或是空的"))
        }

        // 這條沒有地點前綴——地點名稱就是 auto，寫進訊息只會重複。bash 如此。
        if location == "auto" {
            out.append(.structural("地點不能叫 auto，那是 --switch 的保留字"))
        }

        if containsWhitespace(location) {
            out.append(.structural("地點名稱「\(location)」不能含空白"))
        }

        let defaultStep = defaultProfileCheck(location: location, value: value,
                                              profiles: profiles)
        out += defaultStep.problems
        guard defaultStep.continues else { return (out, false) }

        // profile 那四條接在這五條之後，同一個串流裡。
        let profileStep = allProfileChecks(location: location, value: value,
                                           profiles: profiles, root: root)
        out += profileStep.problems
        return (out, profileStep.continues)
    }

    /// label 有沒有重複。
    ///
    /// `join` 只在**有重複時**才被求值——label 是相異物件時它根本走不到，
    /// 所以那種設定不中止。有重複又是物件才會 `cannot be added`。
    private static func duplicateLabelCheck(_ labels: [JSONValue], prefix: String)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        let groups = jqGroups(labels)
        guard labels.count != groups.distinct else { return ([], true) }
        guard let list = jqJoin(groups.repeated) else { return ([], false) }
        return ([.structural("\(prefix)：windows 的 label 重複（\(list)）")], true)
    }

    /// 每個角色的樹（workmode.sh:93-94）。角色依 trees 的來源鍵序；`// {}` 讓
    /// null 與 false 變成「沒有角色」，而字串／數字／true 死在 to_entries。
    /// 陣列合法，角色名變成索引數字。
    private static func allTreeChecks(value: JSONValue, labels: [JSONValue], prefix: String)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        guard let roles = jqToEntries(alternative(value["trees"], .object([])))
        else { return ([], false) }
        var out: [LayoutProblem] = []
        for role in roles {
            let step = treeChecks(node: role.value, labels: labels,
                                  path: "\(prefix).trees.\(JQPrint.interpolate(role.key))")
            out += step.problems
            if !step.continues {
                return (out, false)
            }
        }
        return (out, true)
    }

    /// profile 層的四條（workmode.sh:85-92），順序就是 jq 裡的宣告順序。
    private static func profileChecks(location: String,
                                      key: JSONValue,
                                      value: JSONValue,
                                      locationValue: JSONValue,
                                      root: JSONValue)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        // key 不是字串時（profiles 寫成陣列，to_entries 給的是索引數字），
        // `$p == "auto"` 只是 false、不報錯；死的是下一條的 test("\\s")
        // （`number (0) cannot be matched`）。所以這裡零產出再中止。
        guard case let .string(name) = key else { return ([], false) }
        var out: [LayoutProblem] = []

        if name == "auto" {
            out.append(.structural("\(location) 的 profile 不能叫 auto，那是 --switch 的保留字"))
        }

        if containsWhitespace(name) {
            out.append(.structural("\(location) 的 profile 名稱「\(name)」不能含空白"))
        }

        // has() 對 null 回 **false**（不是 runtime error），所以 null 的 profile
        // 值照報缺 trees 而且不中止；其他非物件才是 error。實測 bash 兩者都驗過。
        switch value {
        case let .object(members):
            if !members.contains(where: { $0.key == "trees" }) {
                out.append(.structural("\(location).\(name)：缺 trees"))
            }
        case .null:
            out.append(.structural("\(location).\(name)：缺 trees"))
        default:
            return (out, false)
        }

        out += misplacedSpacesCheck(prefix: "\(location).\(name)", value: value)

        // $labels 在這裡綁定，所以 map(.label) 的 error 會先於重複檢查發生。
        // 底下的遞迴樹檢查吃的就是這份清單。
        guard let labels = effectiveLabels(profile: value, location: locationValue, root: root)
        else { return (out, false) }

        let duplicates = duplicateLabelCheck(labels, prefix: "\(location).\(name)")
        out += duplicates.problems
        guard duplicates.continues else { return (out, false) }

        let trees = allTreeChecks(value: value, labels: labels, prefix: "\(location).\(name)")
        out += trees.problems
        guard trees.continues else { return (out, false) }

        let spaceTrees = spaceTreeChecks(value: value, labels: labels,
                                         prefix: "\(location).\(name)")
        out += spaceTrees.problems
        return (out, spaceTrees.continues)
    }

    /// 遞迴的樹節點檢查（workmode.sh:59-72 的 `check`）。
    ///
    /// 前序：自己的 axis 檢查 → children 數量 → 遞迴左 → 遞迴右。四條訊息逐字照
    /// bash，路徑每往下一層接 `.0` 或 `.1`。
    ///
    /// 原本是 `private`。`LayoutValidatorSpaces.swift` 的 spaceTrees 走訪要用同一支
    /// ——抄第二份的話，同一棵樹在兩個鍵底下會有兩種對錯，而沒有東西看得見那個分歧。
    static func treeChecks(node: JSONValue, labels: [JSONValue], path: String)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        // `type != "object"`：**陣列也不是物件**，null 也是（`null | type` 是 "null"）。
        // 角色層沒有 `// empty`，所以 null 與 false 在這裡照報——被略過的只有
        // 子節點的位置。這四條訊息都不中止，串流照走。
        guard case let .object(members) = node else {
            return ([.structural("\(path)：節點不是物件")], true)
        }

        // has("window") 優先於 has("axis")：兩者都有時 axis 與 children 完全不看。
        if let window = members.first(where: { $0.key == "window" })?.value {
            // `IN($labels[])` 用 jq 的 `==`，比的是數值不是字面值（1.5 對得上 1.50）。
            if labels.contains(where: { jqCompare($0, window) == .equal }) {
                return ([], true)
            }
            return ([.structural(
                "\(path)：window「\(JQPrint.interpolate(window))」不在生效的 windows 清單裡"
            )], true)
        }

        return splitNodeChecks(members: members, labels: labels, path: path)
    }

    /// 分割節點：axis 的值、children 的數量、以及往下遞迴。
    ///
    /// 與 treeChecks 分開只是複雜度——它是同一條 jq 串流的後半段，前半段是
    /// 「這個節點是不是葉子」。
    private static func splitNodeChecks(members: [JSONMember], labels: [JSONValue],
                                        path: String)
        -> (problems: [LayoutProblem], continues: Bool)
    {
        guard let axis = members.first(where: { $0.key == "axis" })?.value else {
            return ([.structural("\(path)：節點既沒有 window 也沒有 axis")], true)
        }

        var out: [LayoutProblem] = []
        if axis != .string("vertical"), axis != .string("horizontal") {
            out.append(.structural(
                "\(path)：axis「\(JQPrint.interpolate(axis))」不是 vertical 或 horizontal"
            ))
        }

        // `.children // []`：null 與 false 變成空陣列。**true 沒有 length**，jq 在
        // 那裡就 runtime error——上面那條 axis 訊息已經先落地，數量這條不會產生。
        let children = alternative(members.first(where: { $0.key == "children" })?.value,
                                   .array([]))
        guard let count = jqLength(children) else { return (out, false) }
        if jqCompare(count, .number("2")) != .equal {
            out.append(.structural(
                "\(path)：children 有 \(JQPrint.interpolate(count)) 個，必須恰好 2 個"
            ))
        }

        // 數量對不對都照樣往下走，而且只看 [0] 與 [1]——第三個以後連碰都不碰。
        // 物件／字串／數字的 children 索引不動，所以那些設定是「數量訊息先落地
        // 再中止」（`{}` 報 0 個後中止；剛好 2 個成員則連訊息都沒有就中止）。
        for slot in 0 ... 1 {
            guard let element = jqIndex(children, slot) else { return (out, false) }
            switch element {
            case .null, .bool(false): continue // `// empty`：這個位置不遞迴。
            default: break
            }
            let step = treeChecks(node: element, labels: labels, path: "\(path).\(slot)")
            out += step.problems
            if !step.continues {
                return (out, false)
            }
        }
        return (out, true)
    }
}

/// 取物件成員的便利索引。非物件或找不到都回 nil。
public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
}

public extension LayoutProblem {
    /// 這則問題的裸文字：不含 `! layout.json …` 抬頭，也不含縮排。
    ///
    /// 住在 Domain 而不是 renderer 那一層，因為它**不是格式化**——沒有抬頭、沒有
    /// 縮排、也沒有標點的選擇，只是把關聯值取出來。真正的格式化（`renderProblems`
    /// 的抬頭與縮排）留在 Adapters。
    ///
    /// 放在這裡是因為要它的有**三個不同層**：`WorkmodeAdapters` 兩處（`--json` 的
    /// `data.problems` 與 `ApplyEnvelope` 的 message），以及編輯器的 UI——後者依
    /// 架構規則不准 import Adapters（`DependencyRuleTests` 在守），但准 import
    /// Domain。抄第二份的那一份就沒有東西在驗它。
    ///
    /// 寫成檔案末尾的 extension 而不是塞進 enum 本體：這個檔的行號被別處引用著
    /// （`PaneNode.swift:38,44`、`PaneNodeTests.swift:89`、`LayoutDocumentTests.swift:47`、
    /// `EditorWindow.swift:126`），從中間插進去會把它們全部推歪。
    var text: String {
        switch self {
        case let .missingField(text), let .structural(text): text
        }
    }
}
