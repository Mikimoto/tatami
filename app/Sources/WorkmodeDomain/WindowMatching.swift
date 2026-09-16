// 視窗比對的三支：find_windows、current_tab_url、id_for_label。
//
// 三支的對照組都是 awk 或 bash 的字串處理，不是 jq，所以這一整份都在**位元組**上
// 工作而不是 Character 上。三個實測理由，缺一不可：
//   1. bash 的 `[ "$a" = "$b" ]` 與 awk 的比較都是逐位元組——同一個字的 NFC 與 NFD
//      在 bash 不相等（實測 `é` 的 c3a9 與 65cc81 回 rc=1），而 Swift 的 `String ==`
//      會說相等。用 Character 比就是靜默改行為。
//   2. `\r\n` 在 Swift 是**一個** Character，在 awk 是「記錄結尾多一個 \r」。
//   3. awk 的 `.` 吃一個**位元組**（實測 `^.$` 配不上三位元組的「終」，`^...$` 才配）。
//      這台的 awk 是 20200816，早於 one-true-awk 的 UTF-8 支援，而 title-regex 那條
//      還額外帶 LC_ALL=C。

// MARK: - 三支函式

public enum WindowMatchError: Error, Equatable, Sendable {
    /// 設定裡的 match 類型不是那四個。bash 印一行到 stderr 並 `return 2`，
    /// 讓呼叫端能區分「沒命中」與「設定寫錯」。
    case unknownKind(String)
    /// title-regex 的 pattern 編不起來。bash 那側是 awk 自己 exit 2，
    /// 而 `set -o pipefail` 讓整條管線也回 2——與未知類型**同一個 rc**，
    /// 差別只在 stderr 印的是誰的訊息。
    case badPattern
}

public enum WindowMatching {
    /// 一筆記錄對上這條規則了沒。四種 kind 窮舉，沒有 default。
    ///
    /// `.app` 永遠回 false：這支根本不該被 `app` 呼叫（上面已經先 return nil 了），
    /// 但把它留在 switch 裡才有窮舉保證。
    private static func matches(kind: Kind, columns: [[UInt8]],
                                needle: [UInt8], regex: AwkRegex?) -> Bool
    {
        switch kind {
        case .app:
            false
        case .urlExact:
            // `$2 == n || $2 == n "/"`。前一半是 awk 的 == （兩邊都是 numeric
            // string 時比數值，實測 `1e3` 配得上欄位 `1000`）；後一半的右手邊
            // 是**串接**出來的純字串，所以只會做字串比較。
            AwkText.equals(column(columns, 2), needle)
                || column(columns, 2) == needle + [UInt8(ascii: "/")]
        case .urlContains:
            AwkText.indexFound(haystack: column(columns, 2), needle: needle)
        case .titleRegex:
            regex?.matches(bytes: column(columns, 3)) ?? false
        }
    }

    /// dump 的每行是 `<window_id>\t<url>\t<tab title>`（current_tab_url 用的那份
    /// 多一欄 is-current）。
    ///
    /// bash 對應：`find_windows <type> <value> <dump>`（workmode.sh:527-538）。
    ///
    /// 回 nil 是 `app` 那條：它不吃分頁 dump（分頁清單只涵蓋 Safari），
    /// **直接 return 0 而且一個位元組都不印**，代表「這個類型不由我處理」。
    ///
    /// 回的清單已經照位元組排序並去重（bash 是 `sort -u`）。這裡有一個**刻意的
    /// 分歧**：bash 的 sort 跑在 en_US.UTF-8 的定序下，而 macOS 的那份定序把所有
    /// 非 ASCII 字串視為**彼此相等**——實測三筆 id `終`／`工`／`9` 過 `sort -u`
    /// 只剩 `終` 與 `9`，`工` 被當成重複的丟掉。window id 一律是十進位整數
    /// （已用 400 組隨機數字字串驗過兩種定序逐位元組相同），所以這裡用位元組序；
    /// 差分語料因此只放數字 id。
    public static func findWindows(kind rawKind: String, value: String,
                                   dump: String) throws -> [String]?
    {
        guard let kind = Kind(rawValue: rawKind) else {
            throw WindowMatchError.unknownKind(rawKind)
        }
        if kind == .app {
            return nil
        }

        // title-regex 的 pattern 走 ENVIRON（原文），其餘兩個走 -v（會被跳脫處理）。
        let needle = kind == .titleRegex ? [] : AwkText.expandAssignmentEscapes(value)
        var regex: AwkRegex?
        if kind == .titleRegex {
            do {
                regex = try AwkRegex(patternBytes: Array(value.utf8))
            } catch {
                throw WindowMatchError.badPattern
            }
        }

        var ids: [[UInt8]] = []
        for record in records(of: dump) {
            let columns = fields(of: record)
            if matches(kind: kind, columns: columns, needle: needle, regex: regex) {
                ids.append(column(columns, 1))
            }
        }

        ids.sort(by: bytesAscending)
        var unique: [[UInt8]] = []
        for id in ids where unique.last != id {
            unique.append(id)
        }
        return unique.map { String(decoding: $0, as: UTF8.self) }
    }

