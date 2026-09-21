import Foundation
import WorkmodeAdapters

/// 開一個新的 `tatami <子命令>`。
///
/// **三個入口共用這一份**：選單列的「格線」與「編輯設定」
/// （`MenuCommand`）、以及 ⌃⌥⌘G（`HotkeyCommand`）。它們在 0.1.0 是兩份幾乎
/// 相同的程式碼，各自寫死同一條路徑——所以它們一起壞掉，而修其中一份不會讓
/// 另一份好起來。合成一份的理由就是這個，不是為了少幾行。
///
/// **不在 `MenuActions` 裡**：那個 enum 是 `@MainActor`（它碰 `NSMenu`），而
/// `HotkeyRuntime` 不是，呼叫會編不過。spawn 一個子行程與 main actor 無關。
///
/// **不等它結束、也不看 exit code**：子行程自己會把話印到自己的 stderr，而
/// 選單列不該卡在那裡等一個 GUI 面板被關掉。
enum SpawnTatami {
    static func run(_ arguments: [String]) {
        let label = (["tatami"] + arguments).joined(separator: " ")
        guard let executable = TatamiPaths.runningExecutable else {
            complain("開不了「\(label)」：查不到這個 app 自己的執行檔路徑。")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            complain("開不了「\(label)」：\(executable) 起不來（\(error.localizedDescription)）。")
        }
    }

    /// **起不起得來要說出來。**
    ///
    /// 原本兩個呼叫點都是 `try? process.run()`，而 0.1.0 把路徑寫死成一條 cask
    /// 使用者不會有的 symlink——三個入口對他們全部無效，而那個 `try?` 把 ENOENT
    /// 吞掉，所以連 log 都沒有一個字。「按了沒反應」與「這個功能不存在」在畫面上
    /// 分不出來，而這個專案花了一整個版本才發現。
    ///
    /// 選單列沒有地方顯示這種話，所以走 stderr——與其餘事件同一條路
    /// （`open -a Tatami --stderr <檔>` 讀得到）。
    private static func complain(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
