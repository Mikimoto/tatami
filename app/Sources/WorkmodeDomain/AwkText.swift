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

// MARK: - awk 的字串與數值語意

public enum AwkText {
    /// awk `-v` 認得的八個單位元組跳脫。用表而不是 switch：這是一份對照表，
    /// 八筆資料不是八種邏輯（與 JSONParser 那份同一個判斷）。
    static let singleByteEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "\\"): 0x5C,
        UInt8(ascii: "n"): 0x0A,
        UInt8(ascii: "t"): 0x09,
        UInt8(ascii: "b"): 0x08,
        UInt8(ascii: "f"): 0x0C,
        UInt8(ascii: "r"): 0x0D,
        UInt8(ascii: "v"): 0x0B,
        UInt8(ascii: "a"): 0x07,
    ]

    /// `\NNN`：最多**三位**八進位（首位已經吃掉了，這裡最多再吃兩位），
    /// 溢位截斷成一個位元組。
    static func octalEscape(_ first: UInt8, in source: [UInt8], index: inout Int) -> UInt8 {
        var value = Int(first - UInt8(ascii: "0"))
        for _ in 0 ..< 2 {
            guard index < source.count, isDigit(source[index]) else { break }
            value = value * 8 + Int(source[index] - UInt8(ascii: "0"))
            index += 1
        }
        return UInt8(truncatingIfNeeded: value)
    }

    /// `awk -v n="…"` 對值做的跳脫處理。
    ///
    /// 這不是裝飾：`find_windows` 的 url-exact／url-contains 是用 `-v` 傳值的，
    /// 所以網址裡的 `\t` 會變成一個真的 TAB、`\\` 會塌成一個反斜線。title-regex
    /// 改走 ENVIRON 就是為了躲開這件事（ENVIRON 拿到的是**原文**，實測 `a\tb`
    /// 過 -v 得到 `a<TAB>b`、過 ENVIRON 得到四個字元）。
    ///
    /// 與 regex 的跳脫有兩處不同，不要合併：收尾的孤零零反斜線在這裡是**字面的
    /// 反斜線**（regex 那邊是空 pattern），而 `\0` 產生的 NUL 會讓 awk 的 C 字串
    /// 在那裡結束（實測 `a\0b` 拿到的值只有 `a`）——後者這裡照做。
    public static func expandAssignmentEscapes(_ text: String) -> [UInt8] {
        let source = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < source.count {
            let byte = source[index]
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < source.count else {
                out.append(UInt8(ascii: "\\"))
                break
            }
            let escaped = source[index]
            index += 1
            let produced: UInt8 = if let mapped = singleByteEscapes[escaped] {
                mapped
            } else if isDigit(escaped) {
                octalEscape(escaped, in: source, index: &index)
            } else {
                // awk 對不認得的跳脫是**丟掉反斜線、留下那個字元**。
                escaped
            }
            // C 字串在 NUL 結束。
            if produced == 0 {
                return out
            }
            out.append(produced)
        }
        return out
    }

    /// Swift 的 Double 認 `0x10` 但不認 `0X10`，strtod 兩個都認。
    static func lowercasedHexPrefix(_ token: [UInt8]) -> [UInt8] {
        guard token.count > 1, token[0] == UInt8(ascii: "0") || token.count > 2 else {
            return token
        }
        var out = token
        for position in out.indices where out[position] == UInt8(ascii: "X") {
            if position > 0, out[position - 1] == UInt8(ascii: "0") {
                out[position] = UInt8(ascii: "x")
            }
        }
        return out
    }

    /// awk 的「numeric string」判定，照 20200816 的 `is_number()`：
    /// strtod 吃得完整串（前後允許空白）、結果不是 `+HUGE_VAL`、也沒有 ERANGE。
    ///
    /// 四個實測結論，每一個都與直覺相反：
    ///   * `0x10` **是**數值（這版沒有擋十六進位，`0x10 == 16` 為真）；
    ///   * `inf` 與 `Infinity` **不是**（`r == HUGE_VAL` 那條把正無限大排除，
    ///     所以 `inf == Infinity` 為假、走字串比較）；
    ///   * `-inf` **是**（只擋正的），而 `nan` 也是（`nan == NaN` 實測為真——
    ///     awk 用相減的三分法，NaN 兩邊都不成立就落在「相等」）；
    ///   * `1e400`（溢位）與 `1e-400`（下溢）都因為 ERANGE 而不是數值。
    public static func number(_ bytes: [UInt8]) -> Double? {
        var index = 0
        // strtod 自己跳過開頭的 isspace，含 \v 與 \f。
        while index < bytes.count, isStrtodSpace(bytes[index]) {
            index += 1
        }
        let tokenStart = index
        guard let tokenEnd = scanNumberToken(bytes, from: index) else { return nil }
        index = tokenEnd
        // awk 收尾只放行這四個，\v 與 \f 不算（實測 `1<VT>` 不是數值）。
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09
              || bytes[index] == 0x0A || bytes[index] == 0x0D
        {
            index += 1
        }
        guard index == bytes.count else { return nil }

        let token = lowercasedHexPrefix(Array(bytes[tokenStart ..< tokenEnd]))
        // strtod 的 `nan(n-char-sequence)` 形式（實測欄位 `nan(x)` 與任何數值都相等，
        // 因為 awk 用相減的三分法而 NaN 兩邊都不成立）。Swift 的 Double 不收括號，
        // 所以在這裡就短路掉——括號裡的字串只影響 payload，不影響比較。
        if tokenIsNaN(token) {
            return Double.nan
        }
        guard let value = Double(String(decoding: token, as: UTF8.self)) else { return nil }

        return withinStrtodRange(value, token: token)
    }

    /// strtod 的兩道 range 檢查。分開是因為它們判的是**同一個 Double 的兩端**，
    /// 而中間那段（正常的有限值）什麼都不必做。
    ///
    /// 上端：`r == HUGE_VAL` 擋正無限大；負的只有在 ERANGE（溢位）時才擋，
    /// 所以字面上就寫著 `-inf` 的那個要放行。
    /// 下端：算出來是 0 或次正規，但字面上的尾數不是零——那是 ERANGE 的下溢。
    static func withinStrtodRange(_ value: Double, token: [UInt8]) -> Double? {
        if value.isInfinite {
            guard value < 0, tokenIsInfinity(token) else { return nil }
            return value
        }
        if value == 0 || value.magnitude < Double.leastNormalMagnitude,
           !tokenIsZero(token)
        {
            return nil
        }
        return value
    }

    /// awk 的 `==`：兩邊都是 numeric string 就比數值，否則逐位元組比字串。
    ///
    /// 數值那條用相減的三分法而不是 `==`，這樣 NaN 才會落在「相等」——實測
    /// `nan == NaN` 為真，用 Swift 的 `==` 會得到相反的答案。
    public static func equals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        if let left = number(lhs), let right = number(rhs) {
            let delta = left - right
            return !(delta < 0) && !(delta > 0)
        }
        return lhs == rhs
    }

    /// awk 的 `index(s, t) > 0`。空的針只在草堆非空時算命中——awk 的外層迴圈
    /// 條件是 `*p1`，所以 `index("", "")` 是 0 而 `index("a", "")` 是 1（實測
    /// `find_windows url-contains '' ''` 零輸出，餵真 dump 則整份命中）。
    public static func indexFound(haystack: [UInt8], needle: [UInt8]) -> Bool {
        guard !haystack.isEmpty else { return false }
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        for start in 0 ... (haystack.count - needle.count) {
            var matched = true
            for offset in 0 ..< needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched {
                return true
            }
        }
        return false
    }
}
