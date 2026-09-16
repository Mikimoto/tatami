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

// AwkRegex 的 pattern 解析器。與引擎分開只是為了型別長度——它是 AwkRegex 的一部分，
// 唯一的呼叫端是 `AwkRegex.init(patternBytes:)`。
//
// 從 private 放寬成 internal 是拆檔的代價：Swift 的 private 是**檔案**範圍，
// 跨檔的 extension 看不到它。這個 module 之外仍然看不到。

extension AwkRegex {
    struct Parser {
        let pattern: [UInt8]
        var index = 0

        init(pattern: [UInt8]) {
            // `\0`／`\000` 產生的 NUL 會讓 awk 的 C 字串在那裡結束。真正的 NUL 進不了
            // argv，所以這裡只處理不了那一種——留給 escapeByte 產生，見那邊的註解。
            self.pattern = pattern
        }

        var atEnd: Bool {
            index >= pattern.count
        }

        func peek(_ offset: Int = 0) -> UInt8? {
            let position = index + offset
            return position < pattern.count ? pattern[position] : nil
        }

        mutating func parseTop() throws -> Node {
            // 整個 pattern 是空的就是「什麼都配得上」（實測 title-regex 傳空字串
            // 會把整份 dump 都印出來）。這個空與 `a|` 的空分支不同，後者是錯誤。
            guard !pattern.isEmpty else { return .empty }
            let node = try parseAlternate(depth: 0)
            guard atEnd else { throw AwkRegexError.syntax }
            return node
        }

        mutating func parseAlternate(depth: Int) throws -> Node {
            var branches = try [parseConcat(depth: depth)]
            while peek() == UInt8(ascii: "|") {
                index += 1
                try branches.append(parseConcat(depth: depth))
            }
            return branches.count == 1 ? branches[0] : .alternate(branches)
        }

        /// 一段串接至少要有一個元素——這就是 `a|` 報錯的地方。
        mutating func parseConcat(depth: Int) throws -> Node {
            var items: [Node] = []
            while let byte = peek() {
                if byte == UInt8(ascii: "|") {
                    break
                }
                if byte == UInt8(ascii: ")"), depth > 0 {
                    break
                }
                try items.append(parsePiece(atBranchStart: items.isEmpty, depth: depth))
            }
            guard !items.isEmpty else { throw AwkRegexError.syntax }
            return items.count == 1 ? items[0] : .concat(items)
        }

        mutating func parsePiece(atBranchStart: Bool, depth: Int) throws -> Node {
            var node = try parsePrimary(atBranchStart: atBranchStart, depth: depth)
            // 量詞可以疊：`a{1,2}{2}` 與 `a**` 實測都合法。
            while let (low, high) = try parseQuantifier() {
                node = .repeated(node, min: low, max: high)
            }
            return node
        }

        mutating func parseQuantifier() throws -> (Int, Int?)? {
            guard let byte = peek() else { return nil }
            switch byte {
            case UInt8(ascii: "*"): index += 1; return (0, nil)
            case UInt8(ascii: "+"): index += 1; return (1, nil)
            case UInt8(ascii: "?"): index += 1; return (0, 1)
            case UInt8(ascii: "{"): return try parseInterval()
            default: return nil
            }
        }

        /// 回 nil 代表「這個 `{` 不是量詞」，而且**沒有前進** index，讓呼叫端把它
        /// 當字面字元讀掉。回 throw 代表寫壞了（`a{2`、`a{2,1}`）。
        mutating func parseInterval() throws -> (Int, Int?)? {
            let save = index
            index += 1
            guard let first = peek(), isDigit(first) else { index = save; return nil }
            let low = readNumber()
            guard let after = peek() else { throw AwkRegexError.syntax }
            if after == UInt8(ascii: "}") {
                index += 1
                return (low, low)
            }
            guard after == UInt8(ascii: ",") else { throw AwkRegexError.syntax }
            index += 1
            guard let next = peek() else { throw AwkRegexError.syntax }
            if next == UInt8(ascii: "}") {
                index += 1
                return (low, nil)
            }
            guard isDigit(next) else { throw AwkRegexError.syntax }
            let high = readNumber()
            guard peek() == UInt8(ascii: "}") else { throw AwkRegexError.syntax }
            index += 1
            guard high >= low else { throw AwkRegexError.syntax }
            return (low, high)
        }

        mutating func readNumber() -> Int {
            var value = 0
            while let byte = peek(), isDigit(byte) {
                // 位數多到溢位就直接夾在上限——後面的 tooLarge 會把它擋下來。
                value = value >= Compiler.instructionLimit
                    ? value
                    : value * 10 + Int(byte - UInt8(ascii: "0"))
                index += 1
            }
            return value
        }

