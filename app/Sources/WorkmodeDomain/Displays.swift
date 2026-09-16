/// 一個螢幕。只有這支函式用得到的兩個欄位——其餘欄位（spaces 等）等到有人需要再加。
///
/// Sendable 不是裝飾：Swift 6 的嚴格併發下，測試裡把 fixture 寫成檔案層級的
/// `private let` 就是宣告一個全域變數，型別不是 Sendable 會直接編不過。
/// Domain 的值型別一律加上它。
public struct Display: Equatable, Sendable {
    public let uuid: String
    public let index: Int

    public init(uuid: String, index: Int) {
        self.uuid = uuid
        self.index = index
    }
}

public enum Displays {
    /// bash 對應：`display_index_for_uuid <uuid> <displays-json>`（workmode.sh:12-15）
    ///
    /// 回陣列而不是單一值：那支 jq 是 `.[] | select(.uuid == $u) | .index // empty`，
    /// 串流語意下多筆命中會印多行。差分測試比的是輸出，所以這裡照著回。
    public static func indices(forUUID uuid: String, in displays: [Display]) -> [Int] {
        displays.filter { $0.uuid == uuid }.map(\.index)
    }

    // MARK: - visible_space_on（workmode.sh:20-24）

    /// 該螢幕當下可見的 space。回 nil 代表 jq 的 `empty`——**零位元組**，不是空行。
    ///
    /// 不是「第一個 space」：yabai 不重排不可見 space 上的視窗，而 query 回的 frame
    /// 停在上次套用的值，在背景 space 上量 frame 修方向與順序會永遠讀到舊資料。
    ///
    /// `display` 收 JSONValue 而不是 Int：bash 那側是 `--argjson d`，它可以是任何
    /// JSON 值，而 jq 的 `==` 比的是數值不是字面值（`1.0` 認得出 display 1）也不是
    /// 型別轉換（`"1"` 永遠配不上）。先轉成 Int 就等於在移植之前先改掉那些行為。
    public static func visibleSpace(on display: JSONValue,
                                    in spaces: JSONValue) throws -> JSONValue?
    {
        try firstIndex(in: spaces) { try isVisible($0, on: display) }
    }

    /// `visibleSpace` 與 `visibleSpaceObject` 共用的判斷式。
    ///
    /// 抽出來不是為了少打字，是為了讓兩支**不可能**漂移：它們挑到不同的 space 時，
    /// 症狀是「排的是這一個、名字查的是另一個」，而畫面上完全看不出來。
    ///
    /// jq 的 `and` 短路，Swift 的 `&&` 也是——但左邊那次索引照樣會發生，
    /// 元素不是物件就在這裡報錯。
    private static func isVisible(_ element: JSONValue, on display: JSONValue) throws -> Bool {
        try jqEquals(member(element, "display"), display)
            && jqEquals(member(element, "is-visible"), .bool(true))
    }

    /// 該螢幕當下可見的那個 space 的**整個物件**（上面那支只回 `.index`）。
    ///
    /// `--space` 要的是 uuid：space 的身分要跨重開機穩定，而 index 會在 Mission
    /// Control 增刪 space 時無聲錯位。uuid 撐得過重開機——2026-08-22 實測，現在這
    /// 10 個 uuid 全部出現在四次重開機之前的 unified log 裡（wallpaper 子系統每次
    /// 切 space 都會印 `space: <uuid>`），而且逐字存在
    /// `~/Library/Preferences/com.apple.spaces.plist`。
    ///
    /// 與 `visibleSpace` 的**一個刻意差異**：那支收尾有 `// empty`，`.index` 是 null
    /// 或 false 時回 nil；這支不管 index 長什麼樣，命中就回整個元素。這裡沒有 bash
    /// 對應，沒有要複製那個怪脾氣的義務。
    public static func visibleSpaceObject(on display: JSONValue,
                                          in spaces: JSONValue) throws -> JSONValue?
    {
        for element in try iterate(spaces) where try isVisible(element, on: display) {
            return element
        }
        return nil
    }

