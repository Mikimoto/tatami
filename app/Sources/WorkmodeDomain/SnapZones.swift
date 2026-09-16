/// ⌥ 拖曳時浮出來的吸附區。
///
/// **trigger 與 target 是兩個矩形。** 游標落在 `trigger` 裡就選這一區，放開時視窗
/// 被放到 `target`。外圈那些兩者不同（游標在左上角那一塊 → 視窗排到左上
/// **四分之一**），樹的葉兩者相同。合成一個矩形會讓外圈做不出來：左半與左上
/// 四分之一的 target 重疊，光靠「點在哪個 target 裡」分不出使用者要哪一個。
public struct SnapZone: Equatable, Sendable {
    /// 游標落在這裡就選這一區。**彼此可以重疊**，見 `SnapZones.zone(at:)` 的優先序。
    public let trigger: Rect
    /// 放開時視窗被放到這裡。
    public let target: Rect
    /// 給人看的名字。測試與 `__smoke snap` 靠它分辨是哪一區。
    public let name: String

    public init(trigger: Rect, target: Rect, name: String) {
        self.trigger = trigger
        self.target = target
        self.name = name
    }
}

/// 吸附區的三層：外圈（半邊與田字）、中間圈（樹的葉）、正中央（整片）。
///
/// **為什麼不是單純的「樹優先」。** 那個第一版在使用者的設定上只給得出左右兩塊
/// ——那個 space 的樹只有兩個葉，而田字與整片只存在於九宮格 fallback，每個 space
/// 都畫過樹就永遠走不到。更尷尬的是量到那兩個葉（864／864，畫布寬 1728）
/// **剛好就是**九宮格的左半與右半，所以樹優先當時一格都沒有多給、卻擋掉了兩種目標。
public enum SnapZones {
    /// 邊緣帶佔**較短邊**的比例。用較短邊是為了讓寬螢幕與方螢幕手感一致
    /// （1084 高的畫布 → 163pt，那是好瞄的目標）。
    static let bandFraction = 0.15
    /// 正中央那塊佔畫布的比例（兩軸各自）。
    static let centreFraction = 0.20

    /// 這個 space 的吸附區，依**優先序**排好。
    ///
    /// `leaves` 空的（那個 space 沒畫過樹）＝中間圈也是「整片」，等於退回九宮格。
    public static func of(canvas: Rect, leaves: [Rect]) -> [SnapZone] {
        var out = ring(canvas: canvas)
        out.append(SnapZone(trigger: centre(of: canvas), target: canvas, name: "整片"))
        if leaves.isEmpty {
            // 中間圈：沒有樹就整塊都是「整片」。放在正中央之後，兩者答案相同，
            // 所以誰先命中不影響結果。
            out.append(SnapZone(trigger: canvas, target: canvas, name: "整片"))
        } else {
            out += leaves.enumerated().map { index, leaf in
                SnapZone(trigger: leaf, target: leaf, name: "格 \(index + 1)")
            }
        }
        return out
    }

    /// 沒有樹的那一份。`of(canvas:leaves: [])` 的別名，留著是因為「九宮格」
    /// 這個概念本身值得有名字。
    public static func grid(canvas: Rect) -> [SnapZone] {
        of(canvas: canvas, leaves: [])
    }

    /// 游標落在哪一區。都不在就回 nil（拖到螢幕外）。
    ///
    /// **順序即優先序：外圈 → 正中央 → 樹的葉，第一個命中的贏。**
    /// 三層之後葉的矩形覆蓋整個畫布，必定與外圈重疊，所以這件事不能再靠
    /// 「trigger 互不重疊」保證——它現在是一個明講的契約，由
    /// `theOuterRingWinsOverALeafUnderneath` 釘著。
    public static func zone(at point: MouseDrag.Point, in zones: [SnapZone]) -> SnapZone? {
        zones.first { contains($0.trigger, point) }
    }

    // MARK: - 三層各自的幾何

    /// 外圈那八塊。trigger 是「邊緣帶切出來的九宮格」的外圈（中間那格不算），
    /// target 是半邊或四分之一。
    private static func ring(canvas: Rect) -> [SnapZone] {
        let band = min(canvas.width, canvas.height) * bandFraction
        let columns = spans(origin: canvas.originX, extent: canvas.width, band: band)
        let rows = spans(origin: canvas.originY, extent: canvas.height, band: band)
        var out: [SnapZone] = []
        for row in 0 ..< 3 {
            for column in 0 ..< 3 where !(row == 1 && column == 1) {
                let trigger = Rect(originX: columns[column].start, originY: rows[row].start,
                                   width: columns[column].length, height: rows[row].length)
                let (target, name) = destination(canvas: canvas, row: row, column: column)
                out.append(SnapZone(trigger: trigger, target: target, name: name))
            }
        }
        return out
    }

    /// 一軸切三段：帶、中間、帶。中間那段可能是負的（畫布比兩條帶還窄），
    /// 夾成 0——那時外圈的兩條帶剛好接起來，中間圈消失，仍然是一個合法的分割。
    private static func spans(origin: Double, extent: Double,
                              band: Double) -> [(start: Double, length: Double)]
    {
        let edge = min(band, extent / 2)
        return [(origin, edge),
                (origin + edge, max(0, extent - edge * 2)),
                (origin + extent - edge, edge)]
    }

    /// 正中央那一塊，置中。
    private static func centre(of canvas: Rect) -> Rect {
        let width = canvas.width * centreFraction, height = canvas.height * centreFraction
        return Rect(originX: canvas.originX + (canvas.width - width) / 2,
                    originY: canvas.originY + (canvas.height - height) / 2,
                    width: width, height: height)
    }

    /// 外圈的每一塊對到哪。
    private static func destination(canvas: Rect, row: Int, column: Int) -> (Rect, String) {
        let vertical = ["上", "", "下"][row]
        let horizontal = ["左", "", "右"][column]
        if row == 1 {
            return (cell(canvas, rows: 1, columns: 2, row: 0, column: column == 0 ? 0 : 1),
                    horizontal + "半")
        }
        if column == 1 {
            return (cell(canvas, rows: 2, columns: 1, row: row == 0 ? 0 : 1, column: 0),
                    vertical + "半")
        }
        return (cell(canvas, rows: 2, columns: 2, row: row == 0 ? 0 : 1,
                     column: column == 0 ? 0 : 1), horizontal + vertical)
    }

    private static func cell(_ canvas: Rect, rows: Int, columns: Int,
                             row: Int, column: Int) -> Rect
    {
        WindowGeometry.cell(.init(rows: rows, columns: columns, originX: column,
                                  originY: row, width: 1, height: 1), canvas: canvas)
    }

    private static func contains(_ rect: Rect, _ point: MouseDrag.Point) -> Bool {
        point.posX >= rect.originX && point.posX < rect.originX + rect.width
            && point.posY >= rect.originY && point.posY < rect.originY + rect.height
    }
}
