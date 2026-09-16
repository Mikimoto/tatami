import Testing
@testable import WorkmodeDomain

/// `state_set` 一定會印的第一行。
private let header = "# workmode 狀態檔，由 --switch 寫入。手改也可以，一行一個 key=value。\n"

/// tests/test_workmode.sh:218-224 的 `STATE_DUP`。同一個 key 兩筆而且值不同，
/// 前導空白、註解、未知 key 各一筆——一份語料涵蓋解析的四種情況。
private let stateDup = """
# 註解要被忽略

  location=home
profile.home=開發
unknown.key=保留
profile.home=會議

"""

// MARK: - state_get（workmode.sh:157-171）

@Suite("state_get")
struct StateGetTests {
    @Test("同一個 key 多筆取最後一筆")
    func lastEntryWins() {
        #expect(StateFile.value(forKey: "k", in: "k=1\nk=2") == "2")
    }

    /// 最後一筆是空值時整個 key 視為不存在（awk 的 `END { if (v != "") print v }`），
    /// 即使前面有一筆非空的。
    @Test("最後一筆是空值會蓋掉前面那筆非空的")
    func emptyLastValueHidesTheEarlierOne() {
        #expect(StateFile.value(forKey: "k", in: "k=1\nk=") == "")
    }

    @Test("註解、空行、沒有等號的行都跳過")
    func commentsBlankLinesAndKeylessLinesAreSkipped() {
        #expect(StateFile.value(forKey: "k", in: "# k=no\n\n   \nnoequals\nk=yes") == "yes")
    }

    /// 行首的空白與 key 尾端的空白都被剝掉，值那側**不**剝。
    @Test("只剝 key 兩側的空白")
    func surroundingBlanksAreStrippedFromTheKeyOnly() {
        #expect(StateFile.value(forKey: "k", in: "  \tk \t= v ") == " v ")
    }

    /// 註解的判斷發生在剝掉行首空白**之後**。
    @Test("縮排過的註解仍是註解")
    func indentedCommentsAreStillComments() {
        #expect(StateFile.value(forKey: "k", in: "  # k=no\nk=yes") == "yes")
    }

    /// 值裡面的 `=` 不再切一次——只看第一個 `=`。
    @Test("只有第一個等號切一次")
    func onlyTheFirstEqualsSplits() {
        #expect(StateFile.value(forKey: "k", in: "k=a=b") == "a=b")
    }

    /// `LC_ALL=C awk` 比的是位元組，所以 NFC 的 key 取不到 NFD 那筆。
    @Test("key 的比對是位元組層級")
    func stateKeyComparisonIsByteWise() {
        let content = "profile.cafe\u{301}=X"
        #expect(StateFile.value(forKey: "profile.cafe\u{301}", in: content) == "X")
        #expect(StateFile.value(forKey: "profile.caf\u{e9}", in: content) == "")
    }

    /// 記錄用 `\n` 切，不是用 Swift 的 Character——`\r\n` 是一個 Character 但兩個位元組。
    @Test("記錄以換行位元組切開")
    func recordsSplitOnTheNewlineByte() {
        #expect(StateFile.value(forKey: "k", in: "x=1\r\nk=2") == "2")
    }

    @Test("沒有這個 key 回空字串")
    func missingKeyIsEmpty() {
        #expect(StateFile.value(forKey: "k", in: "") == "")
        #expect(StateFile.value(forKey: "k", in: "other=1") == "")
    }

    // ---- tests/test_workmode.sh:228-231 的三條 ----

    @Test("取得 location，前導空白不影響")
    func readsLocationFromStateDup() {
        #expect(StateFile.value(forKey: "location", in: stateDup) == "home")
    }

    @Test("STATE_DUP 的重複 key 取最後一筆")
    func readsLastProfileFromStateDup() {
        #expect(StateFile.value(forKey: "profile.home", in: stateDup) == "會議")
    }

    @Test("沒有的 key 回空字串且不報錯")
    func missingKeyInStateDup() {
        #expect(StateFile.value(forKey: "profile.office", in: stateDup) == "")
    }
}