    /// uuid 是這個的 space 元素（整個物件），不管它可不可見。`--space --all` 用它：
    /// 那條路不看誰可見，只看「這個 uuid 現在存不存在、在哪台」。
    ///
    /// 沒有 bash 對應。純量元素直接跳過而不是 throw——這裡的輸入是我們自己的
    /// window server 給的，不是要鏡射 jq 的地方。
    public static func spaceObject(uuid: String, in spaces: JSONValue) -> JSONValue? {
        guard case let .array(items) = spaces else { return nil }
        return items.first { (try? member($0, "uuid")) == .string(uuid) }
    }

    // MARK: - other_space_on（workmode.sh:27-31）

    /// 清場用的 space：同螢幕上任何一個不是目標的。回 nil 代表整個螢幕只有目標那一個。
    public static func otherSpace(on display: JSONValue, in spaces: JSONValue,
                                  skipping skip: JSONValue) throws -> JSONValue?
    {
        try firstIndex(in: spaces) { element in
            try jqEquals(member(element, "display"), display)
                && !jqEquals(member(element, "index"), skip)
        }
    }

    /// `first(.[] | select(f) | .index) // empty` 的共同骨架。
    ///
    /// `first` 命中就 break，所以**排在命中之後**的壞元素根本沒被求值（實測
    /// `[{可見的}, 5]` 回 rc=0，`[5, {可見的}]` 才 rc=5）。收尾的 `// empty` 只看
    /// 第一個命中者的 index：它是 null 或 false 就沒有輸出，而 `0` 是真值會照印。
    private static func firstIndex(in spaces: JSONValue,
                                   where matches: (JSONValue) throws -> Bool)
        throws -> JSONValue?
    {
        for element in try iterate(spaces) {
            guard try matches(element) else { continue }
            let index = try member(element, "index")
            return isTruthy(index) ? index : nil
        }
        return nil
    }

    // MARK: - detect_location 的前半（workmode.sh:553-557）

    /// `jq -r '.[].uuid' | tr '\n' ' '`：接在線上的 uuid 串成一行。
    ///
    /// **結尾一定有一個空白**——`tr` 把每個 uuid 後面那個換行換成空白，包含最後一個
    /// （命令替換只吃掉結尾的換行，不吃空白）。`match_location` 的左右補空白比對
    /// 依賴這件事，所以它不是可以順手清掉的髒東西。
    ///
    /// runtime error（元素是純量、或 `.uuid` 索引到陣列）**中止整個串流**，但**已經
    /// 印出來的行留著**：實測 `[{uuid:"A"}, 5, {uuid:"B"}]` 得到 `"A "`，B 連印都沒印。
    /// 根本不是容器（或 query 失敗、空輸入）就是空字串。
    ///
    /// 已知的刻意分歧：`.uuid` 是**容器**時 `jq -r` 印的是多行 pretty JSON，經 `tr`
    /// 之後每個換行變空白。這裡回緊湊形式。yabai 的 uuid 一律是字串，這條走不到，
    /// 而 pretty 印法屬 Wire，Domain 不能為一條不可達的路徑依賴它。
    public static func connectedUUIDs(in displays: JSONValue) -> String {
        var out = ""
        guard let elements = try? iterate(displays) else { return out }
        for element in elements {
            guard let uuid = try? member(element, "uuid") else { return out }
            out += JQPrint.raw(uuid) + " "
        }
        return out
    }

    // MARK: - --displays 的第二個輸入形態

    /// `--displays` 的 JSON → `[Display]`。
    ///
    /// **與 `WorkmodeWire.DisplaysDecoder.decode` 是同一條規則的兩個輸入形態**：
    /// 那一支吃字串（bash 時代的 `__diff` 與讀 stdin 的 `workmode displays` 走它），
    /// 這一支吃已經解析好的 `JSONValue`，因為 `YabaiClient.query` 回的是後者。
    /// 缺 `uuid` 或 `index` 就跳過，與它逐字相同——`listAgreesWithTheWireDecoder`
    /// 把兩支綁在一起，沒有那條測試就是兩份會各自漂移的解析器。
    public static func list(in displays: JSONValue) -> [Display] {
        guard let elements = try? iterate(displays) else { return [] }
        return elements.compactMap { element in
            guard case let .string(uuid)? = try? member(element, "uuid"),
                  case let .number(text)? = try? member(element, "index"),
                  let index = Int(text)
            else { return nil }
            return Display(uuid: uuid, index: index)
        }
    }

