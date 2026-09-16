import Foundation

/// 從 `#filePath` 往上爬到 repo 根目錄。不用 cwd：`swift test` 的工作目錄
/// 不保證是 package 根目錄。
///
/// 這一份是 `WorkmodeDomainTests` 共用的，而**現在只剩一個消費端**：`HotkeyTests`
/// 的三處呼叫，讀 `tests/skhdrc-retired-bindings.txt` 與
/// `tests/default-float-apps.txt` 那兩份凍結副本。
/// （2026-09-15 之前是三個檔：`SignalBlockTests`、`YabaircScriptTests`、
/// `YabaiSettingsTests`，全部隨 yabai 退場一起刪了。留著這個檔案而不併回
/// `HotkeyTests` 是因為下一個要讀 repo 內凍結檔的測試還是會需要它。）
///
/// `#filePath` 對每個檔案都是它自己的路徑——只要用它的檔都住在
/// `app/Tests/WorkmodeDomainTests/`，往上爬四層的結果就相同。
/// 換句話說，這個 helper 搬家（往上或往下一層）會靜默算出錯的根目錄。
/// 另外兩個 target（`WorkmodeWireTests`、`WorkmodeEditorModelTests`）各有自己的
/// `private func repoRoot()`，與這一份無關。
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // app/Tests/WorkmodeDomainTests/
        .deletingLastPathComponent() // app/Tests/
        .deletingLastPathComponent() // app/
        .deletingLastPathComponent() // repo 根目錄
}
