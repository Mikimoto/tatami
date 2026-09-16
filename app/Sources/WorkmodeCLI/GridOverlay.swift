import AppKit
import WorkmodeDomain

/// `GridOverlay.present` 要收的東西。
///
/// 包成一個型別而不是七個參數：swiftlint 的 `function_parameter_count` 是 5
/// （`.swiftlint.yml` 的檔頭明文禁止調參數），先例是 `SpaceTargets.swift` 的 `RoleSite`。
struct GridPanelRequest {
    let grid: GridSelection
    /// 目標螢幕的 **NS** frame。面板置中在它上面，不是跟著滑鼠：跟著滑鼠更像
    /// Lasso，但要處理「靠邊時面板會超出螢幕」的夾邊，而置中永遠整塊看得見。
    /// 滑鼠當下在哪台螢幕不影響——要排的是**焦點視窗**那一台。
    let display: NSRect
    let headline: String
    let zones: [GridZone]
    /// 選取換算成畫布上的矩形（間距就是在那裡套的）。面板自己不做這一步：
    /// 它連一次除法都不做，而預覽、拖曳套用與縮圖牆共用這一支正是
    /// 「亮起來的那一塊就是會被套上去的那一塊」的保證。
    let place: (WindowGeometry.GridSpec) -> Rect
    /// 拖曳模式放開滑鼠。**不回來**——那條路打完就結束，是現況也是使用者滿意的。
    let apply: (WindowGeometry.GridSpec) -> Never
    /// 縮圖牆點一格。**會回來**——面板留著，讓同一個視窗再試下一個位置。
    let pick: (WindowGeometry.GridSpec) -> Void
    /// 「記」開著時放開滑鼠：把那一塊存進位置庫而不是套用。回的是寫完之後
    /// **重讀**的那份 zones——面板自己不維護一份，見 `makeWall`。
    let record: (WindowGeometry.GridSpec) -> [GridZone]
    /// 縮圖牆的 `×`。同樣回重讀之後的 zones。
    let delete: (GridZone) -> [GridZone]
}

/// 兩個模式的切換器。**檔案層級而不是區域變數**：`present` 建的兩個 view 各自
/// 抓著一個 `onMode` 閉包要用它，而區域變數在 `application.run()` 之前就出了
/// 作用域（`MenuCommand` 的 `menuController` 是同一條）。
@MainActor
private var gridModeController: GridModeController?

/// 一小塊懸浮的**縮圖**面板（Lasso 那樣），在上面拖一個矩形。
///
/// 2026-09-07 之前這裡是「一層透明的東西蓋住整個螢幕」，而那個形狀有兩個問題：
/// 整片畫面被遮住時看不到自己正在排的視窗長什麼樣，而且手要橫跨整個螢幕。
/// 縮圖版把同一件事縮成一塊 380pt 寬的面板——手的行程短，畫面也還看得見。
///
/// AppKit 而不是 SwiftUI：這裡要的是「一個無邊框視窗、自己畫、自己收
/// mouseDown/Dragged/Up」，那是 `NSView` 的原生形狀。編輯器那邊用 SwiftUI 是因為
/// 它是一堆表單與清單。
///
/// **這一層沒有測試跑得到**，與 `WorkmodeEditorUI` 和 fzf 那條路同一個處境，所以
/// 幾何一律問 `GridSelection`（Domain，有測試）：面板只把自己的點除成 0…1 的比例
/// （`CanvasView` 對 `DropZone` 是同一個分工），一次都不碰螢幕座標。
@MainActor
enum GridOverlay {
    /// 面板最長邊的點數。380 是折衷：再小格子就瞄不準（6 欄時一格 63pt），
    /// 再大就開始遮住要排的東西——縮圖版存在的理由就是不要遮。
    private static let maximumSide: Double = 380

