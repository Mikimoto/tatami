// Core 唯一用到 Foundation 的地方，只為 `String(format: "%.4f")`：awk 的 `printf`
// 就是 C 的 printf，而它的進位由 libc 決定（`1.00005` → `-0.0001`、`0.00005` → `1.0000`
// 都實測過）。自己寫一份等於重新發明一個 dtoa，那才是真的會分歧。
// 這條限制只約束 Domain（見 WorkmodeArchitectureTests），Core 沒有這個禁令。
import Foundation
import WorkmodeDomain

// 兩個小語意，Core 的編排到處要用，而它們都**不是**從程式碼讀得出來的。
// 放 Core 而不是 Domain：它們是「bash 怎麼讀那串文字」，屬編排的一部分；
// Domain 那側的規則吃的是已經切好的欄位。

/// bash 的 `while … read -r … <<< "$var"`。
enum BashRead {
    /// here-string 切出來的行。
    ///
    /// `<<<` 會補一個換行，而 `$(...)` 已經把尾端換行剝掉了，所以
    /// 「空字串跑一次迴圈、`id` 為空」是真的會發生的一輪（`exile_strangers`
    /// 零個視窗時就走這條，然後收尾那句照樣報 moved=0）。
    /// 因此 `""` 必須切成 `[""]` 而不是 `[]`。
    static func lines(of text: String) -> [String] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 只有多於一行時才丟尾端空行：單一空字串那筆是有意義的一輪（見上）。
        if parts.count > 1, parts.last == "" {
            parts.removeLast()
        }
        return parts
    }

    /// `IFS=$'\t' read -r label id`。
    ///
    /// TAB 是 IFS **whitespace**，所以 read 的行為不是「按 tab 切兩段」（實測 bash 5）：
    ///   - 開頭的 tab 被跳過（`"\tC\t3"` → label=C、id=3）
    ///   - 連續的 tab 算一個分隔（`"A\t\t5"` → label=A、id=5，不是 id=""）
    ///   - 最後一個變數拿剩下的**整段**，但尾端的 tab 被剝掉
    ///     （`"B\t7\t9"` → id="7\t9"；`"A\t5\t\t"` → id="5"）
    ///   - 空白不在 IFS 裡，所以不碰（`"C\t5 "` → id="5 "）
    static func labelAndRest(_ line: String) -> (label: String, rest: String) {
        var index = line.startIndex
        while index < line.endIndex, line[index] == "\t" {
            index = line.index(after: index)
        }
        guard let separator = line[index...].firstIndex(of: "\t") else {
            return (String(line[index...]), "")
        }
        let label = String(line[index ..< separator])
        var rest = line.index(after: separator)
        while rest < line.endIndex, line[rest] == "\t" {
            rest = line.index(after: rest)
        }
        var tail = String(line[rest...])
        while tail.hasSuffix("\t") {
            tail.removeLast()
        }
        return (label, tail)
    }

    /// `IFS=$'\t' read -r a b c`（任意欄數）。
    ///
    /// TAB 是 IFS **whitespace**，所以這**不是**「按 tab 切成 n 段」。實測 bash 5：
    ///   - `"A\tv\tB"`   → A / v / B
    ///   - `"A\t\tB"`    → A / **B** / ""（連續的 tab 算一個分隔，所以空欄位會讓
    ///                     後面的欄位整批往前移一格——`tree_seq` 的 axis 是 null 時
    ///                     就走這條，place 會被讀進 axis）
    ///   - `"A\tv\tB\tC"` → A / v / **"B\tC"**（最後一個變數拿剩下的整段）
    ///   - `"\tA\tv\tB"`  → A / v / B（開頭的 tab 被跳過）
    ///   - `"A\tv\tB\t"`  → A / v / B（尾端的 tab 被剝掉）
    ///   - `""`          → "" / "" / ""
    static func fields(_ line: String, count: Int) -> [String] {
        precondition(count > 0)
        var index = line.startIndex
        func skipTabs() {
            while index < line.endIndex, line[index] == "\t" {
                index = line.index(after: index)
            }
        }

        skipTabs()
        var out: [String] = []
        while out.count < count - 1 {
            guard index < line.endIndex else { out.append(""); continue }
            let end = line[index...].firstIndex(of: "\t") ?? line.endIndex
            out.append(String(line[index ..< end]))
            index = end
            skipTabs()
        }
        var tail = String(line[index...])
        while tail.hasSuffix("\t") {
            tail.removeLast()
        }
        out.append(tail)
        return out
    }

    /// `read -r id`（預設 IFS）。單一變數拿整行，前後的 IFS whitespace 被剝掉。
    /// 換行不可能出現在行內，所以只需處理空白與 tab。
    static func singleField(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == " " || first == "\t" {
            text.removeFirst()
        }
        while let last = text.last, last == " " || last == "\t" {
            text.removeLast()
        }
        return String(text)
    }
}

