import WorkmodeCore

/// 一次 `SpaceLayout` 的結果：它回的 outcome，加上它一路發出的事件文字。
///
/// 事件文字由呼叫端收集，因為把事件變成中文的 renderer 住在 `WorkmodeAdapters`
/// ——這一層不准 import 它（`DependencyRuleTests.editorLayersKeepTheirDistance`）。
///
/// **2026-08-30 之前這裡釘的是 `ApplyLayout.Outcome`。** 兩個列舉的 case 完全相同
/// （`completed`／`layoutUnavailable`／`locationUnrecognized`／`profileUnresolved`），
/// 而 UI 那層是用 leading-dot 的 pattern match 讀它（型別名在那層叫不出來，
/// 見 `ApplyButton.outcomeText` 的 doc），所以換型別不必動那幾個 pattern。
public struct ApplyRun: Equatable, Sendable {
    public let outcome: SpaceLayout.Outcome
    public let lines: [String]

    public init(outcome: SpaceLayout.Outcome, lines: [String]) {
        self.outcome = outcome
        self.lines = lines
    }
}

/// ⌘R 能不能按，不能的話為什麼。
///
/// **回列舉不回 Bool**：三種情況要使用者做的事完全不同（去存檔／這個編輯器沒接線／
/// 可以按了），一句話講不完。
///
/// **2026-08-30 拿掉 `wrongLocation` 與 `probeFailed`。** 那兩種只有 probe 產生得
/// 出來，而 ⌘R 改跑 `SpaceLayout` 之後沒有 probe 可跑——`--space` 不流放也不聚集，
/// 弄錯 profile 的後果比 `ApplyLayout` 小得多，不值得為了一句抬頭文字多一條要驗的
/// 路徑（附帶好處：確認框現在立刻出現，舊版要先等那次 probe 無條件 dump Safari
/// 分頁，實測約兩秒）。
public enum ApplyReadiness: Equatable, Sendable {
    /// 可以套用。
    case ready
    /// 有未存的變更。`SpaceLayout` 從磁碟讀設定，套下去是舊檔。
    case notSaved
    /// 這個 controller 沒有被注入 `run`（測試，或 CLI 還沒接線）。
    case notWired
}
