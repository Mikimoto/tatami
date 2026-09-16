import AppKit
import WorkmodeDomain

/// 面板的兩個模式。
enum GridPanelMode {
    case dragging
    case wall
}

/// 面板兩個模式共用的外框：底板、抬頭那一列、以及右側切模式的兩顆按鈕。
///
/// **住在這裡而不是各畫一份**：按鈕的矩形是「畫」與「點得到」共用的同一份
/// ——各算一套的症狀是「亮在這一顆、點到另一顆」，而畫面上兩邊都正常
/// （`GridOverlayView` 的 `board` 與 `drawGridLines` 是同一條紀律）。
@MainActor
enum GridPanelChrome {
    /// 抬頭那一列的高度。面板的縮圖區照舊保持畫布比例，抬頭是**加在上面**的
    /// ——把它擠進縮圖裡會讓格線與真螢幕的比例對不上，而那正是這個面板唯一
    /// 不能錯的東西。
    ///
    /// 住在 chrome 而不是 `GridOverlay`：畫抬頭的是這裡，所以它的高度也該在這裡。
    /// 2026-09-09 之前它是 `GridOverlay` 的 `fileprivate`，而第二個模式在另一個檔
    /// ——Swift 的 `private`／`fileprivate` 都跨不過檔案邊界。
    static let headlineHeight: Double = 34

    private static let buttonSize = NSSize(width: 40, height: 20)
    private static let buttonGap: Double = 6
    private static let rightMargin: Double = 10

    /// 三顆按鈕的位置。畫與 hit-test 都問這一支。
    ///
    /// `record` 只在拖曳模式畫得出來也只在那裡點得到——它記的是「當下拖的那一塊」，
    /// 而縮圖牆沒有那個東西。`draw` 與兩個 view 的 hit-test 用同一個條件
    /// （`mode == .dragging`），所以不會出現「畫不出來卻點得到」。
    /// 三顆按鈕的矩形。struct 而不是 tuple——swiftlint 的 `large_tuple` 上限是 2
    /// （`.swiftlint.yml` 檔頭明文禁止調參數）。
    struct Buttons {
        let record: NSRect
        let dragging: NSRect
        let wall: NSRect
    }

    static func buttons(in bounds: NSRect) -> Buttons {
        let top = (headlineHeight - buttonSize.height) / 2
        let wall = NSRect(x: bounds.maxX - rightMargin - buttonSize.width, y: top,
                          width: buttonSize.width, height: buttonSize.height)
        let dragging = NSRect(x: wall.minX - buttonGap - buttonSize.width, y: top,
                              width: buttonSize.width, height: buttonSize.height)
        let record = NSRect(x: dragging.minX - buttonGap * 2 - buttonSize.width, y: top,
                            width: buttonSize.width, height: buttonSize.height)
        return Buttons(record: record, dragging: dragging, wall: wall)
    }

    /// 底板 ＋ 抬頭 ＋ 兩顆按鈕。回傳底板那條路徑，讓呼叫端最後描邊。
    @discardableResult
    static func draw(in bounds: NSRect, headline: String, mode: GridPanelMode,
                     isRecording: Bool = false) -> NSBezierPath
    {
        let plate = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        // 不透明度 0.82 而不是全螢幕版的 0.18：那時後面就是要排的畫面所以要看得穿，
        // 現在面板只佔一小塊、後面是無關的內容，看得穿反而讓格線讀不出來。
        NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
        plate.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = NSAttributedString(string: headline, attributes: attributes)
        // 垂直置中在抬頭那一列裡。這兩個 view 的 `isFlipped` 都是 true，y 往下。
        //
        // **抬頭要讓出按鈕那一塊**：不夾寬度的話，長的 app 名會畫到按鈕底下，
        // 而按鈕仍然點得到——畫面上看起來就只是「字糊在一起」。
        let boxes = buttons(in: bounds)
        let limit = (mode == .dragging ? boxes.record.minX : boxes.dragging.minX) - 12 - 8
        text.draw(in: NSRect(x: 12, y: (headlineHeight - text.size().height) / 2,
                             width: max(0, limit), height: text.size().height))

        if mode == .dragging {
            pill(boxes.record, title: "記", isOn: isRecording)
        }
        pill(boxes.dragging, title: "格", isOn: mode == .dragging)
        pill(boxes.wall, title: "庫", isOn: mode == .wall)
        return plate
    }

