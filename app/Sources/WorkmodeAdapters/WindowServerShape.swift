import ApplicationServices
import WorkmodeDomain

/// `WindowServerClient` 回給 Core 的 **yabai 形狀** JSON。
///
/// 拆成獨立檔只有一個理由：`WindowServerClient.swift` 撞到 swiftlint 的 `file_length`
/// （上限 400），而這一段是整份裡與其餘部分耦合最少的——它只讀中間表示、不碰任何
/// 系統 API（`windowJSON` 的 deep 那半是唯一的例外）。
extension WindowServerClient {
    /// yabai 的 frame 印四位小數（`4736.0000`）；Core 那側 `Measurements.flooredFrameField`
    /// 會 floor，所以印法只要是合法數字就好，照抄 yabai 是為了 `ws` 的 diff 好看。
    func number(_ value: Double) -> JSONValue {
        .number(String(format: "%.4f", value))
    }

    func frameJSON(_ rect: Rect) -> JSONValue {
        .object([JSONMember(key: "x", value: number(rect.originX)), JSONMember(key: "y", value: number(rect.originY)),
                 JSONMember(key: "w", value: number(rect.width)), JSONMember(key: "h", value: number(rect.height))])
    }

    func displayJSON(_ display: DisplayInfo) -> JSONValue {
        .object([JSONMember(key: "uuid", value: .string(display.uuid)),
                 JSONMember(key: "index", value: .number("\(display.index)")),
                 JSONMember(key: "frame", value: frameJSON(display.frame)),
                 JSONMember(key: "spaces", value: .array(display.spaces.map { .number("\($0.index)") }))])
    }

    func spaceJSON(_ space: SpaceInfo) -> JSONValue {
        .object([JSONMember(key: "index", value: .number("\(space.index)")),
                 JSONMember(key: "uuid", value: .string(space.uuid)),
                 JSONMember(key: "display", value: .number("\(space.display)")),
                 JSONMember(key: "is-visible", value: .bool(space.isVisible))])
    }

    /// `deep` 才問 AX（title／document）：`.windows` 是規則比對用的，
    /// 30 個視窗各搜一次 AX 元素要秒級；`.window(id)` 只有一個。
    ///
    /// **`is-floating`／`is-visible`／`is-minimized` 這三個一律要在**，即使這個引擎
    /// 沒有它們的指涉物。`ManagedWindow.matches`（`SpaceRects` 與 `Measurements` 的
    /// 那個 select）要求三個**恰好**等於 `false`／`false`／`true`，而缺欄位是 null
    /// ——`null == false` 是 false，所以少一個欄位就等於「每一個視窗都不受管理」。
    /// 症狀是 `--save` 印「這些螢幕上沒有任何可以存的視窗」然後一個字都不寫，
    /// 而畫面上明明有視窗（2026-09-08 實際發生，選單列與 CLI 兩條路都中）。
    ///
    /// 值的來源不是量測而是**這條路的漏斗**（`layer == 0`、剛好屬於一個 space、
    /// subrole allowlist）：走到這裡的就是「一個真的、排得動的視窗」，而那三個欄位
    /// 是這個形狀裡唯一能表達那句話的詞彙。逐一說明為什麼不照 yabai 的語意填：
    ///
    /// * `is-floating` ＝「被排除在 bsp 樹外」。這個引擎沒有 bsp 樹，沒有指涉物。
    /// * `is-visible` ＝「在目前可見的 space 上」。照那個語意填會把 `--save --all`
    ///   關掉——它存的正是**不可見**的那些 space。
    /// * `is-minimized` 只有 AX 知道，而問它要 15–220ms／個。`.windowsOnSpace`
    ///   也走這條（`SpaceLayout.hasSafari` 每次切 space 都叫它），所以這裡不能問。
    ///   **代價：最小化的視窗會被 `--save` 存進樹，帶著它縮起來之前的 frame。**
    func windowJSON(_ window: WindowInfo, deep: Bool) -> JSONValue {
        var members = [JSONMember(key: "id", value: .number("\(window.id)")),
                       JSONMember(key: "pid", value: .number("\(window.pid)")),
                       JSONMember(key: "app", value: .string(window.app)),
                       JSONMember(key: "frame", value: frameJSON(window.frame)),
                       JSONMember(key: "space", value: .number("\(window.space)")),
                       JSONMember(key: "display", value: .number("\(window.display)")),
                       JSONMember(key: "is-floating", value: .bool(false)),
                       JSONMember(key: "is-visible", value: .bool(true)),
                       JSONMember(key: "is-minimized", value: .bool(false))]
        if deep, let element = AXWindow.find(pid: window.pid, id: window.id, bridge: bridge) {
            members.append(JSONMember(key: "title", value: .string(element.title ?? "")))
            // 覆寫上面那個佔位的 false，不是再 append 一個——同名鍵兩份的話
            // `JSONValue` 的下標取到的是第一個，也就是永遠取到那個假的。
            if let index = members.firstIndex(where: { $0.key == "is-minimized" }) {
                members[index] = JSONMember(key: "is-minimized",
                                            value: .bool(element.isMinimized ?? false))
            }
            if let document = element.document {
                members.append(JSONMember(key: "document", value: .string(document)))
            }
        }
        return .object(members)
    }
}
