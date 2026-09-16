/// 螢幕座標的矩形，CG 座標系（原點左上、y 往下），與 yabai 的 `frame` 與 AX 的
/// `kAXPositionAttribute` 同一套。欄位名不是 x/y/w/h：swiftlint `identifier_name`
/// 最短三字元（`DropZone.previewFraction` 同一個理由）。
public struct Rect: Equatable, Sendable {
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// 四個欄位都差不到 `tolerance`。AX 設 frame 是**請求**，app 可以夾、可以拒絕，
    /// 所以呼叫端拿設完重讀的值來問這個，而不是問相等。
    public func isClose(to other: Rect, within tolerance: Double) -> Bool {
        abs(originX - other.originX) <= tolerance && abs(originY - other.originY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