    private static func pill(_ box: NSRect, title: String, isOn: Bool) {
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        (isOn ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
        path.fill()
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: isOn ? NSColor.white : NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }
}

/// 面板第二個模式：位置庫的縮圖牆。點一格就套用，而**面板留著**。
///
/// 「面板留著」是使用者選這個架構（而不是把圖庫放進編輯器）的唯一理由：
/// 對**同一個視窗**試不同位置——點「左半」看一眼、不滿意再點「整片」。
/// 目標視窗在面板開起來那一刻就定了（`GridTarget` 只讀一次焦點），而
/// 「點面板外面」照舊是取消，所以中途換一個視窗來排是**做不到**的
/// ——那是 2026-09-09 使用者裁決過的取捨，不是漏掉的功能。
///
/// 分成獨立一個檔是因為 `GridOverlay.swift` 已經 286 行，而 `file_length`
/// 的上限是 400（`.swiftlint.yml` 的檔頭明寫不准調參數）。
///
/// **這一層零測試**（與 `GridOverlayView`／`WorkmodeEditorUI` 同一個處境），
/// 所以格子的幾何一律問 Domain：每一格畫的是 `zone.spec` 在一個**單位矩形**裡的
/// 比例，而那個比例由 `WindowGeometry.cell` 算——與放開滑鼠那一刻走的是同一支。
@MainActor
final class GridZoneWall: NSView {
    /// 一列幾個。4 是照 Lasso 的截圖數的。
    private static let perRow = 4
    private static let spacing: Double = 8
    /// 格子再小就讀不出形狀了。撐不下時寧可讓面板擠一點，也不要靜靜地把
    /// 後面幾個切掉——「點不到」與「我沒存過那一個」在畫面上分不出來。
    private static let minimumTile = NSSize(width: 44, height: 32)

    private let zones: [GridZone]
    private let headline: String
    private let place: (WindowGeometry.GridSpec) -> Rect
    private let onPreview: (Rect?) -> Void
    private let onPick: (WindowGeometry.GridSpec) -> Void
    private let onDelete: (GridZone) -> Void
    private let onMode: (GridPanelMode) -> Void
    /// 按下去的那一格。**不是 hover**：這個 target 一個 `NSTrackingArea` 都沒有、
    /// 面板也沒開 `acceptsMouseMovedEvents`，所以 `mouseMoved` 永遠不會被呼叫
    /// ——留一段不會觸發的高亮，與「壞了」在畫面上分不出來。按下／放開這兩個
    /// 事件則是拖曳那個模式本來就靠著活的，確定送得到。
    private var pressed: Int?

    init(zones: [GridZone], headline: String,
         place: @escaping (WindowGeometry.GridSpec) -> Rect,
         onPreview: @escaping (Rect?) -> Void,
         onPick: @escaping (WindowGeometry.GridSpec) -> Void,
         onDelete: @escaping (GridZone) -> Void,
         onMode: @escaping (GridPanelMode) -> Void)
    {
        self.zones = zones
        self.headline = headline
        self.place = place
        self.onPreview = onPreview
        self.onPick = onPick
        self.onDelete = onDelete
        self.onMode = onMode
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("不從 nib 來")
    }

    override var isFlipped: Bool {
        true
    }

    /// 縮圖牆那一塊＝面板扣掉抬頭。
    private var board: NSRect {
        NSRect(x: 0, y: GridPanelChrome.headlineHeight, width: bounds.width,
               height: max(0, bounds.height - GridPanelChrome.headlineHeight))
    }

    /// 每一格的大小**由現有空間算出來**，不是寫死的。寫死的話 zone 一多就有幾個
    /// 落在面板外面——而畫面上那看起來只是「我少存了一個」。
    private var tile: NSSize {
        let columns = Double(Self.perRow)
        let rows = Double(max(1, (zones.count + Self.perRow - 1) / Self.perRow))
        let width = (board.width - Self.spacing * (columns + 1)) / columns
        let height = (board.height - Self.spacing * (rows + 1)) / rows
        return NSSize(width: max(Self.minimumTile.width, width),
                      height: max(Self.minimumTile.height, height))
    }

    private func tileFrame(_ index: Int) -> NSRect {
        let size = tile
        let column = Double(index % Self.perRow)
        let row = Double(index / Self.perRow)
        return NSRect(x: Self.spacing + column * (size.width + Self.spacing),
                      y: board.minY + Self.spacing + row * (size.height + Self.spacing),
                      width: size.width, height: size.height)
    }

    private func index(at point: NSPoint) -> Int? {
        zones.indices.first { tileFrame($0).contains(point) }
    }

    /// 每一格右上那個 `×`。**畫與 hit-test 同一支**，理由與 chrome 的按鈕逐字相同。
    private func deleteBox(_ index: Int) -> NSRect {
        let box = tileFrame(index)
        let side: Double = 14
        return NSRect(x: box.maxX - side - 2, y: box.minY + 2, width: side, height: side)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mode = modeButton(at: point) {
            onMode(mode)
            return
        }
        // 刪除要**先**問：它疊在格子上面，不先問就會變成「按 × 卻套用了那個位置」。
        if let hit = zones.indices.first(where: { deleteBox($0).contains(point) }) {
            onDelete(zones[hit])
            return
        }
        pressed = index(at: point)
        needsDisplay = true
        // 按住就在**真螢幕**上亮出那一塊，與拖曳模式同一個閉包——放開之前先看到
        // 「它會去哪」，那正是這個面板存在的理由。
        onPreview(pressed.map { place(zones[$0].spec) })
    }