    /// 開面板、跑 run loop。拖曳那個模式放開滑鼠時呼叫 `apply`（那支不回來，
    /// 它 `exit`）；縮圖牆那個模式點一格呼叫 `pick`，**那支會回來**——面板留著。
    static func present(_ request: GridPanelRequest) {
        let grid = request.grid
        let application = NSApplication.shared
        // **`.accessory` 加 `.nonactivatingPanel`，而且不 `activate`。**
        //
        // 2026-09-07 的第一版是 `.regular` ＋ `activate(ignoringOtherApps:)`，理由是
        // Esc 要走 key window。代價是使用者立刻感覺到的：面板一出現焦點就跑到
        // tatami 身上，套用完 tatami 結束，焦點回到系統挑的下一個視窗——**不是剛排好
        // 那一個**。所以現在反過來：完全不搶焦點，Esc 與「點外面」改用 global monitor。
        //
        // 那兩個 monitor 需要「輔助使用」權限——而這條路本來就需要（AX 設 frame），
        // 所以不是新的相依。
        application.setActivationPolicy(.accessory)

        // 預覽要在格線面板**之下**：面板置中在畫布上，同一個 level 的話它會遮掉
        // 中間那一塊，而那正是使用者最想看的地方。
        let highlighter = HighlightOverlay()
        highlighter.show(canvas: grid.canvas, level: .floating)

        let panel = NSPanel(contentRect: frame(for: grid.canvas, on: request.display),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // `.popUpMenu` 蓋得過一般視窗與浮動視窗，而不像 `.screenSaver` 那樣蓋過系統
        // 的警告框——排版工具不該擋住一個要使用者回答的問題。
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // 兩個模式共用同一個面板，換的是 `contentView`（理由見 `GridModeController`）。
        // controller 存在檔案層級的變數裡：兩個 view 的 `onMode` 閉包要抓得到它，
        // 而它自己也必須活過 `application.run()`。
        let dragging = GridOverlayView(grid: grid, headline: request.headline,
                                       place: request.place,
                                       onPreview: { highlighter.highlight($0) },
                                       apply: request.apply,
                                       onMode: { gridModeController?.show($0) },
                                       onRecord: { spec in
                                           // 記完直接切到縮圖牆——那一格立刻看得見，
                                           // 而「按了沒反應」正是這個功能最難查的失效。
                                           let fresh = request.record(spec)
                                           gridModeController?
                                               .replaceWall(makeWall(fresh, request, highlighter))
                                           gridModeController?.show(.wall)
                                       })
        gridModeController = GridModeController(
            panel: panel, dragging: dragging,
            wall: makeWall(request.zones, request, highlighter)
        )
        // `orderFrontRegardless` 而不是 `makeKeyAndOrderFront`：後者對一個沒有被啟動
        // 的 app 不保證做得到，而我們也不需要 key——鍵盤走 monitor。
        panel.orderFrontRegardless()

        watchForCancel(outside: panel)
        application.run()
    }

    /// 縮圖牆。`record`／`delete` 之後要換一面新的，所以建它的地方只能有一處
    /// ——抄第二份的症狀是「刪掉之後那一格又回來了」（新的那面少接了一個 callback）。
    private static func makeWall(_ zones: [GridZone], _ request: GridPanelRequest,
                                 _ highlighter: HighlightOverlay) -> GridZoneWall
    {
        GridZoneWall(zones: zones, headline: request.headline, place: request.place,
                     onPreview: { highlighter.highlight($0) },
                     onPick: request.pick,
                     onDelete: { zone in
                         let fresh = request.delete(zone)
                         gridModeController?.replaceWall(makeWall(fresh, request, highlighter))
                     },
                     onMode: { gridModeController?.show($0) })
    }

    /// Esc 與「點到面板外面」都是取消。
    ///
    /// **global monitor 而不是 `keyDown`／`didResignActive`**：這個行程不被啟動，
    /// 所以它既拿不到 key 事件、也永遠不會 resign active。global monitor 是唯一
    /// 看得到那兩件事的東西，而它要的正是我們已經有的 AX 權限。
    ///
    /// monitor 只讀不吃：Esc 照樣送給前景那個 app（多數 app 對它是 no-op），
    /// 而點擊照樣讓那個視窗做它該做的事——「點外面」同時取消面板與完成那個點擊，
    /// 這正是預期的行為。
    private static func watchForCancel(outside panel: NSPanel) {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // 53 是 Esc。用 keyCode 而不是字元：Esc 沒有可印的字元。
            if event.keyCode == 53 {
                exit(0)
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            // 面板**裡面**的按下也會送到這裡（global 就是全部），所以要自己排除，
            // 不然一按下去就取消、整個手勢做不出來。`NSEvent.mouseLocation` 與
            // `panel.frame` 都是 NS 螢幕座標，直接比。
            if !panel.frame.contains(NSEvent.mouseLocation) {
                exit(0)
            }
        }
    }

    /// 面板自己的 NS frame：保持畫布的長寬比，最長邊 `maximumSide`，置中在目標螢幕。
    private static func frame(for canvas: Rect, on display: NSRect) -> NSRect {
        let scale = maximumSide / max(canvas.width, canvas.height, 1)
        let width = max(1, canvas.width * scale)
        let height = max(1, canvas.height * scale) + GridPanelChrome.headlineHeight
        return NSRect(x: display.midX - width / 2, y: display.midY - height / 2,
                      width: width, height: height)
    }
}

/// 畫格線、收拖曳。
///
/// `isFlipped` 是 true，所以 view 的 y 往下——與 `Rect`／CG 同向，於是「view 的點
/// 除以自己的寬高」直接就是畫布上的比例，不必翻轉。
@MainActor
private final class GridOverlayView: NSView {
    private let grid: GridSelection
    private let headline: String
    private let place: (WindowGeometry.GridSpec) -> Rect
    private let onPreview: (Rect?) -> Void
    private let apply: (WindowGeometry.GridSpec) -> Never
    private let onMode: (GridPanelMode) -> Void
    private let onRecord: (WindowGeometry.GridSpec) -> Void
    /// 「記」開著時，放開滑鼠是**存起來**而不是套用。
    ///
    /// 做成一個先按的開關而不是「拖完再按記下來」：拖曳那條路放開滑鼠就套用並
    /// 結束（那是現況，使用者滿意），所以「拖完之後、面板還開著」那個狀態
    /// 根本不存在——沒有東西可以在那時候被按下去記起來。
    private var isRecording = false
    private var anchor: GridSelection.Cell?
    private var current: GridSelection.Cell?

