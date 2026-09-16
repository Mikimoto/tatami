/// fn ＋ 拖曳搬視窗、fn ＋ 右鍵拖曳縮放的幾何。
///
/// 取代 yabai 的 `mouse_modifier` ＋ `mouse_action1/2`——那是它最後一個還在做的
/// 工作。全部是純函式，所以「抓在哪一角就動哪一角」這種手感問題有測試釘著；
/// 裝事件監聽那一層（`MouseTap`）一次除法都不做。
public struct MouseDrag: Equatable, Sendable {
    /// 按住修飾鍵按下滑鼠的那一刻記下來的東西。
    public let window: String
    /// 按下的那一點（螢幕座標，CG 那一套：原點在主螢幕左上、y 往下）。
    public let origin: Point
    /// 按下當時那個視窗的 frame。**記起來而不是每次重讀**：AX 設 frame 之後
    /// 要 85–115ms 才追得上（`WindowServerClient` 的實測），每次拖曳事件都重讀
    /// 會拿到舊值，於是位移一路累積錯下去。
    public let frame: Rect
    public let action: Action
    /// resize 時被拖動的那一角。move 時無意義。
    public let corner: Corner

    public enum Action: String, CaseIterable, Sendable {
        case move, resize
    }

    /// 視窗的四個角。
    public enum Corner: Equatable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public struct Point: Equatable, Sendable {
        public let posX: Double
        public let posY: Double

        public init(posX: Double, posY: Double) {
            self.posX = posX
            self.posY = posY
        }
    }

    public init(window: String, origin: Point, frame: Rect, action: Action) {
        self.window = window
        self.origin = origin
        self.frame = frame
        self.action = action
        corner = Self.nearestCorner(to: origin, of: frame)
    }

    /// 滑鼠移到 `point` 時那個視窗該有的 frame。
    ///
    /// **一律從按下當時的 frame 加總位移算**，不是「在上一個 frame 上再加一次
    /// 這次的小位移」：後者會把 app 夾過的結果（最小尺寸、拒絕）當成新的基準，
    /// 於是視窗愈拖愈偏，而每一步看起來都只差一點。
    public func frame(at point: Point, minimumSide: Double = 120) -> Rect {
        let deltaX = point.posX - origin.posX, deltaY = point.posY - origin.posY
        switch action {
        case .move:
            return Rect(originX: frame.originX + deltaX, originY: frame.originY + deltaY,
                        width: frame.width, height: frame.height)
        case .resize:
            return resized(deltaX, deltaY, minimumSide)
        }
    }

    /// 被拖的那一角跟著滑鼠，對面那一角釘住。
    ///
    /// 下限用**夾住被拖的那一角**而不是夾寬高：夾寬高會讓釘住的那一角在拖過頭時
    /// 開始移動，而畫面上那看起來像整個視窗突然跳走。
    private func resized(_ deltaX: Double, _ deltaY: Double, _ minimumSide: Double) -> Rect {
        let right = frame.originX + frame.width, bottom = frame.originY + frame.height
        var left = frame.originX, top = frame.originY
        var newRight = right, newBottom = bottom
        switch corner {
        case .topLeft:
            left = min(frame.originX + deltaX, right - minimumSide)
            top = min(frame.originY + deltaY, bottom - minimumSide)
        case .topRight:
            newRight = max(right + deltaX, left + minimumSide)
            top = min(frame.originY + deltaY, bottom - minimumSide)
        case .bottomLeft:
            left = min(frame.originX + deltaX, right - minimumSide)
            newBottom = max(bottom + deltaY, top + minimumSide)
        case .bottomRight:
            newRight = max(right + deltaX, left + minimumSide)
            newBottom = max(bottom + deltaY, top + minimumSide)
        }
        return Rect(originX: left, originY: top,
                    width: newRight - left, height: newBottom - top)
    }

    /// 按下的那一點落在視窗的哪一個象限。
    ///
    /// 中線用 `<`（不是 `<=`）：恰好在中線上算右／下。哪一邊贏不重要，
    /// **有一個確定的答案**才重要——不然抓在正中央時每次拖的角都不一樣。
    static func nearestCorner(to point: Point, of frame: Rect) -> Corner {
        let isLeft = point.posX < frame.originX + frame.width / 2
        let isTop = point.posY < frame.originY + frame.height / 2
        switch (isLeft, isTop) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}