    override func mouseUp(with event: NSEvent) {
        let landed = index(at: convert(event.locationInWindow, from: nil))
        let picked = pressed
        pressed = nil
        needsDisplay = true
        // 按下與放開要在同一格才算數（拖曳模式的「按下就放開＝誤觸」是同一條精神）。
        guard let picked, picked == landed else {
            onPreview(nil)
            return
        }
        onPick(zones[picked].spec)
    }

    private func modeButton(at point: NSPoint) -> GridPanelMode? {
        // `record` 不在這裡：它只在拖曳模式畫得出來（見 `GridPanelChrome.buttons`）。
        let boxes = GridPanelChrome.buttons(in: bounds)
        if boxes.dragging.contains(point) {
            return .dragging
        }
        if boxes.wall.contains(point) {
            return .wall
        }
        return nil
    }

    override func draw(_: NSRect) {
        let plate = GridPanelChrome.draw(in: bounds, headline: headline, mode: .wall)
        if zones.isEmpty {
            let text = NSAttributedString(
                // 這句話**只講今天做得到的事**：切到「格」、拖一塊、按「記」。
                // （寫下它的時候「記」那顆按鈕還不存在，所以原本只講到拖；
                // 它在同一個 branch 的下一顆 commit 就有了，這裡跟著補上。）
                string: "還沒有存過位置。切到「格」拖一塊，按「記」再拖就存起來。",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor]
            )
            text.draw(at: NSPoint(x: 12, y: board.minY + 12))
        } else {
            for (index, zone) in zones.enumerated() {
                draw(zone, in: tileFrame(index), isPressed: index == pressed, index: index)
            }
        }
        NSColor.separatorColor.setStroke()
        plate.lineWidth = 1
        plate.stroke()
    }

    /// 右上角那個 `×`。位置由 `deleteBox` 給——這裡自己再算一次的話，
    /// 症狀是「畫在這裡、點那裡才刪得掉」。
    private func drawDeleteMark(_ index: Int) {
        let mark = deleteBox(index)
        NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: mark).fill()
        let text = NSAttributedString(string: "×", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: mark.midX - size.width / 2, y: mark.midY - size.height / 2))
    }

    private func draw(_ zone: GridZone, in box: NSRect, isPressed: Bool, index: Int) {
        let plate = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        plate.fill()
        // **形狀問 Domain。** 一個單位矩形當畫布，算出來的就是這一格裡的比例
        // ——這一層不做格線的算術（`GridOverlayView` 逐字同一條紀律）。
        let unit = WindowGeometry.cell(zone.spec,
                                       canvas: Rect(originX: 0, originY: 0,
                                                    width: 1, height: 1))
        let shape = NSRect(x: box.minX + unit.originX * box.width,
                           y: box.minY + unit.originY * box.height,
                           width: unit.width * box.width, height: unit.height * box.height)
        NSColor.controlAccentColor.withAlphaComponent(isPressed ? 0.75 : 0.45).setFill()
        NSBezierPath(rect: shape).fill()
        if isPressed {
            NSColor.controlAccentColor.setStroke()
            plate.lineWidth = 2
            plate.stroke()
        }
        drawDeleteMark(index)
        let label = NSAttributedString(
            string: zone.hotkey.map { "\(zone.name) \($0.description)" } ?? zone.name,
            attributes: [.font: NSFont.systemFont(ofSize: 9),
                         .foregroundColor: NSColor.labelColor]
        )
        // 夾在格子裡：名字是使用者打的，長度沒有上限。
        label.draw(in: NSRect(x: box.minX + 3, y: box.maxY - 13,
                              width: box.width - 6, height: 11))
    }
}

/// 兩個模式的切換。
///
/// **換的是 `contentView`，不是開第二個面板**：兩個面板會讓「點外面取消」那個
/// global monitor 要比對兩個 frame，而它現在只認一個（`GridOverlay.watchForCancel`）。
///
/// 存在檔案層級的變數而不是區域變數——與 `MenuCommand` 的 `menuController`
/// 同一條：區域變數在 `application.run()` 之前就出了作用域。
@MainActor
final class GridModeController {
    private let panel: NSPanel
    private let dragging: NSView
    private var wall: NSView

    init(panel: NSPanel, dragging: NSView, wall: NSView) {
        self.panel = panel
        self.dragging = dragging
        self.wall = wall
        show(.dragging)
    }

    func show(_ mode: GridPanelMode) {
        let view = mode == .dragging ? dragging : wall
        panel.contentView = view
        view.needsDisplay = true
    }

    /// 記了或刪了一個 zone 之後換一面新的牆。
    ///
    /// **不是叫舊的重畫**：`GridZoneWall` 的 zones 是 `let`（它是一份快照，
    /// 而面板可能開著好幾秒、檔案同時被編輯器寫），換一個新的比較誠實。
    /// 不換的症狀是「我按了記下來卻沒出現」，而檔案裡其實已經有了。
    func replaceWall(_ view: NSView) {
        let wasShowing = panel.contentView === wall
        wall = view
        if wasShowing {
            show(.wall)
        }
    }
}