    init(grid: GridSelection, headline: String,
         place: @escaping (WindowGeometry.GridSpec) -> Rect,
         onPreview: @escaping (Rect?) -> Void,
         apply: @escaping (WindowGeometry.GridSpec) -> Never,
         onMode: @escaping (GridPanelMode) -> Void,
         onRecord: @escaping (WindowGeometry.GridSpec) -> Void)
    {
        self.grid = grid
        self.headline = headline
        self.place = place
        self.onPreview = onPreview
        self.apply = apply
        self.onMode = onMode
        self.onRecord = onRecord
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("不從 nib 來")
    }

    override var isFlipped: Bool {
        true
    }

    /// Esc 走 global monitor（見 `GridOverlay.watchForCancel`），所以這個 view 不必是
    /// first responder，也不必實作 `keyDown`——那條路在一個沒被啟動的 app 上不會觸發。
    override var acceptsFirstResponder: Bool {
        false
    }

    /// 縮圖區＝面板扣掉抬頭那一列。格線、選取、以及「view 的點 → 比例」
    /// 三處全部用它，不用 `bounds`——用 `bounds` 的症狀是「亮在這一格、
    /// 視窗排到隔壁」，而畫面上兩邊都正常。
    private var board: NSRect {
        NSRect(x: 0, y: GridPanelChrome.headlineHeight, width: bounds.width,
               height: max(0, bounds.height - GridPanelChrome.headlineHeight))
    }