// MARK: - state_set（workmode.sh:178-195）

@Suite("state_set")
struct StateSetTests {
    // ---- tests/test_workmode.sh:233-243 的四條 ----

    @Test("寫入時整份重建：重複的 key 收斂成一筆，未知的 key 保留")
    func rebuildsCollapsingDuplicates() {
        #expect(StateFile.set(stateDup, key: "profile.home", value: "影音")
            == header + "location=home\nprofile.home=影音\nunknown.key=保留\n")
    }

    @Test("值為空字串表示刪除該 key")
    func emptyValueDeletes() {
        #expect(StateFile.set(stateDup, key: "location", value: "")
            == header + "profile.home=會議\nunknown.key=保留\n")
    }

    @Test("從空內容建立")
    func buildsFromEmptyContent() {
        #expect(StateFile.set("", key: "location", value: "office")
            == header + "location=office\n")
    }

    @Test("輸出帶一行說明用的註解")
    func firstLineIsTheComment() {
        let out = StateFile.set(stateDup, key: "profile.home", value: "影音")
        #expect(out.hasPrefix("#"))
        #expect(out.hasPrefix(header))
    }

    // ---- 輸出順序：實測結論 ----

    /// awk 的 `for (key in v)` 迭代順序是實作定義的，但它**決定不了輸出**——
    /// state_set 的結尾是 `| LC_ALL=C sort`，整份重排一次。所以同一組 key 用不同
    /// 的插入順序餵進去，輸出逐位元組相同。
    @Test("輸出順序與插入順序無關")
    func orderIsIndependentOfInsertionOrder() {
        let forward = StateFile.set("z=1\na=2\nm=3\nb=4", key: "k", value: "v")
        let reversed = StateFile.set("a=2\nb=4\nm=3\nz=1", key: "k", value: "v")
        #expect(forward == reversed)
        #expect(forward == header + "a=2\nb=4\nk=v\nm=3\nz=1\n")
    }

    /// 排的是**整行**而不是 key：`b2=0` 排在 `b=1` 前面，因為第二個位元組比的是
    /// `2`(0x32) 與 `=`(0x3D)。真實的 key 就會踩到——`profile.home` 排在
    /// `profile` 前面。只用 key 排序的實作在這裡會反過來。
    @Test("排序比的是整行不是 key")
    func sortsWholeLinesNotKeys() {
        #expect(StateFile.set("b=1\nb2=0", key: "k", value: "v")
            == header + "b2=0\nb=1\nk=v\n")
        #expect(StateFile.set("profile=A\nprofile.home=B", key: "k", value: "v")
            == header + "k=v\nprofile.home=B\nprofile=A\n")
    }

    /// `LC_ALL=C` 排的是位元組：大寫全部在小寫前面，非 ASCII 在最後。用 locale
    /// 定序的實作會把 `apple` 排到 `Banana` 前面。
    @Test("排序是 LC_ALL=C 的位元組序")
    func sortIsByteWise() {
        #expect(StateFile.set("Zebra=1\napple=2\n中文=3\nBanana=4", key: "k", value: "v")
            == header + "Banana=4\nZebra=1\napple=2\nk=v\n中文=3\n")
    }

    /// 位元組序不是數字序。
    @Test("數字型的 key 照字面排")
    func numericKeysSortLexicographically() {
        #expect(StateFile.set("10=a\n9=b\n2=c\n100=d", key: "k", value: "v")
            == header + "100=d\n10=a\n2=c\n9=b\nk=v\n")
    }

    // ---- 解析與邊界 ----

    @Test("沒有等號的行整行丟掉")
    func linesWithoutEqualsAreDropped() {
        #expect(StateFile.set("noequals\nc=3", key: "k", value: "v")
            == header + "c=3\nk=v\n")
    }

    @Test("註解與空行不會被寫回去")
    func commentsAndBlanksAreNotPreserved() {
        #expect(StateFile.set("# 舊註解\n\n   \nc=3", key: "k", value: "v")
            == header + "c=3\nk=v\n")
    }

    /// 只剝 key 那側的空白，值的前導空白留著。
    @Test("重建時 key 的空白被剝掉，值的不剝")
    func whitespaceIsStrippedFromKeysOnly() {
        #expect(StateFile.set("  a = 1\nb\t=\t2", key: "k", value: "v")
            == header + "a= 1\nb=\t2\nk=v\n")
    }

    @Test("刪掉一個不存在的 key 只是重建")
    func deletingAMissingKeyJustRebuilds() {
        #expect(StateFile.set("x=1", key: "nosuch", value: "") == header + "x=1\n")
    }

    @Test("空內容加空值只剩註解行")
    func nothingLeftButTheComment() {
        #expect(StateFile.set("", key: "k", value: "") == header)
    }

    @Test("值裡面的等號原樣留著")
    func valueMayContainEquals() {
        #expect(StateFile.set("x=1", key: "k", value: "a=b") == header + "k=a=b\nx=1\n")
    }

    /// 行首就是 `=` 時 key 是空字串，那筆照樣保留（`substr($0,1,0)` 是 ""）。
    @Test("空的 key 也是一個 key")
    func emptyKeyIsStillAKey() {
        #expect(StateFile.set("=x\ny=2", key: "k", value: "v")
            == header + "=x\nk=v\ny=2\n")
    }

    /// 新的那筆是 `printf '%s=%s\n'` 之後才進 sort 的，所以值裡的換行會把它切成
    /// 好幾筆記錄各自去排。
    @Test("新值裡的換行會被切成多筆記錄")
    func newlineInValueSplitsRecords() {
        #expect(StateFile.set("", key: "k", value: "a\nb") == header + "b\nk=a\n")
    }

    /// 內層是 `sort -u`、外層是 `sort`（沒有 `-u`），所以新加的那行與既有的那行
    /// 撞成同一個字串時**兩筆都留著**。改成整份去重的實作在這裡會少一行。
    @Test("外層排序不去重")
    func theOuterSortDoesNotDeduplicate() {
        #expect(StateFile.set("b=1", key: "k", value: "1\nb=1")
            == header + "b=1\nb=1\nk=1\n")
    }

    /// key 的比對與 state_get 同源，都是位元組——NFD 的 key 覆寫不掉 NFC 那筆，
    /// 兩筆並存。排序也是位元組：NFD 的 `cafe\u{301}` 第四個位元組是 `e`(0x65)，
    /// 比 NFC 的 `é` 開頭 0xC3 小，所以新加的那筆反而排在前面。
    @Test("要覆寫的 key 用位元組比對")
    func targetKeyMatchIsByteWise() {
        let content = "caf\u{e9}=1"
        #expect(StateFile.set(content, key: "cafe\u{301}", value: "2")
            == header + "cafe\u{301}=2\ncaf\u{e9}=1\n")
        #expect(StateFile.set(content, key: "caf\u{e9}", value: "2")
            == header + "caf\u{e9}=2\n")
    }

    /// 記錄以 `\n` 位元組切開，`\r` 留在值裡（它不是空白，剝不掉）。
    @Test("CRLF 的 CR 留在值裡")
    func carriageReturnStaysInTheValue() {
        #expect(StateFile.set("x=1\r\ny=2", key: "k", value: "v")
            == header + "k=v\nx=1\r\ny=2\n")
    }

    /// 寫進去再讀出來要拿得回同一個值——兩支共用同一套解析，這條把它們釘在一起。
    @Test("set 之後 get 得回同一個值")
    func setThenGetRoundTrips() {
        for (key, value) in [("location", "office"), ("profile.home", "影音"),
                             ("weird key", "a=b"), ("", "空 key")]
        {
            let written = StateFile.set(stateDup, key: key, value: value)
            #expect(StateFile.value(forKey: key, in: written) == value,
                    "key=[\(key)] 讀回來不一樣")
        }
    }
}
