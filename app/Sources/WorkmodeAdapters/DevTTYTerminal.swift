import Foundation
import WorkmodeCore

/// `--save` 的互動。對應 workmode.sh:1070 的守衛與 1163、1236 的 `read < /dev/tty`。
public struct DevTTYTerminal: Terminal, Sendable {
    public init() {}

    /// bash 是 `[ ! -t 0 ] || [ ! -r /dev/tty ]` 就擋下來，所以這裡是那個條件的反面：
    /// **stdin 是 tty 而且 /dev/tty 讀得到**。
    ///
    /// 兩個條件都要，不是重複：從 skhd 觸發時 stdin 不是 tty（第一條擋掉），
    /// 而在 pipeline 裡（`echo x | workmode --save`）stdin 也不是 tty 但
    /// /dev/tty 仍然可讀——bash 選的是「兩者皆須成立」，照抄。
    /// 實測（2026-08-14，Claude 的 Bash 工具環境）`[ -t 0 ]` 為假、
    /// `[ -r /dev/tty ]` 為真，所以這裡回 false，`--save` 被擋下——那正是想要的，
    /// 因為沒有 controlling tty 時互動是**無聲卡住**而不是失敗。
    public var hasControllingTTY: Bool {
        isatty(0) != 0 && access("/dev/tty", R_OK) == 0
    }

    /// `IFS= read -r x < /dev/tty` 的等價物。四件事都是那個寫法的語意：
    ///
    /// 1. 從 **/dev/tty** 讀而不是 stdin。理由在 workmode.sh:1161-1162：那個迴圈的
    ///    stdin 是 here-string（待命名的視窗清單），從 stdin 讀會把清單自己吃掉。
    /// 2. `IFS=` → 不切詞、不剝前後空白；`-r` → 反斜線是普通字元。所以這裡對讀到的
    ///    位元組不做任何加工。
    /// 3. 去掉結尾的換行（`read` 不把分隔符放進變數），而且**只去掉那一個**。
    /// 4. 讀到 EOF 時 `read` 回非零，呼叫端寫的是 `|| label='-'`／`|| ans=""`，
    ///    所以 EOF 一律回 nil——**包含「有讀到字但沒有換行就 EOF」那種**。
    ///    bash 那時會把殘字留在變數裡但 rc 仍是 1，於是 `||` 的右邊照樣執行、
    ///    殘字被蓋掉；等價於「那些字沒有用」。
    ///
    /// 每次呼叫重新開 /dev/tty，對齊 bash 的 redirect（它每次也重新開）；
    /// 而且**一個位元組一個位元組讀**，不是讀一個緩衝區——tty 上多讀的位元組
    /// 會從下一次呼叫手上偷走，bash 的 `read` 對非 seekable 輸入也是逐位元組讀。
    public func readLine() -> String? {
        let descriptor = Darwin.open("/dev/tty", O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    return String(decoding: bytes, as: UTF8.self)
                }
                bytes.append(byte)
                continue
            }
            // 0 是 EOF；負值是錯誤（EINTR 也算——bash 的 read 在這種情況下同樣回非零）。
            return nil
        }
    }
}
