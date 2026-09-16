import Testing
import WorkmodeDomain

@Suite("label 的相等判準與 validator 同一支")
struct LabelEqualsTests {
    /// jq 的 `==` 比的是**數值**不是字面值。這一條是 `treeChecks` 的註解
    /// （`LayoutValidator.swift:293`）宣稱的行為，這裡把它變成可執行的斷言。
    @Test func numericLiteralsCompareByValue() {
        #expect(LayoutValidator.labelEquals(.number("1.5"), .number("1.50")))
        #expect(LayoutValidator.labelEquals(.number("7"), .number("7.0")))
    }

    /// **型別不同就不相等。** 這一條是整個掃除功能的地基：規則裡 `"label": 7`
    /// 與樹裡 `{"window": "7"}` 在畫面上長得一模一樣，而 validator 認為它們不同。
    /// 掃除若用 `JQPrint.interpolate` 的字串比較，這兩個會被當成同一個。
    @Test func numbersAreNotStrings() {
        #expect(!LayoutValidator.labelEquals(.number("7"), .string("7")))
        #expect(!LayoutValidator.labelEquals(.string("甲"), .number("7")))
    }

    @Test func sameStringsAreEqual() {
        #expect(LayoutValidator.labelEquals(.string("甲"), .string("甲")))
        #expect(!LayoutValidator.labelEquals(.string("甲"), .string("乙")))
    }
}
