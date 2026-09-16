import WorkmodeDomain

/// 挑選器上的一個候選條件：寫進 `match` 的那一對，加上給人看的說明。
public struct RuleCondition: Equatable, Sendable {
    /// **用 `WindowMatching.Kind` 而不是 `String`**：那個 enum 是四種條件的唯一
    /// 來源，寫成字串就要在這裡再抄一次那四個字面值。它的 raw value 正好就是
    /// 寫進 `match[0]` 的字串。
    public let kind: WindowMatching.Kind
    /// 寫進 `match[1]` 的預設值。
    public let value: String
    /// 顯示用。
    public let summary: String

    public init(kind: WindowMatching.Kind, value: String, summary: String) {
        self.kind = kind
        self.value = value
        self.summary = summary
    }
}

public extension WindowChoice {
    /// 這個視窗能用哪些條件。
    ///
    /// **判準是 `tabURL == nil`，不是 `app == "Safari"`。** 四種裡只有 `app` 讀
    /// `yabai -m query --windows`（`RuleResolution.appCandidates`）；其餘三種全部走
    /// Safari 的分頁 dump（`WindowMatching.swift:108-116`），dump 裡沒有這個 window
    /// id 就永遠配不到。硬編 app 名稱只是換一個會錯的判準——使用者改了顯示名稱、
    /// 或未來換一個也吐分頁的瀏覽器，兩邊就分岔。
    var conditions: [RuleCondition] {
        var out = [RuleCondition(kind: .app, value: app, summary: "App 名稱")]
        guard let tabURL, let tabTitle else { return out }
        out.append(RuleCondition(kind: .urlExact, value: tabURL,
                                 summary: "完整網址（尾斜線會被容忍）"))
        out.append(RuleCondition(kind: .urlContains, value: Self.host(of: tabURL),
                                 summary: "網址含這一段"))
        // **值是 regex，所以要跳脫。** 實測 `Zed (workmode)` 當 pattern 配不到
        // 字面的 `Zed (workmode)`（括號是 group）。
        out.append(RuleCondition(kind: .titleRegex,
                                 value: AwkRegex.escapingLiteral(tabTitle),
                                 summary: "分頁標題（regex，已跳脫）"))
        return out
    }

    /// 網址的 host。`//` 之後到第一個 `/`、`?` 或 `#` 為止。
    ///
    /// **取不出來就退回完整網址**，不回 nil：少一個選項的挑選器與「這個視窗不支援
    /// url-contains」在畫面上分不出來，而使用者可以自己把值改短。
    ///
    /// 用 `firstRange(of:)`（標準庫）而不是 Foundation 的 `range(of:)`：
    /// `WorkmodeEditorModel` 只准 import `WorkmodeDomain`，`DependencyRuleTests`
    /// 的 `editorLayersKeepTheirDistance` 會擋下 `import Foundation`。
    static func host(of url: String) -> String {
        guard let start = url.firstRange(of: "//")?.upperBound else { return url }
        let rest = url[start...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
        let host = String(rest[rest.startIndex ..< (end ?? rest.endIndex)])
        return host.isEmpty ? url : host
    }
}
