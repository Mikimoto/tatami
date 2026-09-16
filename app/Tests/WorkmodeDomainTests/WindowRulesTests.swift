import Testing
@testable import WorkmodeDomain

// MARK: - escape_ere（workmode.sh:335-341）

@Suite("escape_ere")
struct EscapeERETests {
    // ---- tests/test_workmode.sh:493-496 的四條 ----

    @Test("轉義點與星號")
    func escapesDotAndStar() {
        #expect(WindowRules.escapeERE("a.b*c") == #"a\.b\*c"#)
    }

    @Test("反斜線本身也要轉義")
    func escapesBackslash() {
        #expect(WindowRules.escapeERE(#"f\g"#) == #"f\\g"#)
    }

    @Test("轉義括號與其餘元字元")
    func escapesBracketsAndRest() {
        #expect(WindowRules.escapeERE(#"x[1](2){3}|4^5$6+7?8"#)
            == #"x\[1\]\(2\)\{3\}\|4\^5\$6\+7\?8"#)
    }

    @Test("多位元組字元原樣保留")
    func leavesMultibyteAlone() {
        #expect(WindowRules.escapeERE("MyApp — ContentView.swift")
            == #"MyApp — ContentView\.swift"#)
    }

    // ---- 逐個位元組掃過來的實測結果 ----

    /// bash 分四趟 sed 是為了繞開 BSD sed 的字元類限制，不是為了不同的語意：
    /// 實測 32–126 每個字元單獨餵進去，被加反斜線的恰好是這 14 個，其餘原樣。
    /// 後面幾趟的字元類不含 `\`、`[`、`]`，所以前面幾趟加上去的反斜線不會被
    /// 再轉義一次——四趟與單趟逐位元組對映等價。
    @Test("可見 ASCII 裡恰好 14 個字元被轉義")
    func escapesExactlyFourteenASCII() {
        let expected: Set<UInt8> = Set(#"\[].*+?^$(){}|"#.utf8)
        #expect(expected.count == 14)
        for byte in UInt8(32) ... UInt8(126) {
            let char = String(decoding: [byte], as: UTF8.self)
            let got = WindowRules.escapeERE(char)
            if expected.contains(byte) {
                #expect(got == "\\" + char, "0x\(String(byte, radix: 16)) 應該被轉義")
            } else {
                #expect(got == char, "0x\(String(byte, radix: 16)) 不該被動")
            }
        }
    }

    /// 控制字元不在那 14 個裡面，所以原樣穿過去。跳脫序列寫成字面的 `\u{…}`
    /// 是刻意的：真的把控制字元打進原始碼，這條會變成在驗別的東西。
    @Test("控制字元原樣保留")
    func leavesControlBytesAlone() {
        for byte in UInt8(1) ... UInt8(31) {
            let char = String(decoding: [byte], as: UTF8.self)
            #expect(WindowRules.escapeERE(char) == char)
        }
        #expect(WindowRules.escapeERE("\u{7F}") == "\u{7F}")
        #expect(WindowRules.escapeERE("a\u{09}b") == "a\u{09}b")
    }

    /// sed 逐行處理，而轉義集合裡沒有換行，所以多行輸入等於逐行轉義再接回去。
    /// bash 那側**不補尾端換行**（`printf '%s'` 沒給，BSD sed 也不會加）。
    @Test("多行輸入逐行轉義且不補尾端換行")
    func handlesMultilineInput() {
        #expect(WindowRules.escapeERE("a.b\nc*d") == #"a\.b"# + "\n" + #"c\*d"#)
        #expect(WindowRules.escapeERE("") == "")
    }

    /// NFC 與 NFD 的 `café` 是不同的位元組序列，轉義是位元組層級的，所以兩者
    /// 各自原樣穿過去而不會被正規化成同一個。
    @Test("位元組層級：NFC 與 NFD 各自原樣穿過")
    func isByteLevel() {
        let nfc = "caf\u{00E9}.txt"
        let nfd = "cafe\u{0301}.txt"
        #expect(WindowRules.escapeERE(nfc) == "caf\u{00E9}" + #"\.txt"#)
        #expect(WindowRules.escapeERE(nfd) == "cafe\u{0301}" + #"\.txt"#)
        #expect(Array(WindowRules.escapeERE(nfc).utf8) != Array(WindowRules.escapeERE(nfd).utf8))
    }
}

// MARK: - escape_ere → title-regex 的往返

/// `escape_ere` 的產物唯一的去處是 `title-regex`，而那條路走的是 awk 的 ERE。
/// 兩支各自對就好不夠——真正要成立的是「轉義過的標題只認得原標題」，所以這裡
/// 直接把 `escapeERE` 的輸出餵進 `AwkRegex`。
///
/// tests/test_workmode.sh:499-503 只釘了 `a.b`／`aXb` 這一組；這裡對每個元字元
/// 都跑一次，並且**兩個方向都驗**：配得上自己，且配不上「把元字元當語法讀」的
/// 那個替身。只驗正向的話，一個把所有字元都轉義掉的壞實作也會通過。
@Suite("escape_ere 餵進 title-regex 的往返")
struct EscapeERERoundTripTests {
    private func anchored(_ literal: String) throws -> AwkRegex {
        try AwkRegex(pattern: "^" + WindowRules.escapeERE(literal) + "$")
    }

