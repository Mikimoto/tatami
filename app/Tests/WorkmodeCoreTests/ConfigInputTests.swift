import Testing
import WorkmodeCore

// `validate` 與 `fmt` 的輸入從哪裡來。
//
// 這兩支是 stdin filter（對照組是 `jq .`，而 `tests/swift_checks.sh` 用重導餵它們），
// 所以**管線與重導那條一個位元組都不能變**。會變的只有 tty：人在終端機裸打
// `tatami validate` 時 `readDataToEndOfFile()` 會卡住等輸入、一個字都不印，
// 而那與「壞了」在畫面上分不出來。

@Test func aPipeOrRedirectStillReadsStandardInput() {
    #expect(ConfigInput.choose(stdinIsTerminal: false) == .standardInput)
}

/// tty ＝ 沒有人餵東西進來，那就讀使用者唯一會想驗的那份檔。
@Test func aTerminalReadsTheConfigFile() {
    #expect(ConfigInput.choose(stdinIsTerminal: true) == .configFile)
}
