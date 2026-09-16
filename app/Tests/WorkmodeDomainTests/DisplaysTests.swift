import Testing
@testable import WorkmodeDomain

/// 與 tests/test_workmode.sh 的 DISPLAYS 相同的三筆，差分測試才有共同輸入。
private let displays = [
    Display(uuid: "AAA", index: 1),
    Display(uuid: "BBB", index: 2),
    Display(uuid: "CCC", index: 3),
]

@Test func findsTheIndexForAKnownUUID() {
    #expect(Displays.indices(forUUID: "BBB", in: displays) == [2])
}

@Test func returnsNothingForAnUnknownUUID() {
    #expect(Displays.indices(forUUID: "ZZZ", in: displays) == [])
}

/// jq 的 `.[]` 是串流，同一個 uuid 出現兩次就印兩行。這裡釘住同樣的行為，
/// 否則 Swift 版「回第一個」會與 bash 版在這個輸入上分歧。
@Test func returnsEveryMatchNotJustTheFirst() {
    let dup = [Display(uuid: "AAA", index: 1), Display(uuid: "AAA", index: 9)]
    #expect(Displays.indices(forUUID: "AAA", in: dup) == [1, 9])
}

// MARK: - frame(ofIndexText:in:)

/// `--space` 要拿那台螢幕的 frame 當樹的畫布。index 用 `LayoutReading.displayIndexText`
/// 給的**文字**比對，不轉數字：那一支回的就是 jq -r 印出來的字面值。
///
/// 第二台的 y 是負的（本機實際的多螢幕排列就是這樣），所以「把座標當成非負」的
/// 實作分得出來。
@Test func frameOfDisplayIndexReadsAllFourFields() {
    let displays = JSONValue.array([
        obj([("uuid", .string("A")), ("index", num("1")),
             ("frame", obj([("x", num("0")), ("y", num("0")), ("w", num("1728")), ("h", num("1117"))]))]),
        obj([("uuid", .string("B")), ("index", num("2")),
             ("frame", obj([("x", num("1728")), ("y", num("-323")), ("w", num("2560")), ("h", num("1440"))]))]),
    ])
    #expect(Displays.frame(ofIndexText: "2", in: displays)
        == Rect(originX: 1728, originY: -323, width: 2560, height: 1440))
    #expect(Displays.frame(ofIndexText: "3", in: displays) == nil)
}

/// frame 缺一個欄位就當成沒有——半個矩形算出來的樹會把視窗排到螢幕外。
@Test func aFrameMissingAFieldIsNil() {
    let displays = JSONValue.array([
        obj([("index", num("1")), ("frame", obj([("x", num("0")), ("y", num("0")), ("w", num("100"))]))]),
    ])
    #expect(Displays.frame(ofIndexText: "1", in: displays) == nil)
}
