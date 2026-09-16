import WorkmodeDomain

/// `ApplyLayout` 與 `SaveLayout` 共用的「讀設定」那一層。
///
/// 這些函式看起來像瑣碎的取值，實際上每一支都記著一個 bash／jq 的實測行為：
/// 多筆命中時 display index 是**兩行**（於是 `--argjson` 失敗）、`printf '%s\n'`
/// 讓空的 rules 變成 `[""]` 而不是 `[]`、未加引號的命令替換會按 IFS 把角色名切開。
/// 兩支 use case 各抄一份的話，那些知識就會開始漂移——而它們沒有差分基準可以擋。
///
/// 帶著 `renderRaw` 而不是每支都收一個參數：jq 的 `-r` 印法對容器要縮排格式，
/// 那需要 Wire 的 writer，而 Core 不能 import Wire，所以它一路都是注入的。
struct LayoutReading {
    let renderRaw: (JSONValue) -> String

    /// `location_desc` 經過命令替換之後的樣子。
    func describe(_ location: String, in config: JSONValue) -> String {
        guard let described = (try? LayoutQuery.locationDescription(location, in: config)) ?? nil
        else { return "" }
        return CommandSubstitution.capture(renderRaw(described))
    }

    /// `windows_for` 的五欄 TSV，就是 `resolve_rules` 吃的那份文字。
    func windowRulesText(location: String, profile: String,
                         in config: JSONValue) -> String
    {
        var lines: [String] = []
        do {
            try LayoutQuery.windowRules(location: location, profile: profile, in: config) { rule in
                var fields: [String] = []
                for value in [rule.label, rule.matchKind, rule.matchValue,
                              rule.fallbackKind, rule.fallbackValue]
                {
                    // `@tsv` 對容器是 runtime error，而它是**整列**一起轉的——
                    // 所以出錯的那一列一個位元組都不印，不是印出前幾欄。
                    guard let field = JQPrint.tsvField(value) else {
                        throw LayoutQueryError.runtime
                    }
                    fields.append(field)
                }
                lines.append(fields.joined(separator: "\t"))
            }
        } catch {
            // jq 串流中止：已經印出去的列留著（`$( )` 收得到）。
        }
        return lines.joined(separator: "\n")
    }

    /// `live=$(printf '%s\n' "${rules}" | cut -f1 | jq -R . | jq -sc .)`（workmode.sh:1323）。
    ///
    /// `printf '%s\n'` 補的那個換行是有作用的：`rules` 是空字串時它產生**一行空的**，
    /// 於是 live 是 `[""]` 而不是 `[]`。差別看得見——label 是空字串的葉子會被留下來。
    func liveLabels(of rules: String) -> JSONValue {
        var lines = (rules + "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines.removeLast() // `printf` 補的那個換行不是一行
        // `cut -f1`：沒有 tab 的行整行輸出（不是空字串）。
        return .array(lines.map { line in
            .string(line.split(separator: "\t", maxSplits: 1,
                               omittingEmptySubsequences: false).first.map(String.init) ?? line)
        })
    }

    /// `for role in $(printf '%s' "${trees}" | jq -r 'keys_unsorted[]')`（workmode.sh:1325）。
    ///
    /// 未加引號的命令替換：bash 按 IFS（空白、tab、換行）切詞，所以角色名含空白的話
    /// 會被切成兩個角色（而那兩個都找不到 display，於是各印一句「沒定義這個角色」）。
    /// 照抄那個切法。
    ///
    /// 已知的刻意分歧：bash 那一步還會做**路徑展開**，角色名叫 `*` 時會被換成 cwd 的
    /// 檔名清單。不複製它——它取決於執行時的工作目錄，而 Swift 這側沒有等價的東西。
    func roles(of trees: JSONValue) -> [String] {
        let keys: [String]
        switch trees {
        case let .object(members): keys = members.map(\.key)
        // `keys_unsorted` 對陣列回的是索引。
        case let .array(items): keys = (0 ..< items.count).map(String.init)
        // 純量（含 null）是 runtime error＝零輸出＝迴圈一圈都不跑。
        default: return []
        }
        return keys.flatMap { key in
            key.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        }
    }

    /// `location_display` 經過 `[ -z "${uuid}" ]` 之後的樣子：nil ＝ 那句 `-z` 為真。
    func displayUUID(of role: String, location: String,
                     in config: JSONValue) -> String?
    {
        guard let value = (try? LayoutQuery.locationDisplay(location, role: role,
                                                            in: config)) ?? nil
        else { return nil }
        let text = renderRaw(value)
        return text.isEmpty ? nil : text
    }

    /// `display_index_for_uuid`（workmode.sh:12-15）：`.[] | select(.uuid == $u) | .index // empty`。
    ///
    /// 回的是**文字**而不是 `[Int]`：bash 拿它去餵 `--argjson`，而多筆命中時那段文字
    /// 有兩行、根本不是合法的 JSON。`Displays.indices(forUUID:in:)` 收的是
    /// `[Display]`，那要 Wire 的 decoder（Core 不許 import Wire），而它也已經把
    /// 「index 不是整數」這種形狀正規化掉了。
    func displayIndexText(forUUID uuid: String, in displays: JSONValue) -> String {
        let elements: [JSONValue]
        switch displays {
        case let .array(items): elements = items
        case let .object(members): elements = members.map(\.value)
        default: return ""
        }
        var out: [String] = []
        for element in elements {
            switch element {
            case .object, .null: break
            // 純量在 `.uuid` 那次索引中止串流，前面印出去的留著。
            default: return out.joined(separator: "\n")
            }
            // `--arg u` 恆為字串，所以只有同一個字串相等（逐位元組，jq 不做正規化）。
            guard case let .string(text) = element["uuid"] ?? .null,
                  Array(text.utf8) == Array(uuid.utf8) else { continue }
            let index = element["index"] ?? .null
            // `// empty`：null 與 false 什麼都不印，`0` 是真值會照印。
            switch index {
            case .null, .bool(false): continue
            default: out.append(renderRaw(index))
            }
        }
        return out.joined(separator: "\n")
    }

    /// `.[key]`（可串接）。null 索引出 null，物件取成員，其餘型別報錯。
    ///
    /// Domain 那三份副本（LayoutQuery／LayoutTree／Displays）全是 private，而 Core
    /// 不許 import Wire 也沒有一個共用的 jq 層——這裡只用到「取成員」這一個運算，
    /// 抄三行比為它開一個新的公開介面便宜，而它的語意由那三份的 doc 釘著。
    func member(_ value: JSONValue, _ keys: String...) throws -> JSONValue {
        var current = value
        for key in keys {
            switch current {
            case .null: return .null
            case .object: current = current[key] ?? .null
            default: throw LayoutQueryError.runtime
            }
        }
        return current
    }
}
