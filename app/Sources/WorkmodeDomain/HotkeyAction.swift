/// 一個快捷鍵要做的事。
///
/// 字串形式（`focus:west`、`grid:2:2:0:0:1:1`）是設定檔裡存的東西，round-trip
/// 有測試釘著。用字串而不是巢狀 JSON 物件，理由是這份檔案要人看得懂也改得動，
/// 而每個動作的參數數量差很多——攤成物件會讓一半的鍵在一半的動作上不存在。
///
/// **這裡沒有 bsp 的概念**（樹、parent、split、managed／float）。yabai 那些動作
/// 在這條路上一律換成幾何近似：`balance` 是把目前 space 的視窗均分，`rotate` 是
/// 把版面轉 90°，`stack` 是把視窗疊到鄰居的位置上。近似不等於相同——`toggle split`
/// 與 `zoom-parent` 沒有近似物（它們問的是樹的形狀），所以它們不在這個 enum 裡。
public enum HotkeyAction: Hashable, Sendable {
    case focusWindow(Direction)
    case swapWindow(Direction)
    /// 把焦點視窗疊到那個方向的鄰居身上（同一個 frame）。yabai 的 `--stack` 近似。
    case stackWindow(Direction)
    /// 在「跟焦點視窗幾乎同位置」的那群視窗裡循環焦點。yabai 的 `stack.next` 近似。
    case focusStack(next: Bool)
    case moveToSpace(Target)
    case moveToDisplay(Target)
    /// 參數順序與 yabai 的 `--grid` 逐字相同（rows:cols:x:y:w:h），
    /// 所以 `skhdrc` 那幾條可以一個字不改地抄過來。
    case placeGrid(rows: Int, columns: Int, originX: Int, originY: Int, width: Int, height: Int)
    /// 相對改變寬高，原點不動。
    case resizeWindow(deltaWidth: Int, deltaHeight: Int)
    case closeWindow
    /// 填滿整塊畫布；已經填滿就還原成上一次的 frame。
    case toggleFullscreen
    case balanceSpace
    case rotateSpace(clockwise: Bool)
    case toggleGaps
    case applyLayout(all: Bool)
    case showGrid
    /// 逃生門：交給 `/bin/sh -c`。存在的理由是 `skhdrc` 裡有與視窗管理無關的
    /// 綁定（顯示／隱藏桌面那條改的是 Finder 的 defaults），少了它那個檔就退不了役。
    /// 信任層級與 `skhdrc` 相同——那個檔本來就是使用者自己寫的 shell。
    case runShell(String)

    public enum Direction: String, CaseIterable, Sendable {
        case west, east, north, south
    }

    /// space 與 display 共用：不是絕對編號就是相對移動。
    public enum Target: Hashable, Sendable {
        case index(Int)
        case next
        case previous

        public var text: String {
            switch self {
            case let .index(value): String(value)
            case .next: "next"
            case .previous: "prev"
            }
        }

        static func parse(_ text: String) -> Target? {
            switch text {
            case "next": .next
            case "prev": .previous
            default: Int(text).map(Target.index)
            }
        }
    }

    public var text: String {
        switch self {
        case let .focusWindow(direction): "focus:\(direction.rawValue)"
        case let .swapWindow(direction): "swap:\(direction.rawValue)"
        case let .stackWindow(direction): "stack:\(direction.rawValue)"
        case let .focusStack(next): "stack-focus:\(next ? "next" : "prev")"
        case let .moveToSpace(target): "space:\(target.text)"
        case let .moveToDisplay(target): "display:\(target.text)"
        case let .placeGrid(rows, columns, originX, originY, width, height):
            "grid:\(rows):\(columns):\(originX):\(originY):\(width):\(height)"
        case let .resizeWindow(deltaWidth, deltaHeight):
            "resize:\(deltaWidth):\(deltaHeight)"
        case .closeWindow: "close"
        case .toggleFullscreen: "fullscreen"
        case .balanceSpace: "balance"
        case let .rotateSpace(clockwise): "rotate:\(clockwise ? "cw" : "ccw")"
        case .toggleGaps: "gaps"
        case let .applyLayout(all): "apply:\(all ? "all" : "visible")"
        case .showGrid: "grid-picker"
        case let .runShell(command): "shell:\(command)"
        }
    }

    /// 認不得的一律回 nil，呼叫端把那一條當成壞掉的設定並說出來。
    /// **不要在這裡容錯**：一條解不出來的規則安靜地不註冊，症狀是「這個鍵沒反應」。
    public static func parse(_ text: String) -> HotkeyAction? {
        // `shell:` 的參數是一整條命令，裡面本來就會有 `:`（路徑、URL），
        // 所以它在切開之前就先被撈走。
        if text.hasPrefix("shell:") {
            let command = String(text.dropFirst("shell:".count))
            return command.isEmpty ? nil : .runShell(command)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first else { return nil }
        let rest = Array(parts.dropFirst())
        if rest.isEmpty {
            return parseNullary(head)
        }
        return parseWithArguments(head, rest)
    }

    private static func parseNullary(_ head: String) -> HotkeyAction? {
        switch head {
        case "close": .closeWindow
        case "fullscreen": .toggleFullscreen
        case "balance": .balanceSpace
        case "gaps": .toggleGaps
        case "grid-picker": .showGrid
        default: nil
        }
    }

    private static func parseWithArguments(_ head: String, _ rest: [String]) -> HotkeyAction? {
        if rest.count == 1, let directional = parseDirectional(head, rest[0]) {
            return directional
        }
        switch (head, rest.count) {
        case ("stack-focus", 1):
            return rest[0] == "next" ? .focusStack(next: true)
                : rest[0] == "prev" ? .focusStack(next: false) : nil
        case ("space", 1): return Target.parse(rest[0]).map(HotkeyAction.moveToSpace)
        case ("display", 1): return Target.parse(rest[0]).map(HotkeyAction.moveToDisplay)
        case ("rotate", 1):
            return rest[0] == "cw" ? .rotateSpace(clockwise: true)
                : rest[0] == "ccw" ? .rotateSpace(clockwise: false) : nil
        case ("apply", 1):
            return rest[0] == "all" ? .applyLayout(all: true)
                : rest[0] == "visible" ? .applyLayout(all: false) : nil
        case ("grid", 6): return parseGrid(rest)
        case ("resize", 2): return parseResize(rest)
        default: return nil
        }
    }

    /// 三個吃方向的動作。抽出來是為了讓 `parseWithArguments` 過
    /// swiftlint 的 `cyclomatic_complexity`（上限 10，不准調參數）。
    private static func parseDirectional(_ head: String, _ argument: String) -> HotkeyAction? {
        guard let direction = Direction(rawValue: argument) else { return nil }
        switch head {
        case "focus": return .focusWindow(direction)
        case "swap": return .swapWindow(direction)
        case "stack": return .stackWindow(direction)
        default: return nil
        }
    }

    private static func parseResize(_ rest: [String]) -> HotkeyAction? {
        guard let width = Int(rest[0]), let height = Int(rest[1]) else { return nil }
        return .resizeWindow(deltaWidth: width, deltaHeight: height)
    }

    private static func parseGrid(_ rest: [String]) -> HotkeyAction? {
        let numbers = rest.compactMap(Int.init)
        guard numbers.count == 6, numbers[0] > 0, numbers[1] > 0 else { return nil }
        return .placeGrid(rows: numbers[0], columns: numbers[1], originX: numbers[2],
                          originY: numbers[3], width: numbers[4], height: numbers[5])
    }
}
