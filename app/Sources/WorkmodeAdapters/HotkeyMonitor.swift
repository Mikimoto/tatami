import Carbon.HIToolbox
import Foundation
import WorkmodeDomain

/// 用 Carbon 的 `RegisterEventHotKey` 註冊全域快捷鍵。
///
/// **為什麼不是 `NSEvent.addGlobalMonitorForEvents`**（`grid` 那條路用的那個）：
/// global monitor 只能**看**，吃不掉事件——按 `ctrl+alt+cmd-w` 會同時觸發我們的
/// 動作與前景 app 自己對那個組合的處理。`RegisterEventHotKey` 是系統層的註冊，
/// 事件不會再往下傳。
///
/// **也不是 `CGEvent.tapCreate`**：那要「輸入監控」權限（與「輔助使用」是兩份
/// 不同的授權），而且一個壞掉的 event tap 會讓整台機器的鍵盤卡住。
///
/// 這個型別只在 `Tatami.app`（選單列那個常駐行程）裡活著——快捷鍵要有人一直
/// 在跑才收得到，這是它與 skhd 最實際的差別。
@MainActor
public final class HotkeyMonitor {
    /// Carbon 的 hotkey id 只有 32 bit 的 signature 加 32 bit 的 id。signature 用
    /// 四個字元組成的 OSType 是這個 API 的慣例（`'ttmi'` ＝ tatami）。
    private static let signature: OSType = 0x7474_6D69

    private var registered: [UInt32: (ref: EventHotKeyRef, action: HotkeyAction)] = [:]
    private var handler: EventHandlerRef?
    private var perform: ((HotkeyAction) -> Void)?

    public init() {}

    /// 註冊一批綁定。回 (成功幾組, 被拒幾組)。
    ///
    /// 被拒多半是那個組合已經被系統或別的 app 佔走（`RegisterEventHotKey` 對
    /// 重複的組合回非零）。**不 throw**：一組註冊不到不該讓其餘 45 組也沒有，
    /// 而使用者要的是一句話說明哪些沒生效。
    @discardableResult
    public func register(_ bindings: [HotkeyBinding],
                         perform: @escaping (HotkeyAction) -> Void) -> (count: Int, skipped: Int)
    {
        unregisterAll()
        self.perform = perform
        installHandlerIfNeeded()
        var identifier: UInt32 = 1
        var skipped = 0
        for binding in bindings where binding.isEnabled {
            guard let carbon = binding.hotkey.carbon else { skipped += 1; continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                carbon.code, carbon.mask,
                EventHotKeyID(signature: Self.signature, id: identifier),
                GetEventDispatcherTarget(), 0, &ref
            )
            guard status == noErr, let ref else { skipped += 1; continue }
            registered[identifier] = (ref, binding.action)
            identifier += 1
        }
        return (registered.count, skipped)
    }

    public func unregisterAll() {
        for entry in registered.values {
            UnregisterEventHotKey(entry.ref)
        }
        registered.removeAll()
    }

    /// 事件處理器只裝一次，之後重新註冊綁定不必動它——`InstallEventHandler` 裝兩次
    /// 會讓每個按鍵觸發兩次動作，而畫面上那看起來只是「排版跳了一下」。
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotkeyEventHandler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// C callback 進來的入口。它跑在主執行緒的 run loop 上（Carbon 的事件派發就在
    /// 那裡），所以 `assumeIsolated` 成立。
    fileprivate func fire(_ identifier: UInt32) {
        guard let action = registered[identifier]?.action else { return }
        perform?(action)
    }
}

/// `InstallEventHandler` 要的是 C 函式指標，所以它不能捕捉任何東西——
/// monitor 本身從 `userData` 拿回來。
private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.fire(identifier.id) }
    return noErr
}
