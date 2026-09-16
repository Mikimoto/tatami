import SwiftUI
import WorkmodeDomain

/// 錄一組快捷鍵：按下按鈕，然後按下你要的組合。
///
/// **用 `NSEvent.addLocalMonitorForEvents` 而不是 SwiftUI 的焦點系統。**
/// `.focusable()` ＋ `@FocusState` ＋ `.onKeyPress` 在這個 app 裡實測完全沒有反應
/// （2026-08-28，畫布的鍵盤刪除踩過同一個坑）：SwiftUI 的焦點賦值沒有讓那個 view
/// 成為 AppKit 的 first responder，而最可能的成因是使用者的系統設定
/// （「鍵盤導覽」預設關閉）。local monitor 不經過 first responder。
///
/// monitor **吃掉**事件（回 nil）：錄製中按 ⌘S 不該順手存檔。
struct HotkeyRecorder: View {
    /// **Optional 是為了 zone**：`HotkeyBinding.hotkey` 是非 optional 的，而沒有
    /// 掛快捷鍵的 zone 是常態。呼叫端傳一個非 optional 的 `Hotkey` 照樣編得過
    /// （Swift 自己升成 Optional），所以「快捷鍵」那一頁一個字都不用改，
    /// 而且它永遠拿不到 nil——那一列的顯示逐位元組沒變。
    let hotkey: Hotkey?
    /// 這一組與別人撞了。撞了的那條後面那個會安靜地不生效，所以要看得出來。
    let isConflicting: Bool
    let onRecorded: (Hotkey) -> Void

    @State private var monitor: Any?
    /// 錄到一組不能用的（沒有修飾鍵）要講一次，不能安靜地不收。
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            button
            // **拒絕要看得見。** 2026-09-09 人工驗抓到：這句話原本只寫進
            // `.help()`（要把游標停在上面才看得到），而 `colour` 先問
            // `monitor != nil`，所以標籤停在錄製中的藍色——「按了沒反應」
            // 與「這個鍵不能用」在畫面上完全分不出來。
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private var button: some View {
        Button {
            monitor == nil ? start() : stop()
        } label: {
            Text(monitor == nil
                ? (hotkey?.description ?? "未設定") : "按下組合鍵…（Esc 取消）")
                .monospaced()
                .foregroundStyle(colour)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .help(isConflicting ? "這組鍵綁了兩次，只有第一條會生效" : "")
    }

    private var colour: Color {
        // **`refusal` 問在 `monitor` 之前。** 反過來的話錄製中的藍色會蓋掉橘色，
        // 而拒絕之後刻意**不** `stop()`（讓人直接再按一次），所以那正是它出現的時機。
        if refusal != nil {
            return .orange
        }
        if monitor != nil {
            return .accentColor
        }
        if isConflicting {
            return .red
        }
        // 「未設定」要看得出來不是一組真的鍵——同一個灰階與其他頁的 placeholder 一致。
        return hotkey == nil ? .secondary : .primary
    }

    private func start() {
        refusal = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // 吃掉：錄製中按 ⌘S 不該順手存檔。
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Esc 取消。用 keyCode 而不是字元：那個鍵在任何佈局上都是 53。
        guard event.keyCode != 53 else { stop(); return }
        let recorded = Hotkey(key: HotkeyKeys.name(for: UInt32(event.keyCode)),
                              modifiers: Self.modifiers(of: event))
        // **判準在 Domain**（`isSafeAsGlobalShortcut`）：這一層零測試。
        guard recorded.isSafeAsGlobalShortcut else {
            refusal = "至少要按住 ⌘、⌃ 或 ⌥ 其中一個——沒有修飾鍵的話，"
                + "這個鍵在每個 app 裡都會被吃掉。"
            return
        }
        refusal = nil
        stop()
        onRecorded(recorded)
    }

    /// `NSEvent` 的旗標轉成 Domain 的集合。這四行是這一層唯一碰得到的轉換
    /// （AppKit 的常數搬不進 Domain）。
    private static func modifiers(of event: NSEvent) -> Set<Hotkey.Modifier> {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var out: Set<Hotkey.Modifier> = []
        if flags.contains(.command) {
            out.insert(.cmd)
        }
        if flags.contains(.option) {
            out.insert(.alt)
        }
        if flags.contains(.control) {
            out.insert(.ctrl)
        }
        if flags.contains(.shift) {
            out.insert(.shift)
        }
        return out
    }
}
