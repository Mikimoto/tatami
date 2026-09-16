import Testing
import WorkmodeDomain
@testable import WorkmodeWire

// 期望值全部是 `jq 1.8.2` 實跑出來的，不是照 JSON 規格推的。
// 重跑對答案：`echo '<輸入>' | jq '.'`。

@Test func formatsNestedObjectLikeJQ() throws {
    let parsed = try JSONParser.parse(#"{"a":{"b":[1,2]},"c":"x"}"#)
    let expected = """
    {
      "a": {
        "b": [
          1,
          2
        ]
      },
      "c": "x"
    }
    """
    #expect(JSONWriter.format(parsed) == expected)
}

/// jq 不把空容器攤成多行，就是兩個字元。這條沒守住的話整份 layout.json 都會多出空行。
@Test func emptyContainersStayOnOneLine() throws {
    #expect(JSONWriter.format(.object([])) == "{}")
    #expect(JSONWriter.format(.array([])) == "[]")

    let parsed = try JSONParser.parse(#"{"o":{},"a":[]}"#)
    let expected = """
    {
      "o": {},
      "a": []
    }
    """
    #expect(JSONWriter.format(parsed) == expected)
}

/// 走一趟 parse + format，五個字面值一字不變：`2.50` 不得變成 `2.5`、`1.0` 不得變成 `1`。
@Test func keepsNumberLiteralsVerbatimOnOutput() throws {
    let parsed = try JSONParser.parse("[0.75,1.0,1,2.50,-0.5]")
    let expected = """
    [
      0.75,
      1.0,
      1,
      2.50,
      -0.5
    ]
    """
    #expect(JSONWriter.format(parsed) == expected)
}

/// 不經 parser，直接建值——驗的是 writer 自己的跳脫，不是 round-trip。
///
/// 輸入側用 `\u{01}`／`\u{7F}` 建出**真的**控制字元（writer 的輸入本來就是解析後的值）；
/// 期望值側是 raw string，所以 `\u0001` 是六個字面字元。兩側寫反的話這條測試會恆綠。
@Test func escapesExactlyLikeJQ() {
    let parsed = JSONValue.object([
        JSONMember(key: "quote", value: .string("a\"b")),
        JSONMember(key: "backslash", value: .string("a\\b")),
        JSONMember(key: "tab", value: .string("a\tb")),
        JSONMember(key: "newline", value: .string("a\nb")),
        JSONMember(key: "cr", value: .string("a\rb")),
        JSONMember(key: "bs", value: .string("a\u{08}b")),
        JSONMember(key: "ff", value: .string("a\u{0C}b")),
        JSONMember(key: "ctrl01", value: .string("a\u{01}b")),
        JSONMember(key: "del7f", value: .string("a\u{7F}b")),
        JSONMember(key: "slash", value: .string("a/b")),
        JSONMember(key: "cjk", value: .string("專案乙組")),
    ])
    let expected = #"""
    {
      "quote": "a\"b",
      "backslash": "a\\b",
      "tab": "a\tb",
      "newline": "a\nb",
      "cr": "a\rb",
      "bs": "a\bb",
      "ff": "a\fb",
      "ctrl01": "a\u0001b",
      "del7f": "a\u007fb",
      "slash": "a/b",
      "cjk": "專案乙組"
    }
    """#
    #expect(JSONWriter.format(parsed) == expected)
}

@Test func writesScalars() {
    #expect(JSONWriter.format(.null) == "null")
    #expect(JSONWriter.format(.bool(true)) == "true")
    #expect(JSONWriter.format(.bool(false)) == "false")
}

/// **已知且刻意的分歧**：jq 不逐字保留指數寫法，writer 保留。
///
/// 實測 jq 1.8.2：`1e2` → `1E+2`、`1e-3` → `0.001`。它對一般小數是逐字保留的
/// （`2.50` 不變），只有指數形式會被正規化。writer 的合約是「原樣輸出字面值」，
/// 所以這兩種輸入會與 `jq .` 分歧。
///
/// 不對齊的理由：`layout.json` 從來沒有指數寫法（ratio 都是 `0.75` 這種），
/// 而要複製 jq 的正規化就得實作它的浮點格式化，那是為了不存在的輸入付的代價。
/// 這條測試釘住的是**現況**——哪天真的需要對齊，它會先紅並指出這裡。
@Test func exponentLiteralsAreKeptVerbatimUnlikeJQ() throws {
    let parsed = try JSONParser.parse(#"{"a":1e2,"b":1e-3}"#)
    #expect(JSONWriter.format(parsed) == "{\n  \"a\": 1e2,\n  \"b\": 1e-3\n}")
}