    /// 某個 index 的螢幕 frame。`--space` 拿它當 `TreeRects` 的畫布。
    ///
    /// index 比的是**文字**而不是數字：呼叫端手上的是
    /// `LayoutReading.displayIndexText`，那一支回的就是 jq -r 印出來的字面值，
    /// 轉成 Int 再比只是多一個會失敗的環節。
    ///
    /// 四個欄位缺任何一個就回 nil，不當成 0：半個矩形算出來的樹會把視窗排到
    /// 螢幕外，而呼叫端對 nil 的處置是「這台螢幕什麼都不做」，那安全得多。
    public static func frame(ofIndexText indexText: String, in displays: JSONValue) -> Rect? {
        guard let elements = try? iterate(displays) else { return nil }
        for element in elements {
            guard case let .number(text)? = try? member(element, "index"), text == indexText,
                  let frame = try? member(element, "frame") else { continue }
            guard case let .number(originX)? = frame["x"], let xValue = Double(originX),
                  case let .number(originY)? = frame["y"], let yValue = Double(originY),
                  case let .number(width)? = frame["w"], let wValue = Double(width),
                  case let .number(height)? = frame["h"], let hValue = Double(height)
            else { return nil }
            return Rect(originX: xValue, originY: yValue, width: wValue, height: hValue)
        }
        return nil
    }

    // MARK: - match_location（workmode.sh:121-130）

    /// 從設定找出 `displays.main` 出現在 `connected` 裡的那個地點。
    ///
    /// 只比對主螢幕：其餘那幾台沒接時仍要認得出地點，讓那些規則走自己的降級路徑；
    /// 而內建螢幕的 uuid 在多個地點底下都出現，算進去會讓那些地點一起命中。
    ///
    /// 代價是每個地點的 `main` 必須是它獨有的那一台。兩個地點的 `main` 相同時這裡
    /// 回的永遠是寫在前面的那個，而那不是錯誤，是這個判準沒有任何資訊可以區分它們
    /// （2026-08-29 實際踩過：兩地的 `main` 都寫成內建螢幕，於是在家也認成 office）。
    /// 反面的代價是 `main` 那台沒接就認不出那個地點。
    ///
    /// **不 throw**，這是刻意的：bash 那側 jq 的 runtime error 只會印到 stderr，
    /// 函式本身照樣把已經收到的行跑完並 `return 1`。所以中止之前命中的地點還算數，
    /// 之後的整批不見——回 nil 就是那個「沒命中」。
    ///
    /// 回的是 **@tsv 轉義後**的名字，不是原始的鍵：`@tsv` 把 TAB 轉成字面的兩個
    /// 字元，而 bash 拿到的就是轉義後那份（實測鍵 `a<TAB>b` 回來是 `a\tb`）。
    public static func matchLocation(connected: String, in config: JSONValue) -> String? {
        let entries: [(name: JSONValue, value: JSONValue)]
        switch config {
        case let .object(members):
            entries = members.map { (.string($0.key), $0.value) }
        // `to_entries` 對陣列給的是**索引**當 key，對純量才報錯。
        case let .array(items):
            entries = items.enumerated().map { (.number(String($0.offset)), $0.element) }
        default:
            return nil
        }

        // 左右各補一個空白，比對才會落在 uuid 的邊界上。方向與 resolve_profile 相反
        // ——那邊拿使用者給的字當針、清單當草堆所以會有子字串偽陽性，這邊的針是設定
        // 裡的 main，連接清單裡的某個 uuid 只有整個相符才算（2026-08-14 實測確認）。
        // 副作用：main 是空的時候 pattern 收斂成兩個相連的空白，而 connected 為空時
        // 草堆剛好就是兩個空白，於是命中。那是 bash 現行的行為，照抄。
        let haystack = " \(connected) "
        do {
            for entry in entries {
                // 最外層的 windows 是共用視窗總表，不是地點。這道過濾在取
                // `.displays` **之前**，所以它的值是陣列也不會讓串流中止。
                if entry.name == .string(LayoutQuery.reservedKey) {
                    continue
                }
                let name = try tsvField(entry.name)
                let main = try tsvField(member(member(entry.value, "displays"), "main"))
                if name.isEmpty {
                    continue
                }
                if haystack.contains(" \(main) ") {
                    return name
                }
            }
        } catch {
            // jq 的 runtime error 中止整個串流，後面的地點連印都沒印出來。
            return nil
        }
        return nil
    }