    @Test("轉義後仍中原字串")
    func matchesItself() throws {
        for literal in ["a.b", "a*b", "a+b", "a?b", "a^b", "a$b", "a(b)c", "a{2}b",
                        "a|b", "a[x]b", #"a\b"#, "a-b", "a/b", "MyApp — ContentView.swift"]
        {
            #expect(try anchored(literal).matches(literal), "\(literal) 配不上自己")
        }
    }

    @Test("轉義後的元字元不再當語法")
    func doesNotMatchTheMetacharacterReading() throws {
        // 每組是 (原字串, 一個「元字元被當語法讀」時才會中的替身)。
        let decoys: [(String, String)] = [
            ("a.b", "aXb"), // . 當萬用字元
            ("a*b", "b"), // a* 當「零或多個 a」
            ("a+b", "ab"), // a+ 當「一或多個 a」
            ("a?b", "b"), // a? 當「零或一個 a」
            ("a{2}b", "aab"), // {2} 當重複次數
            ("a|b", "a"), // | 當交替
            ("a[x]b", "axb"), // [x] 當字元類
        ]
        for (literal, decoy) in decoys {
            let regex = try anchored(literal)
            #expect(regex.matches(literal), "\(literal) 配不上自己")
            #expect(!regex.matches(decoy), "\(literal) 不該中 \(decoy)")
        }
    }

    /// 錨點自己也得是錨點：`^`／`$` 出現在標題裡時被轉義成字面字元，於是
    /// 外面那對 `^…$` 仍然是整行比對。
    @Test("標題裡的錨點字元不會變成錨點")
    func anchorsInTitleStayLiteral() throws {
        let regex = try anchored("a^b$c")
        #expect(regex.matches("a^b$c"))
        #expect(!regex.matches("abc"))
        #expect(!regex.matches("a"))
    }
}

// MARK: - rule_for_window（workmode.sh:495-505）

@Suite("rule_for_window")
struct RuleForWindowTests {
    // ---- tests/test_workmode.sh:676-684 的三條 ----

    @Test("Safari 用當前分頁網址")
    func safariUsesURL() {
        #expect(WindowRules.rule(label: "新聞", app: "Safari", title: "任何標題",
                                 url: "https://a.b/c", many: "0")
                == obj([("label", .string("新聞")),
                        ("match", .array([.string("url-exact"), .string("https://a.b/c")]))]))
    }