    public enum Kind: String, Sendable, CaseIterable {
        case app
        case urlExact = "url-exact"
        case urlContains = "url-contains"
        case titleRegex = "title-regex"
    }

    /// 某個 Safari 視窗當前分頁的網址。dump 的第四欄是 is-current。
    /// bash 對應：`current_tab_url <window id> <dump>`（workmode.sh:478-480）。
    ///
    /// 兩個比較的語意**不同**，不要統一：`$1 == w` 兩邊都是 numeric string
    /// （欄位與 -v 的值都有那個屬性），所以 `191` 配得上欄位 `191.0`；
    /// 而 `$4 == "1"` 的右手邊是字串常數，所以 `1.0` 與 ` 1` 都不算當前分頁。
    ///
    /// 回 nil 是「沒有這個視窗」，呼叫端印零位元組；有值的話 awk 的 `print`
    /// 會補一個換行。
    public static func currentTabURL(window: String, dump: String) -> String? {
        let want = AwkText.expandAssignmentEscapes(window)
        for record in records(of: dump) {
            let columns = fields(of: record)
            guard AwkText.equals(column(columns, 1), want),
                  column(columns, 4) == [UInt8(ascii: "1")] else { continue }
            return String(decoding: column(columns, 2), as: UTF8.self)
        }
        return nil
    }

    /// 從 label→id 的對應裡查一個 label。
    /// bash 對應：`id_for_label <label> <map>`（workmode.sh:725-731）。
    ///
    /// bash 那側用 while 迴圈而不是 awk，唯一的理由是 macOS 的 awk 在 UTF-8
    /// locale 下對多位元組做 `$1 == "中文"` 會匹配到**任何**多位元組的 `$1`
    /// （實測 `$1=="終端機"` 連「工作瀏覽」那行也印出來）。Swift 沒有這個毛病，
    /// 但這裡要複製的是 bash 的行為而不是「更好的行為」。
    ///
    /// 四個 `read` 的細節都會改變答案，一個都不能省（全部實測過）：
    ///   * `IFS=$'\t'` 而 TAB 是 IFS 空白，所以**連續的 TAB 算一個分隔符**，
    ///     而且行首行尾的 TAB 會被吃掉（`<TAB>A<TAB>1` 的 key 是 `A` 不是空字串）；
    ///   * `read -r k v` 只有兩個變數，所以 v 拿到**剩下全部**含中間的 TAB
    ///     （`A<TAB>1<TAB>2` 的 v 是 `1<TAB>2`），但結尾的 TAB 仍會被剝掉；
    ///   * 沒有 TAB 的一行：k 是整行、v 是空字串，命中時印零位元組而 rc=0；
    ///   * 比較是 `[ "$k" = "$want" ]`，位元組級——NFC 與 NFD 的同一個字不相等。
    ///
    /// 回 nil 是 rc=1。有值時 bash 用 `printf '%s'`，**沒有結尾換行**。
    public static func idForLabel(_ want: String, in map: String) -> String? {
        let target = Array(want.utf8)
        for record in records(of: map) {
            let (key, value) = splitOnIFSTab(record)
            if key == target {
                return String(decoding: value, as: UTF8.self)
            }
        }
        return nil
    }

    // MARK: awk／bash 的切割

    /// awk 的記錄切割。bash 那側是 `printf '%s\n' "$dump" | awk`，所以尾端一定
    /// 補一個換行——空的 dump 因此是**一筆空記錄**而不是零筆（實測
    /// `find_windows url-exact '' ''` 印出一個換行，也就是一個空的 id）。
    static func records(of text: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in Array(text.utf8) {
            if byte == 0x0A {
                out.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        // printf 補的那個換行剛好收掉最後一筆；text 自己就以換行結尾時，
        // 補的那個會多生出一筆空記錄，這裡照樣還原。
        out.append(current)
        return out
    }

    /// `-F'\t'` 的欄位切割。空記錄的 NF 是 0，取任何欄位都是空字串。
    static func fields(of record: [UInt8]) -> [[UInt8]] {
        guard !record.isEmpty else { return [] }
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in record {
            if byte == 0x09 {
                out.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        out.append(current)
        return out
    }

    static func column(_ columns: [[UInt8]], _ number: Int) -> [UInt8] {
        number >= 1 && number <= columns.count ? columns[number - 1] : []
    }

    /// `IFS=$'\t' read -r k v`。TAB 是 IFS 空白，所以前後的 TAB 整段吃掉、
    /// 中間連續的 TAB 算一個分隔符。
    static func splitOnIFSTab(_ record: [UInt8]) -> (key: [UInt8], value: [UInt8]) {
        var start = 0
        var end = record.count
        while start < end, record[start] == 0x09 {
            start += 1
        }
        while end > start, record[end - 1] == 0x09 {
            end -= 1
        }
        var index = start
        while index < end, record[index] != 0x09 {
            index += 1
        }
        let key = Array(record[start ..< index])
        while index < end, record[index] == 0x09 {
            index += 1
        }
        return (key, Array(record[index ..< end]))
    }

    static func bytesAscending(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        for offset in 0 ..< min(lhs.count, rhs.count) where lhs[offset] != rhs[offset] {
            return lhs[offset] < rhs[offset]
        }
        return lhs.count < rhs.count
    }
}
