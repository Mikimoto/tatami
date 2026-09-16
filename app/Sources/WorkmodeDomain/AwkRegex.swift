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

// MARK: - awk 的 ERE

public enum AwkRegexError: Error, Equatable, Sendable {
    /// awk 印一行 `awk: illegal primary in regular expression …` 之類的訊息到 stderr
    /// 並 exit 2。訊息的文字複製不了（那是 awk 的內部字串），所以只保留「壞掉了」
    /// 這個事實；`find_windows` 靠 `set -o pipefail` 把那個 2 透出來，見那支的 doc。
    case syntax
    /// `a{1000000}{1000000}` 這種展開後會爆掉的重複。awk 自己沒有這道閘門（它是
    /// DFA，狀態是懶惰建構的），所以這是一個**刻意的分歧**：與其吃光記憶體，
    /// 不如當成語法錯誤回 2。實際的設定不會寫出這種 pattern。
    case tooLarge
}

/// one-true-awk（20200816）的 ERE 方言，位元組層，只回答「有沒有配到」。
///
/// 不用 Swift 的 `Regex` 也不用 NSRegularExpression：兩者都是 PCRE 風格，與
/// POSIX ERE 在**語法、語意、錯誤**三個面向都不同（清單見 `WindowMatchingTests`
/// 的 `awkDialect…` 那組，全部是拿本機的 awk 實測出來的）。舉幾個會咬人的：
/// `a|` 在 awk 是語法錯誤而在 Swift 是合法的空分支、`\d` 在 awk 是字面的 `d`、
/// `a\+b` 在 awk 是字面的加號、`\b` 在 awk 是 backspace 不是 word boundary、
/// `(?:a)` 在 awk 是語法錯誤、`.` 吃一個位元組不是一個 Character。
///
/// 引擎是 Thompson NFA 的子集模擬：只要布林結果就不需要回溯，也就沒有
/// catastrophic backtracking——`(a*)*b` 這種 pattern 進了設定檔也不會把腳本掛死。
public struct AwkRegex: Sendable {
    // MARK: 指令

    enum Inst: Sendable {
        case byte(UInt8)
        /// `.`。實測**不吃** NUL 與換行（0x00、0x0a 都回 no），其餘 0x01–0xff 全吃，
        /// 含 0x80 以上——所以它切的是位元組不是字元。
        case any
        case set(ByteSet, negated: Bool)
        case bol
        /// `$`（以及 pattern 裡的 NUL）。是**吃掉一個字元**的指令而不是斷言：
        /// awk 的比對器跑在 C 字串上，`$` 配的是那個結尾的 NUL 並且把它消耗掉，
        /// 所以 `a$$` 配不上 `a`（實測回 no），而斷言式的模型會說配得上。
        case eol
        case split(Int, Int)
        case jump(Int)
        case match
    }

    private let program: [Inst]

    // MARK: 建構

    public init(pattern: String) throws {
        try self.init(patternBytes: Array(pattern.utf8))
    }

    public init(patternBytes: [UInt8]) throws {
        var parser = Parser(pattern: patternBytes)
        let node = try parser.parseTop()
        var compiler = Compiler()
        try compiler.emit(node)
        compiler.program.append(.match)
        program = compiler.program
    }

    // MARK: 比對

    public func matches(_ subject: String) -> Bool {
        matches(bytes: Array(subject.utf8))
    }

    /// 未錨定的搜尋：每個位置都放一條新的執行緒進去，所以 `^` 只在 pos 0 成立
    /// （awk 的 `^` 錨在**記錄**開頭，實測兩筆記錄 `a`／`b` 用 `^b` 只中第 2 筆）。
    public func matches(bytes subject: [UInt8]) -> Bool {
        var marks = [Int](repeating: -1, count: program.count)
        var generation = 0
        var current: [Int] = []
        // 多走一格：結尾那個虛擬的終止符要有位置可以被 `.eol` 吃掉。
        let terminator = subject.count
        var position = 0

        generation += 1
        if addClosure(seeds: [0], into: &current, marks: &marks,
                      generation: generation, position: position)
        {
            return true
        }

        while position <= terminator {
            let atTerminator = position == terminator
            let byte = atTerminator ? 0 : subject[position]
            let stepped = step(current, byte: byte, atTerminator: atTerminator)
            position += 1
            generation += 1
            current = []
            // `+ [0]` 就是「從這個位置重新開始試一次」，少了它就變成錨定比對；
            // 但終止符之後沒有新的起點——那裡只剩剛吃掉終止符的那些執行緒。
            let seeds = position <= terminator ? stepped + [0] : stepped
            if addClosure(seeds: seeds, into: &current, marks: &marks,
                          generation: generation, position: position)
            {
                return true
            }
        }
        return false
    }

