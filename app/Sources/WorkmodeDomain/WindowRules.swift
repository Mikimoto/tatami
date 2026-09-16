/// 從一個現存的視窗產生一條 windows 規則，以及它依賴的 ERE 轉義。
/// bash 對應：`workmode.sh:335-341` 的 `escape_ere` 與 `:495-505` 的 `rule_for_window`。
///
/// 兩支放同一個檔，是因為 `rule_for_window` 的 title-regex 那條分支就是
/// `escape_ere` 唯一的呼叫點——拆開之後改其中一支不會有人提醒另一支。
public enum WindowRules {
    // MARK: - escape_ere（workmode.sh:335-341）

    /// ERE 的元字元，逐個位元組實測出來的：把 32–126 每個字元單獨餵給 bash，
    /// 被加上反斜線的恰好是這 14 個。控制字元與 0x80 以上一律原樣。
    ///
    /// bash 那側分四趟 sed（`\` → `[` → `]` → 其餘），註解說明那是 BSD sed 對
    /// `[][.*+?^$(){}|]` 這種把 `]` 擺最前面的字元類會回 "unbalanced brackets"。
    /// 那是**寫法**上的限制不是語意差別：後面幾趟的字元類不含 `\`、`[`、`]`，
    /// 所以前面幾趟加上去的反斜線不會被再轉義一次，四趟與這裡的單趟逐位元組
    /// 對映等價。
    private static let metacharacters: Set<UInt8> = Set(#"\[].*+?^$(){}|"#.utf8)

    /// 把一段文字轉成「逐字比對」的 ERE。
    ///
    /// 位元組層級：多位元組字元原樣穿過去，不做正規化，所以 NFC 與 NFD 的同一個
    /// 字各自轉出不同的 pattern——與 `LC_ALL=C sed` 一致。
    ///
    /// 換行不在元字元裡，所以多行輸入等於逐行轉義再接回去；bash 那側
    /// （`printf '%s'` 餵入、BSD sed 不補）也**不**在尾端補換行，這裡同樣不補。
    public static func escapeERE(_ text: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if metacharacters.contains(byte) {
                out.append(0x5C)
            } // '\'
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - rule_for_window（workmode.sh:495-505）

    /// 產生一條 windows 規則。
    ///
    /// - Parameters:
    ///   - label: 使用者給的名稱
    ///   - app: 視窗的 app
    ///   - title: 視窗當下的標題
    ///   - url: Safari 視窗當前分頁的網址；其他 app 傳空字串
    ///   - many: 這次要存的視窗裡同一個 app 是否不只一個（`"1"`／`"0"`）
    ///
    /// 三條分支的順序就是 bash 的 if/elif/else，語意也照抄：
    ///
    /// - 網址那條在最前面，所以 `many` 對 Safari 完全不生效。判斷是 `[ -n "$url" ]`
    ///   ——看空不空，不看像不像網址。
    /// - `many` 是 `[ "$many" = "1" ]` 的**字面**比對，不是真值：`01`、`true`、
    ///   空字串實測都落到 app 那條。
    /// - 標題那條補一條 app fallback，讓標題漂掉時至少還認得出是這個 app 的
    ///   某個視窗。
    public static func rule(label: String, app: String, title: String,
                            url: String, many: String) -> JSONValue
    {
        if !url.isEmpty {
            return object([("label", .string(label)),
                           ("match", .array([.string("url-exact"), .string(url)]))])
        }
        if many == "1" {
            return object([("label", .string(label)),
                           ("match", .array([.string("title-regex"),
                                             .string("^" + escapeERE(title) + "$")])),
                           ("fallback", .array([.string("app"), .string(app)]))])
        }
        return object([("label", .string(label)),
                       ("match", .array([.string("app"), .string(app)]))])
    }

    private static func object(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(pairs.map { JSONMember(key: $0.0, value: $0.1) })
    }
}
