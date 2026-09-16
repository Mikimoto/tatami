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

// `AwkText.number` 底下那組 strtod 的掃描器。與 AwkText 分開只是為了型別長度。
//
// 同樣從 private 放寬成 internal：private 是檔案範圍，跨檔的 extension 看不到。

extension AwkText {
    static func isStrtodSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    static func tokenIsInfinity(_ token: [UInt8]) -> Bool {
        var body = token
        if let first = body.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            body.removeFirst()
        }
        let lowered = body.map { $0 | 0x20 }
        return lowered == Array("inf".utf8) || lowered == Array("infinity".utf8)
    }

    static func tokenIsNaN(_ token: [UInt8]) -> Bool {
        var body = token
        if let first = body.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            body.removeFirst()
        }
        guard body.count >= 3 else { return false }
        return body[0 ..< 3].map { $0 | 0x20 } == Array("nan".utf8)
    }

    /// 字面上的尾數是不是零（`0`、`0.000`、`0x0`、`+0.0e5` 都算）。
    static func tokenIsZero(_ token: [UInt8]) -> Bool {
        for byte in token {
            if isDigit(byte), byte != UInt8(ascii: "0") {
                return false
            }
            if (byte | 0x20) >= UInt8(ascii: "a"), (byte | 0x20) <= UInt8(ascii: "f") {
                // 十六進位的 a–f 只有在 0x 之後才是尾數；e／p 是指數記號，
                // 兩者都不影響「尾數是零」的判斷，除了 a–d、f 這幾個真數字。
                let lowered = byte | 0x20
                if lowered != UInt8(ascii: "e"), lowered != UInt8(ascii: "p") {
                    return false
                }
            }
        }
        return true
    }

    /// strtod 吃得下的最長前綴的結尾位置。回 nil 代表一個字元都吃不到。
    static func scanNumberToken(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        if index < bytes.count,
           bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
        {
            index += 1
        }
        if let end = scanWord(bytes, from: index, word: "infinity") {
            return end
        }
        if let end = scanWord(bytes, from: index, word: "inf") {
            return end
        }
        if let end = scanWord(bytes, from: index, word: "nan") {
            // strtod 收 `nan(` 英數與底線 `)`；括號沒收好就退回只吃 `nan`。
            guard end < bytes.count, bytes[end] == UInt8(ascii: "(") else { return end }
            var probe = end + 1
            while probe < bytes.count, isNaNPayload(bytes[probe]) {
                probe += 1
            }
            guard probe < bytes.count, bytes[probe] == UInt8(ascii: ")") else { return end }
            return probe + 1
        }
        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "0"),
           (bytes[index + 1] | 0x20) == UInt8(ascii: "x")
        {
            return scanHex(bytes, from: index + 2) ?? scanDecimal(bytes, from: index)
        }
        return scanDecimal(bytes, from: index)
    }

    static func scanWord(_ bytes: [UInt8], from start: Int, word: String) -> Int? {
        let target = Array(word.utf8)
        guard start + target.count <= bytes.count else { return nil }
        for offset in 0 ..< target.count where (bytes[start + offset] | 0x20) != target[offset] {
            return nil
        }
        return start + target.count
    }

    /// `0x` 之後：至少一個十六進位數字（小數點兩側都算），再選配 `p` 指數。
    static func scanHex(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        var digits = 0
        while index < bytes.count, isHexDigit(bytes[index]) {
            digits += 1; index += 1
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, isHexDigit(bytes[index]) {
                digits += 1; index += 1
            }
        }
        guard digits > 0 else { return nil }
        var end = index
        if index < bytes.count, (bytes[index] | 0x20) == UInt8(ascii: "p") {
            var probe = index + 1
            if probe < bytes.count,
               bytes[probe] == UInt8(ascii: "+") || bytes[probe] == UInt8(ascii: "-")
            {
                probe += 1
            }
            var exponentDigits = 0
            while probe < bytes.count, isDigit(bytes[probe]) {
                exponentDigits += 1; probe += 1
            }
            if exponentDigits > 0 {
                end = probe
            }
        }
        return end
    }

    static func scanDecimal(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        var digits = 0
        while index < bytes.count, isDigit(bytes[index]) {
            digits += 1; index += 1
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, isDigit(bytes[index]) {
                digits += 1; index += 1
            }
        }
        guard digits > 0 else { return nil }
        var end = index
        if index < bytes.count, (bytes[index] | 0x20) == UInt8(ascii: "e") {
            var probe = index + 1
            if probe < bytes.count,
               bytes[probe] == UInt8(ascii: "+") || bytes[probe] == UInt8(ascii: "-")
            {
                probe += 1
            }
            var exponentDigits = 0
            while probe < bytes.count, isDigit(bytes[probe]) {
                exponentDigits += 1; probe += 1
            }
            if exponentDigits > 0 {
                end = probe
            }
        }
        return end
    }

    static func isNaNPayload(_ byte: UInt8) -> Bool {
        isDigit(byte) || isAlpha(byte) || byte == UInt8(ascii: "_")
    }

    static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || ((byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "f"))
    }
}
