/// 鍵名 → macOS 虛擬鍵碼（`Carbon/HIToolbox/Events.h` 的 `kVK_*`）。
///
/// 這張表是 **ANSI 佈局**的位置碼，不是字元碼：`kVK_ANSI_A` 是 0，指的是
/// 「標準佈局上 A 所在的那個位置」。所以設定檔存的是名字不是數字——換佈局時
/// 名字仍然對得上使用者印在鍵帽上的東西（見 `Hotkey` 的 doc）。
///
/// 名字沿用 skhd 的（`backspace` 是 ⌫、`delete` 是 fn-⌫），因為使用者的
/// `skhdrc` 就是用那套名字寫的。
public enum HotkeyKeys {
    /// 查不到回 nil。`0x<hex>` 的字面形式一併認得——skhd 對沒有名字的鍵
    /// （`0x2a` 是 `\`）就是這樣寫的，而使用者的檔案裡真的有一條。
    public static func code(for name: String) -> UInt32? {
        if let named = table[name] {
            return named
        }
        guard name.hasPrefix("0x"), let value = UInt32(name.dropFirst(2), radix: 16),
              value < 128 else { return nil }
        return value
    }

    /// 反查：套用時不需要，但 UI 的錄製器拿到的是 keycode，要印回名字給人看。
    /// 表裡沒有的印成 `0x<hex>`，與 `code(for:)` 對稱（round-trip 有測試釘著）。
    public static func name(for code: UInt32) -> String {
        if let match = table.first(where: { $0.value == code }) {
            return match.key
        }
        return "0x" + String(code, radix: 16)
    }

    /// 依 `Events.h` 的 `kVK_*` 逐條抄。分成三段只是為了讀——它是一張表。
    static let table: [String: UInt32] = letters.merging(digits) { first, _ in first }
        .merging(specials) { first, _ in first }

    private static let letters: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static let digits: [String: UInt32] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28,
        "0": 29,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    private static let specials: [String: UInt32] = [
        "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43,
        "/": 44, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
        "home": 115, "pageup": 116, "delete": 117, "end": 119, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86,
        "keypad5": 87, "keypad6": 88, "keypad7": 89, "keypad8": 91, "keypad9": 92,
        "keypadenter": 76, "keypadplus": 69, "keypadminus": 78, "keypadmultiply": 67,
        "keypaddivide": 75, "keypaddecimal": 65, "keypadequals": 81, "keypadclear": 71,
    ]
}
