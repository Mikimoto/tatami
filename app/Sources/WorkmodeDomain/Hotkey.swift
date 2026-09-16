/// 一組快捷鍵：修飾鍵集合加一個主鍵。
///
/// 字串形式沿用 skhd 的寫法（`ctrl + alt + cmd - w`），理由是這份設定會落成一個
/// 人看得懂的 JSON 檔，而使用者的 `skhdrc` 就是這個語法——兩邊長得一樣，搬過來
/// 的時候可以逐條肉眼對帳，而 `parsesEverySkhdrcBindingInTheRepo` 那條測試
/// 拿真的 `skhd/skhdrc` 走一趟，是這個 parser 唯一有牙齒的驗法。
///
/// **不存 keycode 而存鍵名**：keycode 是 ANSI 佈局的數字，寫進設定檔之後
/// 換一個鍵盤佈局就變成一個看不懂也改不動的數字。名字轉 keycode 是套用時的事。
public struct Hotkey: Hashable, Sendable {
    /// 修飾鍵。`fn` 不收——`RegisterEventHotKey` 收不到它。
    public enum Modifier: String, CaseIterable, Comparable, Sendable {
        case ctrl, alt, shift, cmd

        /// Carbon 的 modifier mask（`Events.h`）。這四個常數是 API 的一部分，
        /// 不是我們選的，所以寫死在這裡而不是讓 Adapter 自己查表。
        public var carbonMask: UInt32 {
            switch self {
            case .cmd: 0x0100
            case .shift: 0x0200
            case .alt: 0x0800
            case .ctrl: 0x1000
            }
        }

        /// 印出來的順序，也是 `<` 的定義。固定順序讓 `description` 是規範形式，
        /// 於是「同一組鍵有兩種寫法」在設定檔裡不存在。
        private var rank: Int {
            Modifier.allCases.firstIndex(of: self) ?? 0
        }

        public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public let key: String
    public let modifiers: Set<Modifier>

    /// `key` 一律**正規化成表裡那個名字**，不只是轉小寫。
    ///
    /// `0x2a` 與 `\` 是同一顆鍵（keycode 42），而 `Hotkey` 的相等是比字串的：
    /// 不正規化的話那兩種寫法是兩個不同的值，於是 `conflicts` 抓不到它們撞在
    /// 一起，而 `RegisterEventHotKey` 會安靜地拒絕第二次註冊——症狀是
    /// 「我明明設了這個鍵，按下去卻沒反應」。使用者退役前的 `skhdrc` 寫的正是
    /// `alt + cmd - 0x2A`，所以這不是假想的輸入。
    ///
    /// 查不到的名字原樣留著（小寫）：那時 `carbon` 會回 nil，呼叫端把那一條
    /// 報成「認不得按鍵」，比在這裡靜默換成別的鍵好。
    public init(key: String, modifiers: Set<Modifier>) {
        let lowered = key.lowercased()
        self.key = HotkeyKeys.code(for: lowered).map(HotkeyKeys.name) ?? lowered
        self.modifiers = modifiers
    }

    /// skhd 語法的規範形式（`ctrl + alt + cmd - w`）。
    public var description: String {
        let names = modifiers.sorted().map(\.rawValue)
        return names.isEmpty ? "- \(key)" : names.joined(separator: " + ") + " - \(key)"
    }

    /// 解析 skhd 語法。修飾鍵在 `-` 之前、主鍵在之後。
    ///
    /// 切在**第一個** `-`：修飾鍵名全是英文字母，所以第一個 `-` 必定是分隔符，
    /// 而主鍵名（`0x2a`、`pagedown`）本身不含 `-`。
    /// 認不得的修飾鍵一律回 nil 而不是忽略它——忽略等於安靜地註冊一組別的鍵。
    public static func parse(_ text: String) -> Hotkey? {
        guard let separator = text.firstIndex(of: "-") else { return nil }
        let head = text[text.startIndex ..< separator]
        let key = trimmed(text[text.index(after: separator)...]).lowercased()
        guard !key.isEmpty, HotkeyKeys.code(for: key) != nil else { return nil }
        var modifiers: Set<Modifier> = []
        for piece in head.split(separator: "+") {
            let name = trimmed(piece).lowercased()
            if name.isEmpty {
                continue
            }
            guard let modifier = Modifier(rawValue: normalize(name)) else { return nil }
            modifiers.insert(modifier)
        }
        return Hotkey(key: key, modifiers: modifiers)
    }

    /// skhd 認得的別名。`option` 與 `alt` 是同一顆鍵，`control` 與 `ctrl` 同理；
    /// 不收的話使用者手寫的設定會整條被拒絕，而他看不出哪裡不對。
    private static func normalize(_ name: String) -> String {
        switch name {
        case "option", "opt": "alt"
        case "control": "ctrl"
        case "command": "cmd"
        default: name
        }
    }

    /// 這一組適不適合當全域快捷鍵。
    ///
    /// **至少要有一個修飾鍵**（`cmd`／`ctrl`／`alt`；`shift` 不算）：`RegisterEventHotKey`
    /// 註冊的組合會被系統吃掉、不再往下傳，所以一個裸的 `w` 會讓每個 app 裡的
    /// 每一次打字都變成重排視窗，而且無法從那個 app 裡救回來。
    ///
    /// 判斷放在這裡而不是錄製器：`WorkmodeEditorUI` 零測試。
    public var isSafeAsGlobalShortcut: Bool {
        !modifiers.isDisjoint(with: [.cmd, .ctrl, .alt])
    }

    /// Carbon 要的兩個數字。查不到鍵名回 nil。
    public var carbon: (code: UInt32, mask: UInt32)? {
        guard let code = HotkeyKeys.code(for: key) else { return nil }
        return (code, modifiers.reduce(UInt32(0)) { $0 | $1.carbonMask })
    }
}

/// 不用 Foundation 的 `trimmingCharacters(in:)`——Domain 零 import
/// （`WorkmodeArchitectureTests` 在守）。
private func trimmed(_ text: some StringProtocol) -> String {
    var slice = Substring(text)
    while let first = slice.first, first == " " || first == "\t" {
        slice = slice.dropFirst()
    }
    while let last = slice.last, last == " " || last == "\t" {
        slice = slice.dropLast()
    }
    return String(slice)
}
