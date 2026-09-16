/// 狀態檔的讀寫。一行一個 `key=value`。
/// bash 對應：`workmode.sh:157-171` 的 `state_get` 與 `:178-195` 的 `state_set`。
///
/// 兩支共用同一套解析（剝行首空白 → 跳過註解與空行 → 第一個 `=` 切開 → 剝 key
/// 尾端空白 → 同一個 key 後面蓋前面），所以放同一個檔；解析歪掉時讀與寫會一起
/// 歪，分開放只會讓那件事更難發現。
public enum StateFile {
    /// `state_set` 一定會印的第一行。
    private static let header =
        "# workmode 狀態檔，由 --switch 寫入。手改也可以，一行一個 key=value。\n"

    // MARK: - 共用的解析

    /// 一筆解析出來的 `key=value`，兩側都是位元組。
    private struct Entry {
        var key: [UInt8]
        var value: [UInt8]
    }

    /// 照 awk 那段逐行解析。註解、空行、沒有 `=` 的行都丟掉；同一個 key 後面蓋前面。
    ///
    /// LC_ALL=C 不是裝飾：key 會嵌入地點名稱，而地點名稱可能是中文。macOS 的 awk
    /// 在 UTF-8 locale 下拿多位元組字串比對會對「任何多位元組的欄位」都成立，
    /// 過濾等於沒過濾。所以這裡一路走位元組，不用 Swift 的 `String ==`（後者做
    /// Unicode 正規化等價，NFC 的 key 會取到 NFD 那筆）。
    private static func entries(in content: String) -> [Entry] {
        var out: [Entry] = []
        var index: [[UInt8]: Int] = [:]
        for line in splitOnNewlineBytes(content) {
            var bytes = Array(line.utf8)
            // `sub(/^[ \t]+/, "")`
            var start = 0
            while start < bytes.count, bytes[start] == 0x20 || bytes[start] == 0x09 {
                start += 1
            }
            bytes = Array(bytes[start...])
            // 註解與空行的判斷在剝掉行首空白**之後**。
            if bytes.first == 0x23 {
                continue
            } // '#'
            if bytes.isEmpty {
                continue
            }
            guard let equals = bytes.firstIndex(of: 0x3D) else { continue } // '='
            var key = Array(bytes[..<equals])
            // `sub(/[ \t]+$/, "", key)`——只剝 key 那側，值那側原樣留著。
            while let last = key.last, last == 0x20 || last == 0x09 {
                key.removeLast()
            }
            let value = Array(bytes[bytes.index(after: equals)...])
            // awk 的 `v[key] = …`：後面那筆蓋掉前面那筆，位置不變。位置其實
            // 影響不到輸出（`state_set` 結尾整份重排），留著是為了讓這層的行為
            // 與 awk 的關聯陣列對得上。
            if let seen = index[key] {
                out[seen].value = value
            } else {
                index[key] = out.count
                out.append(Entry(key: key, value: value))
            }
        }
        return out
    }

    // MARK: - state_get（workmode.sh:157-171）

    /// 從狀態檔內容取某個 key 的值。同一個 key 出現多次取**最後**一筆。
    ///
    /// 找不到、或最後一筆的值是空的，都回空字串。「最後一筆是空的」與「沒有這個
    /// key」不可區分，是 awk 的 `END { if (v != "") print v }` 決定的——空值會覆蓋
    /// 掉前面那筆非空的。
    public static func value(forKey key: String, in content: String) -> String {
        let target = Array(key.utf8)
        guard let found = entries(in: content).first(where: { $0.key == target }),
              !found.value.isEmpty else { return "" }
        return String(decoding: found.value, as: UTF8.self)
    }

    // MARK: - state_set（workmode.sh:178-195）

    /// 回傳更新後的**完整**狀態檔內容（含開頭那行註解與結尾換行）。
    /// `value` 為空字串表示刪除該 key。
    ///
    /// 整份重建而不是追加：追加會讓同一個 key 累積多筆，而讀的時候只會拿到其中
    /// 一筆，於是「我明明改過了」與「它讀到的」會漸行漸遠。認不得的 key 原樣保留，
    /// 之後加欄位不會讓舊檔失效。
    ///
    /// **輸出順序取決於什麼**：bash 那側是
    /// `awk … | LC_ALL=C sort -u`，再把新的那筆接上去，整包再過一次 `LC_ALL=C sort`。
    /// 所以 awk 的 `for (key in v)` 那個實作定義的迭代順序**決定不了任何事**——
    /// 它在最外層那次排序被整個洗掉。實際的順序是：
    ///
    /// - 對**整行** `key=value` 做位元組升冪，不是只對 key。`b2=0` 因此排在 `b=1`
    ///   前面（第二個位元組 `2`=0x32 < `=`=0x3D），真實的 key 也會踩到：
    ///   `profile.home` 排在 `profile` 前面。
    /// - `LC_ALL=C`，所以是位元組序不是 locale 定序：大寫全在小寫前，非 ASCII 最後，
    ///   數字型的 key 照字面排（`100` < `10` < `2` < `9`）。
    /// - 最外層那次**沒有** `-u`，所以新加的那行與既有的某行撞成同一個字串時兩筆
    ///   都留著。
    ///
    /// 註解那行是在管線**之外**印的，所以它永遠在第一行，不參與排序。
    ///
    /// 順帶一提 bash 那側的 **rc**：刪除（`value` 為空）時是 **1**，不是 0。
    /// `workmode.sh:4` 開了 `pipefail`，而區塊的最後一個命令是
    /// `[ -n "$value" ] && printf …`——值為空時那個 AND 串列回 1，pipefail 就把
    /// 整條管線的 rc 變成 1。內容照樣印出來而且是對的，rc 只是短路的副作用。
    /// 這裡回的是內容；rc 的鏡射是 `__diff` 那層的事（真命令用自己的慣例）。
    public static func set(_ content: String, key: String, value: String) -> String {
        let target = Array(key.utf8)
        // 內層：重建既有的每一筆，被指名的那個 key 先拿掉。
        var lines = entries(in: content)
            .filter { $0.key != target }
            .map { $0.key + [0x3D] + $0.value }
        // `sort -u`。key 已經去重過，所以這裡的 `-u` 撞不到東西，照抄是為了
        // 讓「哪一層去重」這件事留在程式碼裡——外層那次沒有 -u，差別看得見。
        lines = dedupeAdjacent(byteSorted(lines))

        // 外層：接上新的那筆再整包重排。`printf '%s=%s\n'` 的產物是餵給 sort 的
        // **文字**不是一筆記錄，所以值裡的換行會把它切成好幾筆各自去排。
        if !value.isEmpty {
            lines += records(in: Array(key.utf8) + [0x3D] + Array(value.utf8) + [0x0A])
        }
        lines = byteSorted(lines)

        var out = Array(header.utf8)
        for line in lines {
            out += line
            out.append(0x0A)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 把一段文字切成 sort 看到的那些記錄：以 `\n` 分隔，結尾那個 `\n` 是終止符
    /// 不是一筆空記錄。
    private static func records(in text: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in text {
            if byte == 0x0A {
                out.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            out.append(current)
        }
        return out
    }

    private static func byteSorted(_ lines: [[UInt8]]) -> [[UInt8]] {
        lines.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private static func dedupeAdjacent(_ lines: [[UInt8]]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        for line in lines where out.last != line {
            out.append(line)
        }
        return out
    }
}
