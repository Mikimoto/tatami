import CoreGraphics
import Foundation
import WorkmodeDomain

/// fn ＋ 拖曳搬視窗、fn ＋ 右鍵拖曳縮放。取代 yabai 最後一個還在做的工作。
///
/// **必須是 CGEvent tap，不能是 `NSEvent.addGlobalMonitorForEvents`。**
/// global monitor 只能看、吃不掉事件（`GridOverlay` 那條路記過同一件事），
/// 所以 fn ＋ 拖曳會**同時**搬視窗與被游標下那個 app 當成一次普通拖曳
/// ——在 Safari 裡就是一路選取文字。tap 回 nil 才吃得掉。
///
/// tap 要的是「輔助使用」授權（與這個 app 其餘部分同一份），不是「輸入監控」。
/// 建不起來就回 nil，呼叫端說一句話然後其餘功能照常——**不 fatalError**：
/// 拖曳壞掉不該讓選單列與 45 個快捷鍵一起消失。
public final class MouseTap {
    private let settings: MouseSettings
    private let engine: WindowServerClient
    private let snap: (any SnapPresenter)?
    private var tap: CFMachPort?
    private var drag: MouseDrag?
    /// 這一次拖曳的吸附區。**在按下的那一刻算一次**，不是每個移動事件算一次
    /// ——那要讀並解析 `layout.json`。
    private var zones: [SnapZone] = []
    private var highlighted: SnapZone?

    /// `snap` 是 nil ＝不顯示吸附區，拖到哪就放到哪（2026-09-08 之前的行為）。
    public init(settings: MouseSettings, engine: WindowServerClient,
                snap: (any SnapPresenter)? = nil)
    {
        self.settings = settings
        self.engine = engine
        self.snap = snap
    }

    /// 裝上去。回 false ＝ `tapCreate` 被拒（沒有授權），或兩顆都關掉。
    @discardableResult
    public func install() -> Bool {
        guard !settings.isDisabled else { return false }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                    .rightMouseDown, .rightMouseDragged, .rightMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// 一個事件。回 nil ＝吃掉它。
    ///
    /// **只有「按下的那一刻修飾鍵就按著」才開始拖**：拖到一半才按 fn 不該把一次
    /// 普通的文字選取變成搬視窗。而一旦開始，中途放掉修飾鍵**照樣繼續**——
    /// 手指先離開 fn 再放開滑鼠是很自然的動作，那時中斷會讓視窗停在半路。
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            return begin(type == .leftMouseDown ? settings.button1 : settings.button2, event)
        case .leftMouseDragged, .rightMouseDragged:
            guard let drag else { return event }
            try? engine.place(window: drag.window, drag.frame(at: point(of: event)))
            // 視窗照樣跟著滑鼠，另外把游標所在那一區標起來——只標不吸，
            // 吸是放開那一刻的事。
            if drag.action == .move {
                let found = SnapZones.zone(at: point(of: event), in: zones)
                if found != highlighted {
                    highlighted = found
                    snap?.highlight(found)
                }
            }
            return nil
        case .leftMouseUp, .rightMouseUp:
            guard let drag else { return event }
            // **放開的那一刻要再設一次。** 拖曳事件會掉——系統對太慢的 tap 會發
            // `tapDisabledByTimeout`，而那一格就沒了。因為位移是從按下當時算的
            // （不是逐格疊加），掉幾格中途看不出來，但**最後一格掉了視窗就停在
            // 前一格**。實測（2026-09-08）：合成一次 +80 的六格拖曳，少了這一行
            // 得到 +65（≈ 五格），補上之後 +80 逐點精確。
            //
            // **有吸附區就用它的 target 蓋過自由位置。** 縮放不吸附——那個手勢的
            // 意思是「我要這個大小」，吸到一格等於把它整個取消掉。
            let landing = drag.action == .move
                ? SnapZones.zone(at: point(of: event), in: zones)?.target
                : nil
            try? engine.place(window: drag.window,
                              landing ?? drag.frame(at: point(of: event)))
            finish()
            return nil
        default:
            return event
        }
    }

    private func begin(_ action: MouseDrag.Action?, _ event: CGEvent) -> CGEvent? {
        guard let action, held(settings.modifier, event),
              let target = engine.window(at: point(of: event))
        else { return event }
        drag = MouseDrag(window: target.id, origin: point(of: event),
                         frame: target.frame, action: action)
        if action == .move, let snap, let found = snap.zones(at: point(of: event)) {
            zones = found.zones
            snap.show(zones: found.zones, canvas: found.canvas)
        }
        return nil
    }

    private func finish() {
        drag = nil
        zones = []
        highlighted = nil
        snap?.hide()
    }

    /// 修飾鍵按著沒有。
    ///
    /// **兩個來源都問，因為滑鼠事件不一定帶得到 fn。** 實測（2026-09-08，本機）：
    /// 真的按住 fn 再按下滑鼠，`event.flags` 是 **0x0**——連 `maskNonCoalesced`
    /// 都沒有；而我們自己合成的事件（`event.flags = .maskSecondaryFn`）當然帶得到。
    /// 那個差別就是「合成測試全過而手按完全沒反應」的成因，也是為什麼那次
    /// 合成實測**證明不了這個功能可用**。
    ///
    /// `CGEventSource.flagsState` 問的是**當下的硬體修飾鍵狀態**，與事件本身帶什麼
    /// 無關。事件自己的旗標仍然先問——合成事件走那條，而它是唯一能自動化的路徑。
    private func held(_ modifier: MouseSettings.Modifier, _ event: CGEvent) -> Bool {
        let want = Self.flag(modifier)
        return event.flags.contains(want) || Self.sessionFlags().contains(want)
    }

    private static func sessionFlags() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    private func point(of event: CGEvent) -> MouseDrag.Point {
        MouseDrag.Point(posX: event.location.x, posY: event.location.y)
    }

    /// `fn` 在這裡收得到，而 `RegisterEventHotKey` 收不到——那是快捷鍵那半
    /// 把它排除在 `Hotkey.Modifier` 外的原因，不是這條路的限制。
    private static func flag(_ modifier: MouseSettings.Modifier) -> CGEventFlags {
        switch modifier {
        case .function: .maskSecondaryFn
        case .cmd: .maskCommand
        case .alt: .maskAlternate
        case .ctrl: .maskControl
        case .shift: .maskShift
        }
    }
}

/// C 函式指標，所以捕捉不了任何東西——`MouseTap` 從 `userInfo` 拿回來。
private let mouseTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MouseTap>.fromOpaque(userInfo).takeUnretainedValue()
    // 系統會在 tap 太慢時把它停掉（`tapDisabledByTimeout`）。不重新啟用的話
    // 拖曳從此無聲失效，而那與「這台機器不支援」外觀相同。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return nil
    }
    guard let result = tap.handle(type, event) else { return nil }
    return Unmanaged.passUnretained(result)
}

private extension MouseTap {
    func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
