import Foundation
import WorkmodeAdapters
import WorkmodeCore

/// `ConfigInput` 的接線：把那個判斷變成真的一串位元組。
///
/// 這一層沒有測試跑得到（`WorkmodeCLI` 沒有 test target），所以裡面**只有 IO**，
/// 一個判斷都不留——「從哪裡讀」在 `ConfigInput`，那支有兩條測試。
enum ConfigSource {
    /// - Returns: 讀到的全文；tty 那條讀不到設定檔時回 nil，讓呼叫端印自己的訊息。
    ///   stdin 那條**永遠**回字串（空輸入就是空字串），與改動之前逐字相同。
    static func read() -> String? {
        switch ConfigInput.choose(stdinIsTerminal: isatty(0) != 0) {
        case .standardInput:
            String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        case .configFile:
            try? String(contentsOf: URL(fileURLWithPath: TatamiPaths().layout),
                        encoding: .utf8)
        }
    }

    /// tty 那條讀不到檔時要印的路徑，讓訊息講得出「找不到的是哪一個」。
    static var configPath: String {
        TatamiPaths().layout
    }
}