    @Test("同 app 只有一個視窗時用 app")
    func singleWindowUsesApp() {
        #expect(WindowRules.rule(label: "程式碼", app: "Xcode",
                                 title: "MyApp — ContentView.swift", url: "", many: "0")
                == obj([("label", .string("程式碼")),
                        ("match", .array([.string("app"), .string("Xcode")]))]))
    }

    @Test("同 app 多個視窗時退到轉義過的標題並補 app fallback")
    func manyWindowsFallsBackToTitle() {
        #expect(WindowRules.rule(label: "程式碼", app: "Xcode", title: "MyApp.swift",
                                 url: "", many: "1")
                == obj([("label", .string("程式碼")),
                        ("match", .array([.string("title-regex"), .string(#"^MyApp\.swift$"#)])),
                        ("fallback", .array([.string("app"), .string("Xcode")]))]))
    }

    // ---- 實測補的邊界 ----

    /// 網址那條在最前面，`many` 完全不看——Safari 就算只有一個視窗也走網址。
    @Test("有網址時 many 不影響結果")
    func urlWinsOverMany() {
        let withMany = WindowRules.rule(label: "L", app: "Safari", title: "T",
                                        url: "https://u", many: "1")
        let without = WindowRules.rule(label: "L", app: "Safari", title: "T",
                                       url: "https://u", many: "0")
        #expect(withMany == without)
        #expect(withMany == obj([("label", .string("L")),
                                 ("match", .array([.string("url-exact"), .string("https://u")]))]))
    }

    /// bash 是 `[ "$many" = "1" ]`，字面比對而不是「真值」：`01`、`true`、空字串
    /// 實測都走 app 那條。
    @Test("many 只認字面的 1")
    func manyIsLiteralOne() {
        for many in ["0", "01", "true", "", " 1", "1 ", "2"] {
            #expect(WindowRules.rule(label: "L", app: "App", title: "T", url: "", many: many)
                == obj([("label", .string("L")),
                        ("match", .array([.string("app"), .string("App")]))]),
                "many=[\(many)] 不該走 title-regex")
        }
        #expect(WindowRules.rule(label: "L", app: "App", title: "T", url: "", many: "1")
            != obj([("label", .string("L")),
                    ("match", .array([.string("app"), .string("App")]))]))
    }

    /// `[ -n "$url" ]` 看的是空不空，不是像不像網址。
    @Test("url 只要非空就走 url-exact")
    func anyNonEmptyURLCounts() {
        #expect(WindowRules.rule(label: "L", app: "A", title: "T", url: " ", many: "0")
            == obj([("label", .string("L")),
                    ("match", .array([.string("url-exact"), .string(" ")]))]))
    }

    @Test("空的 label 與 app 照樣產生規則")
    func emptyStringsAreFine() {
        #expect(WindowRules.rule(label: "", app: "", title: "", url: "", many: "0")
            == obj([("label", .string("")),
                    ("match", .array([.string("app"), .string("")]))]))
    }

    /// 標題裡的引號與反斜線先被 `escape_ere` 加上反斜線，再由 JSON 那層各自
    /// 跳脫一次——兩層轉義疊起來容易少算一層，所以釘住轉義**之後**的字串本身。
    @Test("標題同時需要 ERE 轉義與 JSON 跳脫")
    func titleNeedingBothLayers() {
        let rule = WindowRules.rule(label: "L", app: "App", title: "a\"b\\c\u{09}d",
                                    url: "", many: "1")
        #expect(rule == obj([
            ("label", .string("L")),
            ("match", .array([.string("title-regex"), .string("^a\"b\\\\c\u{09}d$")])),
            ("fallback", .array([.string("app"), .string("App")])),
        ]))
    }

    @Test("空標題產生只配空字串的 pattern")
    func emptyTitle() throws {
        let rule = WindowRules.rule(label: "L", app: "App", title: "", url: "", many: "1")
        #expect(rule == obj([
            ("label", .string("L")),
            ("match", .array([.string("title-regex"), .string("^$")])),
            ("fallback", .array([.string("app"), .string("App")])),
        ]))
        let regex = try AwkRegex(pattern: "^$")
        #expect(regex.matches(""))
        #expect(!regex.matches("x"))
    }
}
