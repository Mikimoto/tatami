/// 滑鼠拖曳的設定，對應 yabai 的 `mouse_modifier` ＋ `mouse_action1/2`。
///
/// 住在 `hotkeys.json` 的 `mouse` 物件裡而不是另一個檔：它與快捷鍵是同一類東西
/// （「按住什麼、做什麼」），而多一個檔就多一份 dirty、一個 ⌘S 與一道外部變更閘門。
public struct MouseSettings: Equatable, Sendable {
    /// 按住哪一顆才算拖視窗。
    ///
    /// **`fn` 在這裡是合法的，在 `Hotkey.Modifier` 不是**：那邊的限制來自
    /// `RegisterEventHotKey` 收不到 fn，而這條路走的是 CGEvent tap，收得到。
    public enum Modifier: String, CaseIterable, Sendable {
        /// **case 名字是 `function` 而 rawValue 是 `fn`**：swiftlint 的
        /// `identifier_name` 最短三字元（`.swiftlint.yml` 的檔頭明文禁止調參數），
        /// 而寫進 `hotkeys.json` 的字要與 yabai 用的那個相同——使用者的 `yabairc`
        /// 寫的就是 `mouse_modifier fn`。
        case function = "fn"
        case cmd, alt, ctrl, shift
    }

    public let modifier: Modifier
    /// 左鍵拖曳做什麼。nil ＝關掉。
    public let button1: MouseDrag.Action?
    /// 右鍵拖曳做什麼。nil ＝關掉。
    public let button2: MouseDrag.Action?

    public init(modifier: Modifier, button1: MouseDrag.Action?, button2: MouseDrag.Action?) {
        self.modifier = modifier
        self.button1 = button1
        self.button2 = button2
    }

    /// 預設是 **`alt`**，不是 yabai 那三行寫的 `fn`。
    ///
    /// **`fn` 在這台機器上觀測不到**（2026-09-08 實測，三個獨立來源）：真的按住 fn
    /// 再按下滑鼠，`CGEvent.flags`、`CGEventSource.flagsState(.combinedSessionState)`
    /// 與 `NSEvent.modifierFlags` **全部是 0x0**；同一組量測按 ⌥ 則三個來源都正確
    /// 報出 `0x80000`。所以那不是讀法的問題——最可能是 fn 在外接的 Logitech 鍵盤上
    /// 由裝置自己處理、從來沒送到 macOS（`logioptionsplus_agent` 在跑）。
    ///
    /// **推論：yabai 的 `mouse_modifier fn` 在這台機器上大概也從來沒生效過。**
    /// 那三行只是在重述 yabai 的預設值，而「yabai 還在做 fn ＋ 拖曳」那個結論
    /// 是拿**合成事件**（我們自己設 `.maskSecondaryFn`）驗出來的——它證明了 tap
    /// 收得到帶旗標的事件，證明不了真的 fn 鍵會設那個旗標。那次實測**沒有**
    /// 驗到這個功能可用，而我當時把它寫成驗過了。
    ///
    /// `fn` 仍然留在 `Modifier` 裡：別的機器（內建鍵盤）上它是好的。
    public static let defaults = MouseSettings(modifier: .alt, button1: .move,
                                               button2: .resize)

    /// 兩顆都關掉＝不必裝事件監聽。呼叫端據此決定要不要建 tap——建一個什麼都不做
    /// 的 tap 只是白付一次權限檢查與每一個滑鼠事件的往返。
    public var isDisabled: Bool {
        button1 == nil && button2 == nil
    }

    /// `hotkeys.json` 的 `mouse` 物件。整個鍵不存在就回預設值——與綁定那半同一條：
    /// 檔案沒提到的東西用內建值，不是關掉它。
    ///
    /// **認不得的值一律回 nil（＝關掉那顆），不是靜默退回預設**：使用者打錯
    /// `"button1": "mvoe"` 時「那顆沒反應」查得出來（他打的字還在檔案裡），
    /// 而「悄悄變成 move」查不出來。modifier 打錯則整個物件退回預設並由呼叫端
    /// 報一句——沒有修飾鍵可用的話兩顆都不能動，那不是「關掉一顆」。
    public static func read(_ value: JSONValue?) -> (settings: MouseSettings, problem: String?) {
        guard let value else { return (defaults, nil) }
        guard case let .object(fields) = value else {
            return (defaults, "mouse 不是物件，用內建的預設值")
        }
        func text(_ key: String) -> String? {
            guard case let .string(found)? = fields.first(where: { $0.key == key })?.value
            else { return nil }
            return found
        }
        let name = text("modifier") ?? defaults.modifier.rawValue
        guard let modifier = Modifier(rawValue: name) else {
            return (defaults, "認不得 mouse.modifier「\(name)」，用內建的預設值")
        }
        return (MouseSettings(modifier: modifier,
                              button1: action(text("button1"), defaults.button1),
                              button2: action(text("button2"), defaults.button2)), nil)
    }

    /// 鍵不存在用預設；存在但認不得就是關掉（見 `read` 的 doc）。
    private static func action(_ text: String?, _ fallback: MouseDrag.Action?)
        -> MouseDrag.Action?
    {
        guard let text else { return fallback }
        return MouseDrag.Action(rawValue: text)
    }

    /// 寫回去。**與預設值相同時整個物件不寫**——這個檔是給人看的，
    /// 寫一份與內建相同的設定只是雜訊（`enabled` 與 `float` 同一條）。
    public var member: JSONMember? {
        guard self != Self.defaults else { return nil }
        var fields = [JSONMember(key: "modifier", value: .string(modifier.rawValue))]
        // 關掉的那顆寫成 `"off"`：省略它會在下一次讀的時候變回預設值。
        fields.append(JSONMember(key: "button1",
                                 value: .string(button1?.rawValue ?? "off")))
        fields.append(JSONMember(key: "button2",
                                 value: .string(button2?.rawValue ?? "off")))
        return JSONMember(key: "mouse", value: .object(fields))
    }
}
