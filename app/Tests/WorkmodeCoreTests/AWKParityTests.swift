import Foundation
import Testing
@testable import WorkmodeCore

// workmode.sh:836 的 `printf '%s' "$ratio" | awk '{printf "%.4f", 1 - $1}'`。
//
// 驗法不是把答案抄進測試（那只證明我抄了兩次同一份東西），而是**每次都真的跑
// /usr/bin/awk**再逐位元組比對——同 HumanEventRendererTests 對 bash printf 的做法。
// 這個值會直接進 `yabai -m window <id> --ratio abs:<值>` 的 argv，位數是它的一部分
// （`0.2500` 不是 `0.25`），所以「大致相等」不夠。
//
// 這裡也是 `JQNumber` **不適用**的地方：那是 jq 的 dtoa 模型，這一行是 C 的 printf。

private func awkOneMinusFirstField(_ input: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
    process.arguments = [#"{printf "%.4f", 1 - $1}"#]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    try process.run()
    // `printf '%s' "$ratio"`：沒有尾端換行，空字串就是零位元組。
    stdin.fileHandleForWriting.write(Data(input.utf8))
    stdin.fileHandleForWriting.closeFile()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// 涵蓋 `layout.json` 實際用得到的值、邊界、以及非數字。
private let inputs = [
    "0.75", "0.7", "0.5", "1", "0", "0.25",
    // 非數字＝0（awk 的 strnum 轉換），所以是 1.0000——不是錯誤、不是空字串。
    "abc",
    // macOS 的 awk 認十六進位（strtod）：0x10 是 16。
    "0x10",
    // 有前綴數字的字串取到解不下去為止。
    "0.5abc", ".5", "+0.25", " 0.5 ",
    // C 的 %.4f 進位（不是 jq 的印法）。
    "0.3333", "1.00005", "0.00005",
    // 越界與非有限：printf 印 `-inf`／`nan`，不是數字。
    "1e400", "inf", "nan",
    // 零位元組＝一筆記錄都沒有＝零輸出；一個空白是一筆記錄（$1 空 → 0）。
    "", " ",
]

@Test func theInverseRatioMatchesRealAWKByteForByte() throws {
    for input in inputs {
        let expected = try awkOneMinusFirstField(input)
        let actual = AWK.oneMinusFirstField(input)
        let note = Comment(rawValue: "輸入 \(input.debugDescription)：awk 印 "
            + "\(expected.debugDescription)，Swift 印 \(actual.debugDescription)")
        #expect(Array(actual.utf8) == Array(expected.utf8), note)
    }
}

/// 正控制組（兩個方向）：上面那條若因為 harness 壞掉而恆真，就完全沒在驗。
/// 這條確認 (1) awk 真的印得出東西、(2) 一個刻意寫錯的期望值真的會被判不同。
@Test func theAWKHarnessCanActuallyFail() throws {
    #expect(try awkOneMinusFirstField("0.75") == "0.2500")
    #expect(try awkOneMinusFirstField("0.75") != "0.25")
    // 零位元組真的是零輸出，不是 "1.0000"——這條區分「沒有記錄」與「空記錄」。
    #expect(try awkOneMinusFirstField("").isEmpty)
    #expect(try awkOneMinusFirstField(" ") == "1.0000")
}
