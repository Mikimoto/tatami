/// 這次執行是 LaunchServices 起的（＝選單列），還是人在命令列打的。
///
/// 同一個執行檔有兩種身分：`Tatami.app` 沒有參數就是選單列，而 `tatami` 是 CLI。
/// Finder 與 launchd 起一個 .app 時不給任何參數，所以光看參數分不出來。
///
/// **訊號是 `__CFBundleIdentifier`，不是 `Bundle.main.bundleIdentifier`。**
/// 後者只說「我在不在一個 bundle 裡」，而階段 B 之後那個答案永遠是「在」——
/// Homebrew cask 的 `binary` stanza 把 `tatami` 接到 PATH 上、指向 bundle 內的
/// 執行檔。那時裸打 `tatami` 會靜默多開一個選單列圖示而不是印用法字串。
///
/// 實測（2026-09-15）：
///
/// | 怎麼起的 | `__CFBundleIdentifier` |
/// |---|---|
/// | 終端機（Ghostty）裡跑 bundle 的執行檔 | `com.mitchellh.ghostty` |
/// | `open -a Tatami` | `com.deepthought.tatami` |
///
/// LaunchServices 把**被啟動那個 app 的** bundle id 放進環境；從終端機跑時那個
/// 變數是**終端機自己的**，因為子行程繼承了它。所以判準是「等不等於自己的」。
///
/// **不用 `isatty`**：管線與 cron 裡沒有 tty，但那些明明是命令列。
/// **不用 PPID**：背景行程會被 launchd 收養（CLAUDE.md 記過，PPID 變 1），
/// 那個訊號分不出「我被收養了」與「launchd 起的我」。
///
/// 判斷放 Core 因為它是判斷；讀環境變數那半在 CLI，而那一層沒有測試跑得到
/// （與 `SpaceWatchDecision`、`ConfigInput` 同一個分工）。
public enum LaunchContext: Equatable, Sendable {
    /// LaunchServices 起的：進選單列模式。
    case menuBarApp
    /// 人在命令列打的：照常走用法字串／子命令。
    case commandLine

    /// - Parameters:
    ///   - bundleIdentifier: `Bundle.main.bundleIdentifier`。裸執行檔是 nil。
    ///   - launchServicesIdentifier: 環境變數 `__CFBundleIdentifier`。
    public static func decide(bundleIdentifier: String?,
                              launchServicesIdentifier: String?) -> LaunchContext
    {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundleIdentifier == launchServicesIdentifier
        else { return .commandLine }
        return .menuBarApp
    }
}