    /// 吃掉一個位元組：每個活著的執行緒各自看它停在哪一種指令。
    ///
    /// 抽出來只是複雜度——它就是 NFA 的一步，四種吃位元組的指令加上「其餘不動」。
    /// `.eol` 只在終止符那一格成立，而那一格 `byte` 是虛構的 0，所以另外三種
    /// 都要先問 `atTerminator`。
    private func step(_ current: [Int], byte: UInt8, atTerminator: Bool) -> [Int] {
        var stepped: [Int] = []
        for counter in current {
            switch program[counter] {
            case let .byte(expected):
                if !atTerminator, expected == byte {
                    stepped.append(counter + 1)
                }
            case .any:
                if !atTerminator, byte != 0x00, byte != 0x0A {
                    stepped.append(counter + 1)
                }
            case let .set(members, negated):
                if !atTerminator, members.contains(byte) != negated {
                    stepped.append(counter + 1)
                }
            case .eol:
                if atTerminator {
                    stepped.append(counter + 1)
                }
            default:
                break
            }
        }
        return stepped
    }

    /// epsilon 閉包。回 true 代表這一步就走到 `.match` 了。
    /// 用顯式堆疊而不是遞迴：`a{500}` 展開之後程式有上千個指令，遞迴會爆 stack。
    private func addClosure(seeds: [Int], into list: inout [Int], marks: inout [Int],
                            generation: Int, position: Int) -> Bool
    {
        var stack = seeds.reversed().map(\.self)
        var matched = false
        while let counter = stack.popLast() {
            if marks[counter] == generation {
                continue
            }
            marks[counter] = generation
            switch program[counter] {
            case let .jump(target):
                stack.append(target)
            case let .split(first, second):
                // second 先推、first 後推 → first 先被取出。順序對布林結果沒有影響，
                // 只是讓走訪順序與 AST 的左右一致，除錯時比較好讀。
                stack.append(second)
                stack.append(first)
            case .bol:
                if position == 0 {
                    stack.append(counter + 1)
                }
            case .match:
                matched = true
            case .byte, .any, .set, .eol:
                list.append(counter)
            }
        }
        return matched
    }