/// `… | jq -r '.<key>'` 這整條管線。
///
/// 印法本身在 `WorkmodeDomain.JQPrint`：它走在 `validate`／`match_location` 的差分
/// 路徑上（對真的 jq 比過），所以借它就繼承那份驗證，而 Core 自己那份副本沒有任何
/// 訊號會告訴我們它寫錯了。這裡只剩「bash 那側看得見什麼」。
enum JQPipeline {
    /// bash 那側看得見的兩種空字串來源：query 失敗（`2>/dev/null` ＋ jq 吃空輸入，
    /// rc=0 零輸出）、以及值不是物件（字串索引是 runtime error，rc=5）。
    /// 缺 key **不是**空字串——jq 給 null，`-r` 印成字面的 `null`。
    static func member(_ value: JSONValue?, _ key: String) -> String {
        guard let value, case .object = value else { return "" }
        // 用 Domain 既有的 subscript（取**第一個**同名成員）而不是自己挑最後一個：
        // jq 對重複鍵是後者勝，但 yabai 的輸出裡不會有重複鍵，而在這裡自成一套
        // 只會讓 Core 與 Domain 對「取成員」有兩種答案。
        return JQPrint.raw(value[key] ?? .null)
    }
}

/// workmode.sh:836 的 `printf '%s' "$ratio" | awk '{printf "%.4f", 1 - $1}'`。
enum AWK {
    /// `1 - $1` 再用 C 的 `printf "%.4f"` 印。
    ///
    /// **不走 `JQNumber`**：那是 jq 的 dtoa 模型，這裡是 C 的 `%.4f`，兩者只有在
    /// 短小的十進位上剛好一樣。實跑 `/usr/bin/awk` 取證（`AWKParityTests` 每次都
    /// 重跑一遍，不是把答案抄進測試）：
    ///   `0.75` → `0.2500`、`0.7` → `0.3000`、`0.5` → `0.5000`、`1` → `0.0000`、
    ///   `0` → `1.0000`、`0.25` → `0.7500`、`abc` → `1.0000`（非數字是 0）、
    ///   `0x10` → `-15.0000`（macOS awk 認十六進位）、`inf` → `-inf`、`nan` → `nan`
    ///
    /// 回空字串 ＝ awk 一筆記錄都沒有（輸入是零位元組），於是 `$( )` 拿到空字串
    /// 而 bash 照樣送出 `--ratio abs:`。**空白**一個字元是一筆記錄（`$1` 是空 → 0
    /// → `1.0000`），與零位元組不同。
    static func oneMinusFirstField(_ input: String) -> String {
        // awk 逐筆記錄各印一次，輸出直接相接（格式字串沒有換行）。`ratio` 走過
        // `@tsv` 所以不可能含真正的換行，這裡照樣照抄，免得日後改了來源才發現。
        var records = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if records.last == "" {
            records.removeLast()
        }
        return records.map { record in
            // `$1`：預設 FS 是空白，開頭的空白跳過，取到下一個空白為止。
            let first = record.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? ""
            // awk 的字串→數字就是 strtod（吃得下前綴、十六進位、inf、nan；
            // 解不出來是 0），所以直接借它。
            let value = strtod(String(first), nil)
            return String(format: "%.4f", 1 - value)
        }.joined()
    }
}

/// `$(…)` 這個捕獲本身。
///
/// 它會**剝掉結尾的全部換行**（不是一個），所以 `x=$(printf 'a\n\n\n')` 之後 `$x`
/// 是 `a`。這件事在這個移植裡咬過四次，而且每次的症狀都不一樣：
///   - `cands=$(…) | tr '\n' ' '` 的結果**沒有**結尾空白（tr 拿不到那個換行）
///   - `json=$(cat layout.json)` 之後真實檔案的檔尾換行不見了
///   - `state=$(state_set …)` 之後再 `printf '%s\n'` 寫回去，才剛好是一個換行；
///     少了這一步就會每寫一次多長一行
///   - `dump=$(safari_tab_dump)` 之後 osascript 那兩個結尾換行只剩零個
///
/// 所以凡是 bash 那側用 `$(…)` 接住的東西，Swift 這側都要經過這裡一次。
enum CommandSubstitution {
    static func capture(_ text: String) -> String {
        var out = text
        while out.hasSuffix("\n") {
            out.removeLast()
        }
        return out
    }
}