    /// view 的點 → 0…1 的比例。零寬的 view 收斂成 0（不除以零）。
    private func cell(at point: NSPoint) -> GridSelection.Cell {
        let local = NSPoint(x: point.x, y: point.y - board.minY)
        return grid.cell(atFraction: board.width > 0 ? local.x / board.width : 0,
                         board.height > 0 ? local.y / board.height : 0)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // 切模式的按鈕要**先**問。不先問的話那一下會被當成從第 0 列開始的拖曳，
        // 而同一點放開又剛好是「按下就放開」＝ 取消——按一下切模式，面板就沒了。
        let boxes = GridPanelChrome.buttons(in: bounds)
        if boxes.record.contains(point) {
            isRecording.toggle()
            needsDisplay = true
            return
        }
        if boxes.dragging.contains(point) {
            onMode(.dragging); return
        }
        if boxes.wall.contains(point) {
            onMode(.wall); return
        }
        anchor = cell(at: point)
        current = anchor
        needsDisplay = true
        onPreview(selection())
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        current = cell(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        onPreview(selection())
    }

    /// 兩格之間的選取，用 `WindowGeometry.GridSpec` 表示。
    ///
    /// 交出 spec 而不是矩形，是因為間距要由 `GapInset.cell` 套——它要知道
    /// 「幾格裡的哪幾格」才算得出畫布與格子各縮一半。**這一支只有一份**，
    /// 預覽與放開滑鼠都走它：兩處各建一次 spec 的話，那六個欄位就是會漂的兩份。
    private func spec(from first: GridSelection.Cell,
                      to second: GridSelection.Cell) -> WindowGeometry.GridSpec
    {
        WindowGeometry.GridSpec(
            rows: grid.rows, columns: grid.columns,
            originX: min(first.column, second.column), originY: min(first.row, second.row),
            width: abs(second.column - first.column) + 1,
            height: abs(second.row - first.row) + 1
        )
    }

    /// 現在選到的那一塊，畫布座標。**面板自己不算**——那是這一層的既有紀律
    /// （`GridOverlayView` 連一次除法都不做），而走 `place` 讓預覽與最後套上去的
    /// 是同一個矩形，含間距。
    private func selection() -> Rect? {
        guard let anchor, let current else { return nil }
        return place(spec(from: anchor, to: current))
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor else { exit(0) }
        let last = cell(at: convert(event.locationInWindow, from: nil))
        // 按下就放開（同一格）＝ 誤觸，取消。要「整格」的話拖過那一格再放開。
        guard last != anchor else { exit(0) }
        guard isRecording else { apply(spec(from: anchor, to: last)) }
        // 記完把開關關掉：不關的話下一次拖曳又是記錄，而畫面上只有一顆小按鈕的
        // 顏色在說這件事。選取也清掉——它已經被存走了。
        isRecording = false
        self.anchor = nil
        current = nil
        onPreview(nil)
        onRecord(spec(from: anchor, to: last))
    }

    override func draw(_: NSRect) {
        let plate = GridPanelChrome.draw(in: bounds, headline: headline, mode: .dragging,
                                         isRecording: isRecording)
        drawGridLines()
        drawSelection()
        NSColor.separatorColor.setStroke()
        plate.lineWidth = 1
        plate.stroke()
    }

    /// 格線畫在面板的等分處。**這裡的等分與 `GridSelection` 的邊界是同一個算式**
    /// （`extent * i / n`），所以畫出來的線與實際落點對得起來——各寫一套的話症狀是
    /// 「亮在這一格、視窗排到隔壁」，而畫面上兩邊都正常。
    private func drawGridLines() {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for column in 1 ..< max(grid.columns, 1) {
            let position = board.width * Double(column) / Double(grid.columns)
            path.move(to: NSPoint(x: position, y: board.minY))
            path.line(to: NSPoint(x: position, y: board.maxY))
        }
        for row in 1 ..< max(grid.rows, 1) {
            let position = board.minY + board.height * Double(row) / Double(grid.rows)
            path.move(to: NSPoint(x: 0, y: position))
            path.line(to: NSPoint(x: board.width, y: position))
        }
        path.stroke()
    }

    private func drawSelection() {
        guard let anchor, let current else { return }
        let left = Double(min(anchor.column, current.column))
        let right = Double(max(anchor.column, current.column) + 1)
        let top = Double(min(anchor.row, current.row))
        let bottom = Double(max(anchor.row, current.row) + 1)
        let local = NSRect(
            x: board.width * left / Double(grid.columns),
            y: board.minY + board.height * top / Double(grid.rows),
            width: board.width * (right - left) / Double(grid.columns),
            height: board.height * (bottom - top) / Double(grid.rows)
        )
        NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
        local.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: local)
        border.lineWidth = 2
        border.stroke()
    }
}
