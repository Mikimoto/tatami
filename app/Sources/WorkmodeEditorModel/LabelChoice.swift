import WorkmodeDomain

/// 可以拖到畫布上的一個 label。
///
/// **帶 `JSONValue` 而不只是字串**：`LayoutValidator.treeChecks` 比 label 用的是 jq 的
/// `==`（`LayoutValidator.swift:274`），數值與字面值分開——規則裡 `"label": 7`
/// 這一條，樹裡要寫**數字 7**，寫成字串 `"7"` 存檔會被擋下並報「不在生效的 windows
/// 清單裡」，而畫面上那兩個 7 長得一模一樣。
///
/// `display` 走 `JQPrint.interpolate`，與 validator 的訊息同一支，兩邊的字才會一致。
public struct LabelChoice: Equatable, Sendable {
    public let value: JSONValue
    public let display: String

    public init(value: JSONValue) {
        self.value = value
        display = JQPrint.interpolate(value)
    }
}
