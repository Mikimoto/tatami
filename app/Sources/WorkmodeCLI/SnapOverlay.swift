import AppKit
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain

/// ⌥ 拖曳時浮在畫面上的吸附區。
///
/// 面板與那塊填色都在 `HighlightOverlay`，與格線面板的真螢幕預覽**共用**一份。
/// 這條路對「不搶焦點」的要求比格線那邊更嚴：格線是拖完焦點會跑掉，而這裡是
/// 拖曳中途搶焦點會讓那個拖曳本身斷掉。
@MainActor
final class SnapOverlay: SnapPresenter {
    private let source: SnapSource
    private let overlay = HighlightOverlay()

    init(source: SnapSource) {
        self.source = source
    }

    nonisolated func zones(at point: MouseDrag.Point) -> (canvas: Rect, zones: [SnapZone])? {
        // `MouseTap` 的 callback 跑在主執行緒的 run loop 上（CGEvent tap 掛在那裡），
        // 所以 `assumeIsolated` 成立——與 `HotkeyMonitor.fire` 同一條。
        MainActor.assumeIsolated { source.zones(at: point) }
    }

    nonisolated func show(zones _: [SnapZone], canvas: Rect) {
        MainActor.assumeIsolated { overlay.show(canvas: canvas, level: .popUpMenu) }
    }

    nonisolated func highlight(_ zone: SnapZone?) {
        // 畫 `target` 不是 `trigger`：要看的是「放開之後視窗會在哪」，而外圈那些
        // 兩者不同（游標在左上那一塊 → 視窗排到左上四分之一）。
        MainActor.assumeIsolated { overlay.highlight(zone?.target) }
    }

    nonisolated func hide() {
        MainActor.assumeIsolated { overlay.hide() }
    }
}
