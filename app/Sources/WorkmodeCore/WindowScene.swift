import WorkmodeDomain

/// 按下快捷鍵那一刻的畫面：焦點視窗是誰、它在哪個 space／螢幕、那個 space 上
/// 還有誰、以及那台螢幕的畫布。
///
/// 一次把三個 query 問完再交給動作，而不是每個動作自己去問：一次按鍵最多只該
/// 掃一次視窗清單（實測整趟 129ms），而且**每個動作看到的畫面要一致**——
/// 分開問的話 swap 可能拿到兩份不同時間的座標，症狀是兩個視窗疊在一起。
struct WindowScene {
    let focused: String
    let frame: Rect
    /// mission control 編號的字串，`YabaiCommand.moveToSpace` 吃的就是這個。
    let spaceIndex: String
    let displayIndex: String
    let canvas: Rect
    /// 同一個 space 上的全部視窗，**含焦點視窗自己**。
    let onSpace: [WindowGeometry.Placed]
    /// id → app 名（`app` 欄位，本地化名稱）。float 清單的比對用它。
    let appsByID: [String: String]
    let displays: [Display]
    let spaces: [Space]

    struct Display: Equatable, Sendable {
        let index: String
        let uuid: String
        let frame: Rect
    }

    struct Space: Equatable, Sendable {
        let index: String
        let display: String
        let isVisible: Bool
    }

    /// 焦點視窗以外的那些。方向動作要的是這個——把自己算進候選會讓
    /// 「距離 0」永遠贏。
    var others: [WindowGeometry.Placed] {
        onSpace.filter { $0.id != focused }
    }

    /// nil ＝ 沒有焦點視窗，或它不在任何查得到的 space 上（螢幕鎖著時就是這樣）。
    static func read(yabai: any YabaiClient, control: any WindowControl,
                     state: String) -> WindowScene?
    {
        guard let focused = try? control.focusedWindow(),
              let windowList = try? yabai.query(.windows),
              case let .array(rows) = windowList,
              let mine = rows.first(where: { $0["id"].map(JQPrint.raw) == focused }),
              let frame = rect(mine["frame"])
        else { return nil }
        let spaceIndex = mine["space"].map(JQPrint.raw) ?? ""
        let displayIndex = mine["display"].map(JQPrint.raw) ?? ""
        let displays = readDisplays(yabai)
        guard let display = displays.first(where: { $0.index == displayIndex })
        else { return nil }
        let canvas = LayoutCanvas.of(frame: display.frame, display: display.uuid, state: state)
        var appsByID: [String: String] = [:]
        let onSpace = rows.compactMap { row -> WindowGeometry.Placed? in
            guard row["space"].map(JQPrint.raw) == spaceIndex,
                  let id = row["id"].map(JQPrint.raw), let box = rect(row["frame"])
            else { return nil }
            if case let .string(app)? = row["app"] {
                appsByID[id] = app
            }
            return WindowGeometry.Placed(id: id, frame: box)
        }
        return WindowScene(focused: focused, frame: frame, spaceIndex: spaceIndex,
                           displayIndex: displayIndex, canvas: canvas.frame, onSpace: onSpace,
                           appsByID: appsByID, displays: displays, spaces: readSpaces(yabai))
    }

    private static func readDisplays(_ yabai: any YabaiClient) -> [Display] {
        guard case let .array(rows)? = try? yabai.query(.displays) else { return [] }
        return rows.compactMap { row in
            guard let index = row["index"].map(JQPrint.raw),
                  case let .string(uuid)? = row["uuid"], let frame = rect(row["frame"])
            else { return nil }
            return Display(index: index, uuid: uuid, frame: frame)
        }
    }

    private static func readSpaces(_ yabai: any YabaiClient) -> [Space] {
        guard case let .array(rows)? = try? yabai.query(.spaces) else { return [] }
        return rows.compactMap { row in
            guard let index = row["index"].map(JQPrint.raw),
                  let display = row["display"].map(JQPrint.raw) else { return nil }
            return Space(index: index, display: display,
                         isVisible: row["is-visible"] == .bool(true))
        }
    }

    /// `{x,y,w,h}` → `Rect`。缺任何一個欄位就 nil：半份 frame 排出來的視窗會
    /// 落在螢幕外，那比不動更糟（與 `SpaceLayout` 對缺欄位的 display 同一個立場）。
    static func rect(_ value: JSONValue?) -> Rect? {
        guard let value,
              let originX = number(value["x"]), let originY = number(value["y"]),
              let width = number(value["w"]), let height = number(value["h"])
        else { return nil }
        return Rect(originX: originX, originY: originY, width: width, height: height)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case let .number(literal)? = value else { return nil }
        return Double(literal)
    }
}
