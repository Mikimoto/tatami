import Testing
import WorkmodeDomain
import WorkmodeWire

/// **同一條規則的兩個輸入形態要給出同一個答案。** `DisplaysDecoder` 吃字串走
/// `JSONSerialization`，`Displays.list` 吃 `JSONValue`（因為 `YabaiClient.query`
/// 回的是後者）。沒有這條測試，那就是兩份會各自漂移的解析器。
///
/// fixture 刻意做出鑑別力：一筆正常、一筆缺 uuid、一筆缺 index、一筆不是物件、
/// 一筆 index 是字串、一筆 index 不是整數。只有第一筆該留下來，所以「兩邊都回
/// 空陣列」不會蒙混過關。最後那筆是 2026-08-20 補的：少了它，「`Int(text)` 改成
/// `Int(text) ?? 0`」這個突變沒有任何輸入踩得到（`"5"` 在 `.number` 那一關就被
/// 擋掉了，根本走不到 `Int(_:)`）。
@Test func listAgreesWithTheWireDecoder() throws {
    let text = """
    [ { "uuid": "U-1", "index": 1 },
      { "index": 2 },
      { "uuid": "U-3" },
      "不是物件",
      { "uuid": "U-5", "index": "5" },
      { "uuid": "U-6", "index": 2.5 } ]
    """
    let fromText = try DisplaysDecoder.decode(text)
    let fromValue = try Displays.list(in: JSONParser.parse(text))
    #expect(fromText == [Display(uuid: "U-1", index: 1)])
    #expect(fromValue == fromText)
}

/// 根不是陣列時兩邊都不產出（那一支 throw、這一支回空）。
@Test func aNonArrayRootYieldsNothing() throws {
    #expect(try Displays.list(in: JSONParser.parse("{}")).isEmpty)
    #expect(throws: (any Error).self) { try DisplaysDecoder.decode("{}") }
}