    /// 把一段字面文字變成「只配得上它自己」的 pattern。
    ///
    /// **這是 `init(pattern:)` 的反函式**，所以放在這裡而不是呼叫端：改了引擎
    /// 認得的語法，這一支要跟著改，而分居兩地的話沒有人會記得。
    ///
    /// **逐位元組做**：這個引擎整份在位元組上工作，而 ERE 的特殊字元全在 ASCII
    /// 區、UTF-8 的續位元組都 >= 0x80，所以逐位元組掃不會切開多位元組字元。
    ///
    /// **保守跳脫**：對每個特殊位元組加反斜線，不去判斷「這裡的 `-` 需不需要」。
    /// 實測多加的反斜線是安全的——`Zed\-2\.0 \[beta\]` 照樣命中 `Zed-2.0 [beta]`
    /// （2026-08-28，bash 的 awk 與這支引擎兩側一致）。
    public static func escapingLiteral(_ text: String) -> String {
        let special: Set<UInt8> = Set(".[]()*+?{}|^$\\".utf8)
        var out: [UInt8] = []
        for byte in Array(text.utf8) {
            if special.contains(byte) {
                out.append(UInt8(ascii: "\\"))
            }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: AST

    indirect enum Node: Sendable {
        /// 什麼都不吃。`()` 與收尾的孤零零反斜線都落在這裡（實測 `\` 這個 pattern
        /// 配得上任何字串，包含空字串——它就是一個空 pattern）。
        case empty
        case literal(UInt8)
        case any
        case cclass(ByteSet, negated: Bool)
        case bol
        case eol
        case concat([Node])
        case alternate([Node])
        /// `max == nil` 是無上限。
        case repeated(Node, min: Int, max: Int?)
    }

    // MARK: 編譯

    struct Compiler {
        var program: [Inst] = []
        /// 展開 `{n,m}` 會複製子樹，所以要有上限。這個數字沒有對應的 awk 行為，
        /// 純粹是不讓 `a{100000}{100000}` 吃光記憶體，見 `AwkRegexError.tooLarge`。
        static let instructionLimit = 200_000

        mutating func emit(_ node: Node) throws {
            guard program.count < Self.instructionLimit else { throw AwkRegexError.tooLarge }
            if let instruction = node.singleInstruction {
                program.append(instruction)
                return
            }
            // 兩支 switch **都**窮舉、都沒有 default，所以新增一種節點時兩邊都會
            // 編譯錯誤——這裡少寫一個 case 的下場是「那種節點什麼都不編譯出來」，
            // 而那不會有任何執行期訊號。
            switch node {
            case let .concat(items):
                for item in items {
                    try emit(item)
                }
            case let .alternate(branches):
                try emitAlternate(branches)
            case let .repeated(inner, low, high):
                try emitRepeat(inner, min: low, max: high)
            // 上面那個 if 已經處理掉了；`.empty` 本來就不產生指令。
            case .empty, .literal, .any, .cclass, .bol, .eol:
                break
            }
        }

        private mutating func emitAlternate(_ branches: [Node]) throws {
            guard let first = branches.first else { return }
            guard branches.count > 1 else { return try emit(first) }
            let splitAt = program.count
            program.append(.split(0, 0))
            try emit(first)
            let jumpAt = program.count
            program.append(.jump(0))
            let secondAt = program.count
            program[splitAt] = .split(splitAt + 1, secondAt)
            try emitAlternate(Array(branches.dropFirst()))
            program[jumpAt] = .jump(program.count)
        }

        private mutating func emitRepeat(_ node: Node, min low: Int, max high: Int?) throws {
            for _ in 0 ..< low {
                try emit(node)
            }
            guard let high else {
                // 星號：L1: split L2, L3 / L2: node / jump L1 / L3:
                let splitAt = program.count
                program.append(.split(0, 0))
                try emit(node)
                program.append(.jump(splitAt))
                program[splitAt] = .split(splitAt + 1, program.count)
                return
            }
            guard high > low else { return }
            // 可選的那幾份要**巢狀**而不是並列：`a{0,2}` 是 (a(a)?)? 不是 a?a?，
            // 兩者對布林結果同義，但巢狀的指令數與 awk 的 DFA 狀態數同階。
            var tails: [Int] = []
            for _ in 0 ..< (high - low) {
                let splitAt = program.count
                program.append(.split(0, 0))
                tails.append(splitAt)
                try emit(node)
                program[splitAt] = .split(splitAt + 1, 0)
            }
            for splitAt in tails {
                guard case let .split(first, _) = program[splitAt] else { continue }
                program[splitAt] = .split(first, program.count)
            }
        }
    }

    // MARK: 解析

    // 文法是照本機 awk 實測回推的，不是照 POSIX 抄的——兩者在四個地方不一樣：
    //   * 空的分支是錯誤（`a|`、`|a`、`(a|)` 全部 rc=2），但空的**群組** `()` 合法；
    //   * `^` 只能當一段串接的**第一個**元素（`a^b` 是 syntax error，`a|^b` 沒問題），
    //     `$` 則哪裡都能放（`$a` 不報錯，只是永遠配不到）；
    //   * 沒有配對的 `)` 是**字面**的右括號（`a)` 配得上 `a)`），沒有配對的 `(` 才報錯；
    //   * `{` 後面接得出合法區間才算量詞：`a{` 與 `a{,2}` 是字面的大括號，
    //     `a{2` 是錯誤（沒有收尾），`{2}` 出現在該放 primary 的位置也是錯誤。
}

extension AwkRegex.Node {
    /// 只產生**一個**指令的節點。複合節點（concat／alternate／repeated）回 nil，
    /// 由 `Compiler.emit` 自己遞迴。
    var singleInstruction: AwkRegex.Inst? {
        switch self {
        // `.empty` 不產生指令，與「複合節點」一樣回 nil。
        case .empty: nil
        case let .literal(byte): .byte(byte)
        case .any: .any
        case let .cclass(members, negated): .set(members, negated: negated)
        case .bol: .bol
        case .eol: .eol
        case .concat, .alternate, .repeated: nil
        }
    }
}
