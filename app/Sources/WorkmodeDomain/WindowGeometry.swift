/// 快捷鍵動作要的幾何，全部是純函式。
///
/// 這裡沒有 bsp 樹——**除了**兩個刻意反過來走的動作：`balance` 與 `rotate` 先把
/// 現在的矩形餵給 `RectTree.fromRects` 推回一棵樹，改完再用 `TreeRects.leaves`
/// 排回去。那條路已經有 436 組凍結語料在守，自己重寫一套「均分」只是多一個
/// 沒有人在驗的演算法。
public enum WindowGeometry {
    /// 一個視窗現在在哪。`id` 是 yabai 形狀的十進位字串。
    public struct Placed: Equatable, Sendable {
        public let id: String
        public let frame: Rect

        public init(id: String, frame: Rect) {
            self.id = id
            self.frame = frame
        }
    }

    /// 那個方向最近的鄰居。沒有就 nil。
    ///
    /// 兩段式：先取**垂直軸上有重疊**的（並排的視窗，那是使用者按方向鍵時想的東西），
    /// 那組裡挑軸向距離最小的；一個都沒有才退回中心點距離最近的。
    /// 只用中心點距離的話，一個又高又窄的鄰居會輸給對角線上那個——而畫面上
    /// 它明明就在旁邊。
    public static func neighbour(of frame: Rect, among windows: [Placed],
                                 direction: HotkeyAction.Direction) -> Placed?
    {
        let candidates = windows.filter { isBeyond($0.frame, frame, direction) }
        guard !candidates.isEmpty else { return nil }
        let aligned = candidates.filter { overlapsAcross($0.frame, frame, direction) }
        let pool = aligned.isEmpty ? candidates : aligned
        return pool.min { lhs, rhs in
            let left = aligned.isEmpty ? centreDistance(lhs.frame, frame)
                : axisDistance(lhs.frame, frame, direction)
            let right = aligned.isEmpty ? centreDistance(rhs.frame, frame)
                : axisDistance(rhs.frame, frame, direction)
            // 距離相同時用 id 決勝，讓結果不依賴 `min` 的走訪順序——不然
            // 「按左鍵跳到哪」會隨查詢回來的順序變，而那看起來就是隨機。
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    /// 「疊在同一個位置」的那一群，含自己。yabai 的 stack 在這條路上沒有對應的
    /// 狀態，所以它就是幾何：四個數字都在容差內。
    ///
    /// 容差 20pt 是猜的，但它必須大於 0——`setFrame` 是**請求**，app 可以夾
    /// （實測一個高 1409 的視窗被夾成 1374），逐位元組相等的兩個 frame 在實機上
    /// 幾乎不存在。
    public static func stack(around frame: Rect, among windows: [Placed],
                             tolerance: Double = 20) -> [Placed]
    {
        windows.filter { $0.frame.isClose(to: frame, within: tolerance) }
            .sorted { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count }
    }

    /// yabai `--grid rows:columns:x:y:w:h` 的那一組數字。
    ///
    /// 包成 struct 而不是 6 個參數，是為了過 swiftlint 的
    /// `function_parameter_count`（上限 5，不准調參數；`SpaceTargets.RoleSite`
    /// 是同一個理由的先例）。
    public struct GridSpec: Equatable, Sendable {
        public let rows: Int
        public let columns: Int
        public let originX: Int
        public let originY: Int
        public let width: Int
        public let height: Int

        public init(rows: Int, columns: Int, originX: Int, originY: Int,
                    width: Int, height: Int)
        {
            self.rows = rows
            self.columns = columns
            self.originX = originX
            self.originY = originY
            self.width = width
            self.height = height
        }
    }

    /// 那一格在畫布上的矩形。
    ///
    /// 邊界一律 `origin + extent * i / n` 再相減（與 `TreeRects`／`GridSelection`
    /// 同一條紀律）：`n/n` 在 IEEE 下恰為 1.0，所以最後一格精確落在畫布邊緣。
    /// 索引夾回範圍內——設定檔是人寫的，`grid:2:2:5:0:1:1` 打得出來。
    public static func cell(_ spec: GridSpec, canvas: Rect) -> Rect {
        let columns = max(1, spec.columns), rows = max(1, spec.rows)
        let columnStart = min(max(0, spec.originX), columns - 1)
        let rowStart = min(max(0, spec.originY), rows - 1)
        let columnEnd = min(columns, columnStart + max(1, spec.width))
        let rowEnd = min(rows, rowStart + max(1, spec.height))
        let left = canvas.originX + canvas.width * Double(columnStart) / Double(columns)
        let right = canvas.originX + canvas.width * Double(columnEnd) / Double(columns)
        let top = canvas.originY + canvas.height * Double(rowStart) / Double(rows)
        let bottom = canvas.originY + canvas.height * Double(rowEnd) / Double(rows)
        return Rect(originX: left, originY: top, width: right - left, height: bottom - top)
    }

    /// 相對改變寬高，左上角不動；超出畫布就往回推。
    ///
    /// 下限 `minimumSide` 不是保險：0 或負的寬會讓一個視窗整個消失，而
    /// `AXUIElementSetAttributeValue` 對那種值不一定會拒絕。
    public static func resized(_ frame: Rect, deltaWidth: Double, deltaHeight: Double,
                               canvas: Rect, minimumSide: Double = 120) -> Rect
    {
        let width = min(max(minimumSide, frame.width + deltaWidth), canvas.width)
        let height = min(max(minimumSide, frame.height + deltaHeight), canvas.height)
        let originX = min(frame.originX, canvas.originX + canvas.width - width)
        let originY = min(frame.originY, canvas.originY + canvas.height - height)
        return Rect(originX: max(canvas.originX, originX),
                    originY: max(canvas.originY, originY),
                    width: width, height: height)
    }

    // MARK: - 走樹的那兩個

    /// 餵給 `RectTree.fromRects` 的形狀（`[{label,x,y,w,h}, …]`）。
    /// label 就是 window id，所以排完之後 `TreeRects.Leaf.window` 直接是要設的對象。
    public static func rects(of windows: [Placed]) -> JSONValue {
        .array(windows.map { window in
            .object([
                JSONMember(key: "label", value: .string(window.id)),
                JSONMember(key: "x", value: .number(JQNumber.text(window.frame.originX))),
                JSONMember(key: "y", value: .number(JQNumber.text(window.frame.originY))),
                JSONMember(key: "w", value: .number(JQNumber.text(window.frame.width))),
                JSONMember(key: "h", value: .number(JQNumber.text(window.frame.height))),
            ])
        })
    }

    /// 拿掉每個 `ratio`＝均分。yabai 的 `space --balance` 做的就是這件事。
    public static func withoutRatios(_ node: JSONValue) -> JSONValue {
        transform(node) { members in members.filter { $0.key != "ratio" } }
    }

    /// 每個 `axis` 橫縱對調＝把版面轉 90°。
    ///
    /// **不分順逆時針**：一棵二元切割樹轉 90° 與轉 270° 產生的畫面在葉的位置上
    /// 只差一個鏡射，而鏡射要重排 children 的順序；yabai 那兩條鍵的差別在
    /// bsp 的插入方向，那個東西在這裡不存在。兩條鍵都保留是因為使用者的手記得
    /// 它們，而按下去確實會轉。
    public static func withFlippedAxes(_ node: JSONValue) -> JSONValue {
        transform(node) { members in
            members.map { member in
                guard member.key == "axis" else { return member }
                let flipped: JSONValue = member.value == .string("vertical")
                    ? .string("horizontal") : .string("vertical")
                return JSONMember(key: "axis", value: flipped)
            }
        }
    }

    private static func transform(_ node: JSONValue,
                                  _ edit: ([JSONMember]) -> [JSONMember]) -> JSONValue
    {
        switch node {
        case let .object(members):
            .object(edit(members).map { JSONMember(key: $0.key, value: transform($0.value, edit)) })
        case let .array(items):
            .array(items.map { transform($0, edit) })
        default:
            node
        }
    }

    // MARK: - 方向的四個問句

    private static func isBeyond(_ other: Rect, _ frame: Rect,
                                 _ direction: HotkeyAction.Direction) -> Bool
    {
        switch direction {
        case .west: midX(other) < midX(frame)
        case .east: midX(other) > midX(frame)
        case .north: midY(other) < midY(frame)
        case .south: midY(other) > midY(frame)
        }
    }

    /// 垂直於移動方向的那一軸上有沒有重疊。
    private static func overlapsAcross(_ other: Rect, _ frame: Rect,
                                       _ direction: HotkeyAction.Direction) -> Bool
    {
        switch direction {
        case .west, .east:
            other.originY < frame.originY + frame.height
                && frame.originY < other.originY + other.height
        case .north, .south:
            other.originX < frame.originX + frame.width
                && frame.originX < other.originX + other.width
        }
    }

    private static func axisDistance(_ other: Rect, _ frame: Rect,
                                     _ direction: HotkeyAction.Direction) -> Double
    {
        switch direction {
        case .west, .east: abs(midX(other) - midX(frame))
        case .north, .south: abs(midY(other) - midY(frame))
        }
    }

    private static func centreDistance(_ other: Rect, _ frame: Rect) -> Double {
        let deltaX = midX(other) - midX(frame), deltaY = midY(other) - midY(frame)
        return deltaX * deltaX + deltaY * deltaY
    }

    private static func midX(_ rect: Rect) -> Double {
        rect.originX + rect.width / 2
    }

    private static func midY(_ rect: Rect) -> Double {
        rect.originY + rect.height / 2
    }
}
