/// `validate` 與 `fmt` 的輸入從哪裡來。
///
/// 那兩支是 stdin filter，而它們的對照組是 `jq .`——`tests/swift_checks.sh` 用
/// `< examples/layout.json` 餵它們，所以**管線與重導那條的行為一個位元組都不能變**。
///
/// 會變的只有 tty 那條。設定搬到 `~/.config/tatami` 之後，想檢查設定要打
/// `tatami validate < ~/.config/tatami/layout.json`——沒有人猜得到；而裸打
/// `tatami validate` 會**卡住等 stdin、一個字都不印**，那與「壞了」分不出來。
///
/// **判準是 `isatty` 不是「stdin 有沒有東西」**：後者要先讀才知道，而讀下去就已經
/// 卡住了。判斷放 Core 而 IO 留在 CLI，理由與 `SpaceWatchDecision` 逐字相同——
/// `WorkmodeCLI` 沒有 test target。
public enum ConfigInput: Equatable, Sendable {
    /// 管線或重導：照舊讀 stdin。
    case standardInput
    /// tty：讀 `TatamiPaths().layout`。
    case configFile

    /// - Parameter stdinIsTerminal: `isatty(0) != 0`。
    public static func choose(stdinIsTerminal: Bool) -> ConfigInput {
        stdinIsTerminal ? .configFile : .standardInput
    }
}