        /// `(` 之後。空的群組 `()` 是合法的（實測），內容則遞迴下去。
        mutating func parseGroup(depth: Int) throws -> Node {
            index += 1
            if peek() == UInt8(ascii: ")") {
                index += 1
                return .empty
            }
            let inner = try parseAlternate(depth: depth + 1)
            guard peek() == UInt8(ascii: ")") else { throw AwkRegexError.syntax }
            index += 1
            return inner
        }

        /// `\` 之後那一個位元組當 primary。
        ///
        /// 收尾的孤零零反斜線讀到的是 C 字串的結尾那個 NUL，而 awk 的比對器是跑在
        /// C 字串上的，於是 pattern 裡的 NUL **等於字串結尾**。實測四條互相印證：
        /// `\` 與 `$` 對同一份 dump 回同一組 id、`a\` 與 `a$` 也是（只中結尾是 a 的）、
        /// `a\0b` 與 `\0a` 則永遠配不到（NUL 之後不可能再吃到位元組）。所以這裡回
        /// .eol，「後面還有東西就永遠不中」是 .eol 自己就有的性質，不必另外處理。
        mutating func parseEscapedPrimary() -> Node {
            index += 1
            guard !atEnd else { return .eol }
            let byte = escapeByte()
            return byte == 0 ? .eol : .literal(byte)
        }

        /// 這個位置沒有可以重複的東西：接得出合法區間就是錯誤（`{2}`），
        /// 接不出來才是字面的大括號（`{`、`{,2}`）。
        mutating func parseBraceAsPrimary(_ byte: UInt8) throws -> Node {
            if try parseInterval() != nil {
                throw AwkRegexError.syntax
            }
            index += 1
            return .literal(byte)
        }

        static let plainPrimaries: [UInt8: Node] = [
            UInt8(ascii: "$"): .eol,
            UInt8(ascii: "."): .any,
        ]

        mutating func parsePrimary(atBranchStart: Bool, depth: Int) throws -> Node {
            guard let byte = peek() else { throw AwkRegexError.syntax }
            // `$` 與 `.` 沒有條件也沒有 payload，走表；`^` 不行，它要看
            // atBranchStart（`a^b` 是 syntax error 而 `a|^b` 不是）。
            if let node = Self.plainPrimaries[byte] {
                index += 1
                return node
            }
            switch byte {
            case UInt8(ascii: "^"):
                guard atBranchStart else { throw AwkRegexError.syntax }
                index += 1
                return .bol
            case UInt8(ascii: "("):
                return try parseGroup(depth: depth)
            case UInt8(ascii: "["):
                return try parseBracket()
            case UInt8(ascii: "\\"):
                return parseEscapedPrimary()
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
                // 沒有東西可以重複。awk: `illegal primary in regular expression`。
                throw AwkRegexError.syntax
            case UInt8(ascii: "{"):
                return try parseBraceAsPrimary(byte)
            default:
                index += 1
                return .literal(byte)
            }
        }

        /// `\` 之後那一個位元組。與 awk 的 `quoted()` 對齊（實測 `\t` 是 TAB、
        /// `\b` 是 backspace 不是 word boundary、`\101` 是 `A`、`\q` 是字面的 `q`）。
        mutating func escapeByte() -> UInt8 {
            let byte = pattern[index]
            index += 1
            if let mapped = Self.controlEscapes[byte] {
                return mapped
            }
            guard isDigit(byte) else { return byte }
            return octalEscape(byte)
        }

        /// awk `quoted()` 認得的七個控制字元跳脫。表而不是 switch：七筆資料，
        /// 不是七種邏輯。
        static let controlEscapes: [UInt8: UInt8] = [
            UInt8(ascii: "n"): 0x0A,
            UInt8(ascii: "t"): 0x09,
            UInt8(ascii: "r"): 0x0D,
            UInt8(ascii: "b"): 0x08,
            UInt8(ascii: "f"): 0x0C,
            UInt8(ascii: "v"): 0x0B,
            UInt8(ascii: "a"): 0x07,
        ]

        /// awk 收的是**十進位數字**再照八進位累加（實測 `\8` 得到 0x08），
        /// 所以這裡不能只認 0–7。最多三位（首位已經吃掉了）。
        mutating func octalEscape(_ first: UInt8) -> UInt8 {
            var value = Int(first - UInt8(ascii: "0"))
            for _ in 0 ..< 2 {
                guard let next = peek(), isDigit(next) else { break }
                value = value * 8 + Int(next - UInt8(ascii: "0"))
                index += 1
            }
            return UInt8(truncatingIfNeeded: value)
        }
    }
}
