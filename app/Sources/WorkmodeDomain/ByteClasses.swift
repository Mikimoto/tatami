// LC_ALL=C 下的三個位元組分類。ERE 引擎的解析器與 AwkText 的 strtod 掃描器都要用，
// 而它們在拆檔之後住在不同的檔案裡——Swift 的 private 是檔案範圍，所以這三支只能
// 是 internal。這個 module 之外仍然看不到。
//
// 不用 Foundation 的 CharacterSet 也不用 Swift 的 `isNumber`：那些認 Unicode，
// 而 awk 在 LC_ALL=C 下只認 ASCII。

func isDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
}

func isAlpha(_ byte: UInt8) -> Bool {
    (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A
}

func isGraph(_ byte: UInt8) -> Bool {
    byte > 0x20 && byte < 0x7F
}
