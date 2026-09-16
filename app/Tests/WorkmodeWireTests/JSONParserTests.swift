import Testing
@testable import WorkmodeWire

@Test func parsesScalars() throws {
    #expect(try JSONParser.parse("null") == .null)
    #expect(try JSONParser.parse("true") == .bool(true))
    #expect(try JSONParser.parse("false") == .bool(false))
    #expect(try JSONParser.parse("\"hi\"") == .string("hi"))
}

/// 鍵序是這整層存在的理由：windows 的順序決定碰撞時誰先認領視窗，
/// profiles 的第一個是沒有 default 時的 fallback。
@Test func preservesObjectKeyOrder() throws {
    let parsed = try JSONParser.parse(#"{"z":1,"a":2,"m":3}"#)
    guard case let .object(members) = parsed else { Issue.record("不是物件"); return }
    #expect(members.map(\.key) == ["z", "a", "m"])
}

@Test func parsesNestedContainers() throws {
    let parsed = try JSONParser.parse(#"{"a":[1,{"b":null}],"c":{}}"#)
    guard case let .object(members) = parsed else { Issue.record("不是物件"); return }
    #expect(members.map(\.key) == ["a", "c"])
    #expect(members[1].value == .object([]))
    guard case let .array(items) = members[0].value else { Issue.record("不是陣列"); return }
    #expect(items.count == 2)
}

@Test func ignoresWhitespaceBetweenTokens() throws {
    let parsed = try JSONParser.parse("  {\n  \"a\" :  [ 1 , 2 ]\n}  ")
    guard case let .object(members) = parsed else { Issue.record("不是物件"); return }
    #expect(members.map(\.key) == ["a"])
}

@Test func rejectsTrailingGarbage() {
    #expect(throws: (any Error).self) { try JSONParser.parse("{} extra") }
}

@Test func rejectsTruncatedInput() {
    #expect(throws: (any Error).self) { try JSONParser.parse(#"{"a":"#) }
}

/// jq 1.8 逐字保留數字字面值，所以 parser 也要。解成 Double 再印的話
/// `2.50` 會變 `2.5`、`1.0` 會變 `1`，round-trip 就對不上了。
@Test func keepsNumberLiteralsVerbatim() throws {
    let parsed = try JSONParser.parse(#"{"a":0.75,"b":1.0,"c":1,"d":2.50,"e":-0.5,"f":0}"#)
    guard case let .object(members) = parsed else { Issue.record("不是物件"); return }
    #expect(members.map(\.value) == [.number("0.75"), .number("1.0"), .number("1"),
                                     .number("2.50"), .number("-0.5"), .number("0")])
}

@Test func decodesShortEscapes() throws {
    let parsed = try JSONParser.parse(#""a\"b\\c\/d\nE\tF\r\b\f""#)
    #expect(parsed == .string("a\"b\\c/d\nE\tF\r\u{08}\u{0C}"))
}

@Test func decodesUnicodeEscapes() throws {
    #expect(try JSONParser.parse(#""A\u007F""#) == .string("A\u{7F}"))
    #expect(try JSONParser.parse(#""\u8cc7\u6599""#) == .string("資料"))
}

/// 半個代理對要 throw，不能靜默輸出一個孤立的代理：那會讓字串在之後某個無關的
/// 地方壞掉。2026-08-18 把 parseUnicodeEscape 從 parseString 抽出來時補的——正向那條
/// 早就有（見下面的 decodesSurrogatePairs），四條壞法一條都沒有。
///
/// 輸入側用 raw string 讓 `\u` 保持字面的六個字元；寫成真字元會走 parser 的原始
/// 位元組路徑，這條就變成在驗別的東西。
@Test func rejectsBrokenSurrogatePairs() throws {
    for broken in [#""\uD83D""#, // 高代理後面什麼都沒有
                   #""\uD83Dx""#, // 後面不是反斜線
                   #""\uD83D\n""#, // 是反斜線但不是 u
                   #""\uD83D\u0041""#] // 是 \u 但不在低代理範圍
    {
        #expect(throws: (any Error).self) { try JSONParser.parse(broken) }
    }
}

/// 代理對要合起來變成一個字元，不能各自輸出。少了這段，emoji 會靜默壞掉。
@Test func decodesSurrogatePairs() throws {
    #expect(try JSONParser.parse(#""\ud83d\ude00""#) == .string("😀"))
}

@Test func rejectsBadEscape() {
    #expect(throws: (any Error).self) { try JSONParser.parse(#""a\qb""#) }
}

/// 非 ASCII 原樣進來（jq 不跳脫中日韓），也要原樣出去。
@Test func keepsRawNonASCII() throws {
    #expect(try JSONParser.parse(#""專案乙組 - Chat""#) == .string("專案乙組 - Chat"))
}
