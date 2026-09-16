import AppKit
import WorkmodeDomain

/// 一塊「蓋在畫布上、填一個矩形、忽略滑鼠」的面板。
///
/// 兩個消費端：⌥ 拖曳的吸附區（`SnapOverlay`）與格線面板的真螢幕預覽。
/// **抽出來而不是抄一份**：兩邊都要把 CG 的畫布換成 NS 的 frame，而
/// `nsRect(fromCG:)` 的註解已經明寫「這個換算全 repo 只該有一份」——
/// 而抄第二份的症狀是「蓋在別的螢幕上」或「上下顛倒」。
///
/// 面板的形狀照 `GridOverlay`：`.borderless` ＋ `.nonactivatingPanel`、
/// `orderFrontRegardless()`、不 `activate`。**`ignoresMouseEvents = true`**
/// 是這個型別存在的第二個理由：它蓋在整個畫布上，不忽略滑鼠的話會把正在
/// 進行的拖曳吃掉（`MouseTap` 就收不到 `mouseDragged`，而格線面板收不到 `mouseUp`）。
@MainActor
final class HighlightOverlay {
    private var panel: NSPanel?
    private var view: HighlightOverlayView?

    /// - Parameter level: 疊放層級。格線那條路要**低於**格線面板，否則面板自己
    ///   （置中在畫布上）會遮掉一塊預覽，而那塊剛好是使用者最想看的中間。
    func show(canvas: Rect, level: NSWindow.Level) {
        guard panel == nil else { return }
        let frame = nsRect(fromCG: canvas)
        let overlay = HighlightOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        overlay.canvas = canvas
        let created = NSPanel(contentRect: frame,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        created.isOpaque = false
        created.backgroundColor = NSColor.clear
        created.hasShadow = false
        created.level = level
        created.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        created.ignoresMouseEvents = true
        created.contentView = overlay
        created.orderFrontRegardless()
        panel = created
        view = overlay
    }

    /// nil ＝什麼都不畫（游標離開任何一區，或還沒開始拖）。
    func highlight(_ rect: Rect?) {
        view?.target = rect
        view?.needsDisplay = true
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }
}

/// 畫一個填色的矩形。
private final class HighlightOverlayView: NSView {
    var canvas = Rect(originX: 0, originY: 0, width: 0, height: 0)
    var target: Rect?

    override var isFlipped: Bool {
        true
    }

    override func draw(_: NSRect) {
        guard let target else { return }
        let box = local(target)
        NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        border.lineWidth = 2
        border.stroke()
    }

    /// 畫布座標（CG）→ view 座標。這個 view 蓋的就是畫布，而它 `isFlipped`，
    /// 所以只有平移沒有翻轉（`GridOverlayView` 逐字同一條）。
    private func local(_ rect: Rect) -> NSRect {
        NSRect(x: rect.originX - canvas.originX, y: rect.originY - canvas.originY,
               width: rect.width, height: rect.height)
    }
}
