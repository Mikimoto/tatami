import Testing
import WorkmodeCore

// 「這次執行是 LaunchServices 起的，還是人在命令列打的」。
//
// 同一個執行檔兩種身分：`Tatami.app` 沒有參數就是選單列，而 `tatami` 是 CLI。
// 分辨它們的訊號是 `__CFBundleIdentifier`——LaunchServices 起一個 app 時把**那個
// app 的** bundle id 放進環境變數，而從終端機跑時那個變數是**終端機自己的**
// （2026-09-15 實測：Ghostty 裡跑 bundle 的執行檔拿到 `com.mitchellh.ghostty`）。

private let own = "com.deepthought.tatami"

/// LaunchServices 起的：環境變數等於自己的 bundle id。
@Test func launchServicesStartsTheMenuBar() {
    #expect(LaunchContext.decide(bundleIdentifier: own,
                                 launchServicesIdentifier: own) == .menuBarApp)
}

/// **這一條是整組的理由。** 從終端機跑 bundle 內的執行檔——`bundleIdentifier` 不是
/// nil（舊的判準到這裡就錯了），而 `__CFBundleIdentifier` 是終端機的。
///
/// cask 的 `binary` stanza 把 `tatami` 指進 bundle 之後，這就是使用者裝完打的
/// 第一個命令走的路。
@Test func aTerminalInsideTheBundleIsStillTheCommandLine() {
    #expect(LaunchContext.decide(bundleIdentifier: own,
                                 launchServicesIdentifier: "com.mitchellh.ghostty")
            == .commandLine)
}

/// 裸執行檔（`.build/debug/tatami`）：`bundleIdentifier` 是 nil。
@Test func aBareExecutableIsTheCommandLine() {
    #expect(LaunchContext.decide(bundleIdentifier: nil,
                                 launchServicesIdentifier: nil) == .commandLine)
}

/// 沒有 `__CFBundleIdentifier`（例如 ssh 進來、或 launchd 直接 exec）：
/// 那不是 LaunchServices，所以是命令列。
@Test func noLaunchServicesVariableIsTheCommandLine() {
    #expect(LaunchContext.decide(bundleIdentifier: own,
                                 launchServicesIdentifier: nil) == .commandLine)
}