    // MARK: - jq 的零件

    /// `.[]`。物件走的是它的**值**；純量報錯（`Cannot iterate over number`）。
    private static func iterate(_ value: JSONValue) throws -> [JSONValue] {
        switch value {
        case let .array(items): return items
        case let .object(members): return members.map(\.value)
        default: throw DisplaysError.runtime
        }
    }

    /// `.[key]`。null 索引出 null（不是錯），物件取成員（沒有就 null），
    /// 其餘型別報錯——**陣列也不行**，字串索引只對物件成立。
    private static func member(_ value: JSONValue, _ key: String) throws -> JSONValue {
        switch value {
        case .null: return .null
        case .object: return value[key] ?? .null
        default: throw DisplaysError.runtime
        }
    }

    private static func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case let .bool(flag): flag
        default: true
        }
    }

    /// `JQPrint.tsvField` 的 throwing 外衣（容器 ＝ jq 的 runtime error
    /// `object ({"k":1}) is not valid in a csv row`，而這裡用 throws 表示串流中止）。
    ///
    /// 為什麼轉義的正確性在這個檔案裡特別要緊：這邊的 `@tsv` 不只是**印法**，
    /// 而是**規則的一部分**——match_location 回傳與比對的都是轉義後的文字，
    /// 所以轉義的結果會改變答案，不只是改變輸出。那個理由現在寫在 `JQPrint` 的
    /// 型別註解上，因為印法收成一份之後，借用它的每一處都繼承同一個責任。
    private static func tsvField(_ value: JSONValue) throws -> String {
        guard let field = JQPrint.tsvField(value) else { throw DisplaysError.runtime }
        return field
    }
}

public enum DisplaysError: Error, Equatable, Sendable {
    /// jq 的 runtime error：`.[]` 碰到純量、字串索引碰到非物件、`@tsv` 碰到容器。
    /// bash 那側 visible_space_on 與 other_space_on 的 exit code 是 5；
    /// match_location 把它吞掉，見那支的 doc。
    case runtime
}

/// jq 的 `==`。**不是** JSONValue 自動合成的 Equatable：那個比的是數字的字面值，
/// 而 jq 比的是數值（`1 == 1.0` 為真），物件也不看鍵序（`{"a":1,"b":2}` 等於
/// `{"b":2,"a":1}`，實測）。型別不同一律不相等，`null == false` 是 false。
///
/// 只做相等不做全序：LayoutTree 那份 `order` 是為了 `sort_by` 與 `group_by`，
/// 這裡兩支函式只需要 `==` 與 `!=`。
func jqEquals(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null):
        return true
    case let (.bool(left), .bool(right)):
        return left == right
    case let (.number(left), .number(right)):
        // 解不出 Double 的字面值退回逐字比較，那至少仍是個等價關係。
        guard let leftValue = Double(left), let rightValue = Double(right) else {
            return left == right
        }
        return leftValue == rightValue
    case let (.string(left), .string(right)):
        return left == right
    case let (.array(left), .array(right)):
        return left.count == right.count && zip(left, right).allSatisfy { jqEquals($0, $1) }
    case let (.object(left), .object(right)):
        guard left.count == right.count else { return false }
        return left.allSatisfy { member in
            guard let other = right.first(where: { $0.key == member.key }) else { return false }
            return jqEquals(member.value, other.value)
        }
    default:
        return false
    }
}
