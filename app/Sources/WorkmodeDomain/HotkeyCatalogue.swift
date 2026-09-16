/// 動作的中文名字，以及「選單裡列哪些」。
///
/// 放在 Domain 而不是 UI：`WorkmodeEditorUI` 零測試，而
/// `everyDefaultActionHasAName` 這條要求「使用者的 45 條裡沒有一條在畫面上
/// 顯示成一串生字串」——那個檢查只有在這一層才做得到。
public enum HotkeyCatalogue {
    /// 選單要列的那些，依組。組名同時是選單的分隔標題。
    ///
    /// **不是全部可能的動作**：`space:1…9` 有九個、`grid` 有無限多種組合，
    /// 全列出來的選單沒有人找得到東西。列不到的走那一格的文字輸入
    /// （`HotkeyAction.parse` 的字串形式），而那是這個欄位的規範表示。
    public static let groups: [(title: String, actions: [HotkeyAction])] = [
        ("焦點", [.focusWindow(.west), .focusWindow(.east), .focusWindow(.north),
                .focusWindow(.south), .focusStack(next: true), .focusStack(next: false)]),
        ("位置", [.swapWindow(.west), .swapWindow(.east), .swapWindow(.north),
                .swapWindow(.south), .stackWindow(.west), .stackWindow(.east),
                .toggleFullscreen, .balanceSpace, .rotateSpace(clockwise: true),
                .rotateSpace(clockwise: false), .toggleGaps]),
        ("搬到別處", [.moveToSpace(.next), .moveToSpace(.previous),
                  .moveToDisplay(.next), .moveToDisplay(.previous)]),
        ("tatami", [.applyLayout(all: false), .applyLayout(all: true), .showGrid,
                    .closeWindow]),
    ]

    /// 給人看的名字。表裡沒有的（`space:3`、`grid:2:2:0:0:1:1`、`shell:…`）
    /// 用一個講得出參數的說法，最後才退回原始字串——**退回的那條路不能拿掉**，
    /// 它是「使用者手打了一個我們沒想到的動作」時畫面上唯一看得懂的東西。
    public static func label(for action: HotkeyAction) -> String {
        if let named = names[action] {
            return named
        }
        switch action {
        case let .moveToSpace(target): return "搬到 space \(target.text)"
        case let .moveToDisplay(target): return "搬到螢幕 \(target.text)"
        case let .placeGrid(rows, columns, originX, originY, width, height):
            return "排到 \(columns)×\(rows) 格線的 (\(originX), \(originY)) 起 \(width)×\(height) 格"
        case let .resizeWindow(deltaWidth, deltaHeight):
            return "改變大小 \(signed(deltaWidth)) × \(signed(deltaHeight))"
        case let .runShell(command): return "跑命令：\(command)"
        default: return action.text
        }
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private static let names: [HotkeyAction: String] = [
        .focusWindow(.west): "焦點往左", .focusWindow(.east): "焦點往右",
        .focusWindow(.north): "焦點往上", .focusWindow(.south): "焦點往下",
        .focusStack(next: true): "同位置的下一個視窗",
        .focusStack(next: false): "同位置的上一個視窗",
        .swapWindow(.west): "與左邊對調", .swapWindow(.east): "與右邊對調",
        .swapWindow(.north): "與上面對調", .swapWindow(.south): "與下面對調",
        .stackWindow(.west): "疊到左邊那個上面", .stackWindow(.east): "疊到右邊那個上面",
        .moveToSpace(.next): "搬到下一個 space", .moveToSpace(.previous): "搬到上一個 space",
        .moveToDisplay(.next): "搬到下一台螢幕", .moveToDisplay(.previous): "搬到上一台螢幕",
        .closeWindow: "關閉視窗", .toggleFullscreen: "填滿螢幕／還原",
        .balanceSpace: "均分這個 space", .rotateSpace(clockwise: true): "版面轉 90°",
        .rotateSpace(clockwise: false): "版面轉 270°", .toggleGaps: "切換間隙",
        .applyLayout(all: false): "重排目前可見的 space",
        .applyLayout(all: true): "重排全部有版面的 space",
        .showGrid: "滑鼠格線",
    ]
}
