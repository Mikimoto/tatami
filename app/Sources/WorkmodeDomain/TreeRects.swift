/// 把一棵 `spaceTrees` 的樹攤成「每個葉一個矩形」。`RectTree.fromRects` 的反向。
///
/// yabai 那條路（`TreeLayout`）把樹翻成 `--warp`／`--swap`／`--ratio` 再事後量測修正；
/// 這裡直接算座標，因為 AX 設 frame 沒有「插入方向不固定」那種事。
public enum TreeRects {
    public struct Leaf: Equatable, Sendable {
        public let window: JSONValue
        public let rect: Rect

        public init(window: JSONValue, rect: Rect) {
            self.window = window
            self.rect = rect
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// 節點既沒有 `window` 也不是合法的分割。`validate` 會先擋，所以走到這裡是 bug。
        case malformed
    }

    /// 前序：與 `LayoutTree.splits` 同一個走訪順序，葉的順序就是畫面上左→右、上→下。
    public static func leaves(of node: JSONValue, in rect: Rect) throws -> [Leaf] {
        guard case .object = node else { throw Failure.malformed }
        if let window = node["window"] {
            return [Leaf(window: window, rect: rect)]
        }
        guard case let .string(axis)? = node["axis"],
              case let .array(children)? = node["children"], children.count == 2
        else { throw Failure.malformed }

        // ratio 只掛在葉上（`RectTree.stamp`）：第一個 child 是葉就用它的，
        // 是分割就從第二個葉反推；兩個都沒有就均分。
        let share = ratio(of: children[0]) ?? ratio(of: children[1]).map { 1 - $0 } ?? 0.5
        // 第二塊的尺寸用**減法**算，不是 `size * (1 - share)`：兩塊必須剛好鋪滿父矩形。
        // 乘法在 double 下辦不到——實測 `1000 * (1 - 0.7)` 是 300.00000000000006 而
        // `1000 - 1000 * 0.7` 是 300.0，於是右緣落在父矩形外 6e-14。這個誤差本身小到
        // 看不見，但它讓「兩塊加起來等於父」不成立，而 `RectTree.fromRects` 的切線
        // 判準正是「沒有矩形跨越切線」——量回來的 frame 再餵回去就可能切不開。
        // `theSecondChildIsTheParentMinusTheFirst` 釘著它——注意那條問的是「第二塊的
        // 值等不等於父減第一塊」而不是「兩塊加起來等不等於父」：後者沒有牙齒，
        // 6e-14 在 1000 附近的加法裡會被 ULP 吸收掉（實測 700 + 300.00000000000006
        // 就是 1000.0）。
        let cutX = rect.width * share
        let cutY = rect.height * share
        let (first, second): (Rect, Rect) = switch axis {
        case "vertical":
            (Rect(originX: rect.originX, originY: rect.originY,
                  width: cutX, height: rect.height),
             Rect(originX: rect.originX + cutX, originY: rect.originY,
                  width: rect.width - cutX, height: rect.height))
        case "horizontal":
            (Rect(originX: rect.originX, originY: rect.originY,
                  width: rect.width, height: cutY),
             Rect(originX: rect.originX, originY: rect.originY + cutY,
                  width: rect.width, height: rect.height - cutY))
        default:
            throw Failure.malformed
        }
        return try leaves(of: children[0], in: first) + leaves(of: children[1], in: second)
    }

    /// 0 與 1 之外的值當成沒有：0 會讓一個視窗消失，而那不是任何人的意圖。
    private static func ratio(of node: JSONValue) -> Double? {
        guard case let .number(text)? = node["ratio"], let value = Double(text),
              value > 0, value < 1 else { return nil }
        return value
    }
}
