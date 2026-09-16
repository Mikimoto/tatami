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

// MARK: - 位元組集合

/// bracket 表達式用的 256 位元集合。用四個 UInt64 而不是 `Set<UInt8>`：
/// 比對的內迴圈每個位元組都要查一次，而 Domain 不能用 Foundation 的 CharacterSet。
///
/// 四個**具名屬性**而不是一個 `[UInt64]`：陣列會把這 32 個位元組搬到堆上並帶著
/// retain／release 進那個內迴圈。具名屬性與原本的 `(UInt64, UInt64, UInt64, UInt64)`
/// 記憶體佈局相同，差別只在 Equatable 這下能自動合成（tuple 不行，所以原本要手寫）。
struct ByteSet: Equatable, Sendable {
    private var word0: UInt64 = 0
    private var word1: UInt64 = 0
    private var word2: UInt64 = 0
    private var word3: UInt64 = 0

    mutating func insert(_ byte: UInt8) {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: word0 |= bit
        case 1: word1 |= bit
        case 2: word2 |= bit
        default: word3 |= bit
        }
    }

    func contains(_ byte: UInt8) -> Bool {
        let bit = UInt64(1) << UInt64(byte & 63)
        switch byte >> 6 {
        case 0: return word0 & bit != 0
        case 1: return word1 & bit != 0
        case 2: return word2 & bit != 0
        default: return word3 & bit != 0
        }
    }
}
