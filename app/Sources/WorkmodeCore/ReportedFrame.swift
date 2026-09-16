/// `report_rules` 那一行裡 frame 的四個值。
///
/// 收成一個型別而不是四個並排的參數：它們一起來自 yabai 的 `.frame`，一起被 `floor`
/// 過，也一起出現在那一行的尾巴。四個並排時呼叫端很容易把 width 與 height 對調而
/// 編譯器不會說話——它們同型別。
///
/// 全是 `String`：這一行不是 `printf` 印的而是 jq 的字串插值印的，四個值都走
/// `JQNumber` 的 dtoa 模型（`1e999 | floor` 印成 `1.7976931348623157e+308`）。
/// 轉成數字會把那些形狀丟掉，而它們是實際會出現在終端機上的位元組。
public struct ReportedFrame: Equatable, Sendable {
    public let width: String
    public let height: String
    public let originX: String
    public let originY: String

    public init(width: String, height: String, originX: String, originY: String) {
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
    }
}
