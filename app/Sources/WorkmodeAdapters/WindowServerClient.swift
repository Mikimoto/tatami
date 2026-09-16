import AppKit
import ApplicationServices
import WorkmodeCore
import WorkmodeDomain

/// 用 AX 加 SkyLight 實作 `YabaiClient` 的查詢形狀，外加 `WindowServer.setFrame`。
///
/// 回 yabai 形狀的 JSON 是刻意的：Core 讀那個形狀讀了兩年（`LayoutPreamble`、
/// `RuleResolution`、`MinimizedWindows`、`SpaceLayout` 全在讀），換型別等於重寫它們。
/// 只做 Core **實際讀的**欄位：displays 的 `uuid/index/frame`、spaces 的
/// `index/uuid/display/is-visible`、windows 的 `id/pid/app/title/frame/space/display/is-minimized`。
/// `tatami ws spaces|windows` 印的就是這份，所以能直接與 `yabai -m query` diff。
///
/// **`frame` 是可視區**（扣掉選單列與 Dock），yabai 印的是整個螢幕。`TreeRects` 拿它
/// 當畫布，這樣使用者 padding 為 0 的設定不必再算選單列。差異寫在 `ws spaces` 的說明。
///
/// **必須在 main thread 呼叫**（`NSScreen` 是 `@MainActor`；CLI 的 `main.swift` 是）。
/// `MainActor.assumeIsolated` 猜錯是當場 crash 不是靜默錯值，`EditCommand.swift:62` 同一個取捨。
public struct WindowServerClient: YabaiClient, WindowServer {
    private let skyLight: SkyLight
    let bridge: AXWindow.Bridge

    public init() throws {
        // 鍵寫字面值而不是 `kAXTrustedCheckOptionPrompt`：那個符號在 Swift 是
        // 一個 `var`，Swift 6 的嚴格併發把它判成共享可變狀態而編不過。
        // 它的值就是這個字串（ApplicationServices 的 `AXUIElement.h`）。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw WindowServerFailure.notTrusted }
        skyLight = try SkyLight()
        bridge = try AXWindow.Bridge()
    }

    // MARK: - YabaiClient

    public func query(_ query: YabaiQuery) throws -> JSONValue {
        switch query {
        case .displays:
            return .array(displays().map(displayJSON))
        case let .display(index):
            return .array(displays().filter { index == "\($0.index)" }.map(displayJSON))
        case .spaces:
            return .array(spaces().map(spaceJSON))
        case .windows:
            return .array(windows().map { windowJSON($0, deep: false) })
        case let .windowsOnSpace(index):
            return .array(windows().filter { index == "\($0.space)" }.map { windowJSON($0, deep: false) })
        case let .window(id):
            // 與 yabai 一樣：查不到的視窗是 malformedOutput，Core 用 `try?` 接成「跳過它」。
            guard let target = CGWindowID(id), let info = window(id: target) else {
                throw YabaiError.malformedOutput(argv: query.argv)
            }
            return windowJSON(info, deep: true)
        }
    }

    /// 只支援 `--space` 那條路會下的兩個命令；bsp 命令（warp／swap／toggle／ratio）
    /// 在這個引擎沒有意義，收到就是 Core 走錯路，直接失敗。
    public func run(_ command: YabaiCommand) throws {
        switch command {
        case let .deminimize(window):
            try axWindow(window).deminimize()
        case let .moveToSpace(window, spaceIndex):
            guard let target = spaces().first(where: { spaceIndex == "\($0.index)" }) else {
                throw YabaiError.commandFailed(argv: command.argv, status: 1)
            }
            guard let id = CGWindowID(window) else { throw WindowServerFailure.windowNotFound(window) }
            if skyLight.spaces(ofWindow: id).contains(target.id) {
                return
            }
            guard skyLight.move(window: id, toSpace: target.id) else {
                throw YabaiError.commandFailed(argv: command.argv, status: 1)
            }
            // **搬移是非同步的，而且要 run loop 跑過才會生效。** 實測（2026-09-04）：
            // 只 `usleep` 的話等 3.6 秒視窗一動也不動，讓 run loop 跑一次就在 20ms 內
            // 到位。所以這裡不是「等它慢慢好」而是「給它機會執行」——用 `usleep` 取代
            // 這個迴圈會讓搬移**永遠不發生**，而外觀只是「視窗沒過去」。
            //
            // 預算 1 秒與 `setFrame` 同級。追不上就讓下一步的 `setFrame` 去發現：
            // 視窗還在別的 space 時 AX 照樣設得動，使用者切過去才看得出來。
            for _ in 0 ..< Self.movePolls {
                RunLoop.current.run(until: Date().addingTimeInterval(Self.moveInterval))
                if skyLight.spaces(ofWindow: id).contains(target.id) {
                    return
                }
            }
        case .warp, .toggleSplit, .swap, .setRatio:
            throw YabaiError.commandFailed(argv: command.argv, status: 1)
        }
    }

    /// 見 `SkyLight.canMoveAcrossSpaces`。給 `__smoke ws` 用。
    public var canMoveAcrossSpaces: Bool {
        skyLight.canMoveAcrossSpaces
    }

    // MARK: - WindowServer

    /// 設完重讀 **window server** 的 bounds，不是 AX 的：前者是畫面上真的位置
    /// （實測對不可見 space 的視窗也會變），後者是 app 自己的說法。
    ///
    /// **要輪詢，不能設完立刻讀。** 實測（2026-09-03，Ghostty 在不可見的 space 4 上，
    /// 兩個方向各一次）：`AXUIElementSetAttributeValue` **0.2–0.3ms** 就回來，而
    /// `kCGWindowBounds` 要 **85ms／115ms** 才追上。立刻讀必定讀到舊值，而呼叫端
    /// （`FrameLayout`）拿它跟要求的比，差超過 1pt 就發 `frameRejected`——於是**每一個
    /// 視窗都會被誤報成拒絕**，而畫面上明明排對了。這個坑與 `--deminimize` 之後不能
    /// 立刻查 `is-minimized`（CLAUDE.md 記的那個 ~600ms 動畫）是同一個形狀。
    ///
    /// 追上就回，沒追上就回**最後讀到的值**——那才是呼叫端要的：app 真的把 frame 夾掉
    /// 時它永遠追不上，而那時該報的就是它實際停在哪裡。代價是被夾住的視窗每個要等滿
    /// 預算。
    ///
    /// **預算 2026-09-03 從 300ms 提到 1000ms**，因為 300ms 是拿小幅搬移量出來的：
    ///
    /// | 動作 | bounds 追上要多久 |
    /// |---|---|
    /// | 小幅搬移（±60px） | 82ms／97ms |
    /// | 大幅搬移（±1504px，跨半個螢幕） | **244ms／250ms** |
    ///
    /// 跨半個螢幕的搬移只剩幾十毫秒餘裕，實跑 `--space` 就有視窗因此被誤報成拒絕。
    /// 提高預算不會讓每次套版變慢，前提是**頂端 inset 已經校準**（見 `TopInset`）：
    /// 命中的視窗一輪就返回，只有真的被夾住的才等滿。
    /// 設 frame，等它到位，**沒到位就再設一次**（2026-09-10 的缺陷修正，機制寫在
    /// `AXWindow.setFrame`：位置套用的是視窗當下的尺寸，配不上就被靜默拒絕）。
    ///
    /// 重試掛在這個**本來就在輪詢**的迴圈上，不是在下面連設兩次——AX 設完要
    /// 85–115ms 畫面才追上，背靠背的第二輪讀到的仍是舊尺寸，實測零改善。
    /// 預算沒變（1 秒），只是切成 `setAttempts` 段；到不了的視窗照舊等滿、
    /// 回最後讀到的值、呼叫端照舊發 `frameRejected`。
    public func setFrame(window: String, _ frame: Rect) throws -> Rect {
        let target = try axWindow(window)
        guard let id = CGWindowID(window) else {
            throw WindowServerFailure.windowNotFound(window)
        }
        var last: Rect?
        for _ in 0 ..< Self.setAttempts {
            try target.setFrame(frame)
            for _ in 0 ..< Self.pollsPerAttempt {
                guard let bounds = serverBounds(of: id) else { break }
                last = bounds
                if bounds.isClose(to: frame, within: Self.settleTolerance) {
                    return bounds
                }
                usleep(Self.settleInterval)
            }
        }
        guard let bounds = last else { throw WindowServerFailure.windowNotFound(window) }
        return bounds
    }

    /// 搬 space 的預算：1 秒，每次讓 run loop 跑 20ms。實測到位是第一輪就到，
    /// 這個迴圈的存在理由是**讓 run loop 有機會跑**而不是等很久。
    private static let movePolls = 50
    private static let moveInterval = 0.02

    /// `setFrame` 的預算：1000ms，5ms 一次。與 `FrameLayout.tolerance` 用同一個 1pt
    /// ——這裡若比它鬆，「輪詢覺得追上了」與「呼叫端覺得被拒絕」就會同時成立而永遠
    /// 報一句假的拒絕。
    /// 每次設定給 335ms 追上，最多 3 次——總預算仍是原本的 1 秒。3 次是因為實測
    /// **第二次**就到位（第一次讓尺寸變對、第二次位置才設得上），第三次留給有動畫的 app。
    private static let setAttempts = 3
    private static let pollsPerAttempt = 67
    private static let settleInterval: UInt32 = 5000
    private static let settleTolerance = 1.0

    // MARK: - 中間表示

    struct DisplayInfo {
        let uuid: String
        let index: Int
        let frame: Rect
        let spaces: [SpaceInfo]
    }

    struct SpaceInfo {
        let id: UInt64
        let uuid: String
        let index: Int
        let display: Int
        let isVisible: Bool
    }

    struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let frame: Rect
        let space: Int
        let display: Int
    }

    /// mission control 編號跨螢幕累加，yabai 也這樣算。
    func displays() -> [DisplayInfo] {
        let visible = visibleFrames()
        var nextIndex = 1
        return skyLight.managedDisplays().enumerated().map { offset, managed in
            let displayIndex = offset + 1
            let spaces = managed.spaces.map { space in
                defer { nextIndex += 1 }
                return SpaceInfo(id: space.id, uuid: space.uuid, index: nextIndex,
                                 display: displayIndex, isVisible: space.id == managed.currentSpace)
            }
            return DisplayInfo(uuid: managed.uuid, index: displayIndex,
                               frame: visible[managed.uuid] ?? Rect(originX: 0, originY: 0, width: 0, height: 0),
                               spaces: spaces)
        }
    }

    func spaces() -> [SpaceInfo] {
        displays().flatMap(\.spaces)
    }

    /// yabai 會管的那幾種 subrole。**不能只收 `AXStandardWindow`**：實測那一輪 10 個
    /// 視窗裡有一個（CleanMyMac 295×68）是 `AXDialog`，而 yabai 自己也收 dialog 這幾種。
    static let managedSubroles: Set<String> = [
        "AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow",
    ]

    /// 一般視窗，含不可見 space 上的與最小化的（`.optionAll`）。
    /// `title` 不在這裡：`kCGWindowName` 要螢幕錄製權限，而 Core 的規則比對不讀 yabai 的 title。
    ///
    /// **漏斗（2026-09-03 實測，螢幕未鎖時；最後與 `yabai -m query --windows` 逐一相同）**：
    ///
    ///     CG 全部（.optionAll）               219 筆
    ///     ＋ layer == 0                       177 筆     21ms
    ///     ＋ spaces(ofWindow:).count == 1      14 筆      6ms
    ///     ＋ 每個 pid 建一次 AX 元素表          （不篩）   93ms（8 個 pid）
    ///     ＋ subrole ∈ managedSubroles         10 筆    667ms
    ///
    /// 最後那 667ms **全部是三次暴力搜的錢**，而且變動很大：搜得到的話一次十幾毫秒
    /// （實測第 43 個 token 就中），搜不到就是掃滿 `0..<0x7fff` 約 220ms。整趟
    /// `tatami ws windows` 實測 0.78–0.80 秒（三次搜、其中一次掃滿沒找到），而同一支
    /// 程式在沒有任何一次要搜的那一輪是 **0.10–0.13 秒**——這個數字取決於當下有幾個
    /// 不可見 space 上的視窗沒有 AX 元素，不是取決於程式。
    ///
    /// **`layer == 0` 不能拿掉。** 拿掉之後所有 CG 條目都要走到 AX 那一關，實測整趟
    /// **10350ms**；而它換來的只有一個 yabai 也標成 floating 的 1×2 helper（見下）。
    ///
    /// 被 `count == 1` 擋掉的 163 筆是每個 app 為每台螢幕造的選單列高度長條
    /// （寬滿版、高 30／33，一台螢幕四條），它們**不屬於任何 space**。
    /// 這道**不會**吃掉最小化的視窗——實測 Finder 的視窗 `kAXMinimizedAttribute = true`
    /// 期間 `spaces(ofWindow:)` 全程都是 `[19]`、也還在 CG 清單裡，而 `--space`
    /// 必須看得到它們才還原得了。
    ///
    /// subrole 擋掉的四個逐一實測：Safari 兩個 60×20 的面板（一個在可見 space 上根本
    /// 沒有 AX 元素，一個在不可見 space 上搜得到但 subrole 是 `AXUnknown`）、
    /// CleanMyMac 兩個 256×256 的 `AXUnknown`。
    ///
    /// **`alpha` 不是判準。** 這裡原本有一道 `alpha > 0`，理由寫「那些面板的 alpha 是
    /// 0.0」——那份量測是**螢幕鎖住時**做的，解鎖之後同一個視窗的 alpha 是 **1.00**。
    ///
    /// **已知與 yabai 的一個差異，刻意不追。** 這一輪中途 Thaw 開了一個 1×2、alpha=0、
    /// **`layer == 3`**、subrole `AXSystemDialog` 的 helper（id 1996），yabai 列它
    /// （`layer=above`、`is-floating=true`），我們的 `layer == 0` 擋掉它。要收它只有
    /// 兩條路：整個拿掉 layer 那一關（10.35 秒），或替 layer 3 開一張白名單——後者
    /// 會把「1×2 的隱形 helper」放進規則比對的候選，而它連 yabai 自己都不會排。
    ///
    /// **第二個差異，這個是能力限制不是取捨。** 行事曆（pid 500）的視窗 117 在
    /// **可見**的 space 1 上、yabai 列它，而它的 app 元素 `kAXWindowsAttribute`
    /// 回**成功且 0 個**（連跑四次、`AXUIElementGetAttributeValueCount` 也是 0，
    /// `AXChildren` 只有一個 `AXMenuBar`，`AXFocusedWindow` 回 -25212），remote token
    /// 掃滿 0…0x7fff 也找不到。收不到它其實是一致的——AX 拿不到元素就等於 `setFrame`
    /// 也做不到，列出一個排不動的視窗只會讓 `--space` 每次印一句失敗。
    ///
    /// **而且 yabai 自己也拿不到**：它那筆記錄的 `has-ax-reference` 是 **false**、
    /// `subrole` 是空字串（實測），System Events 對行事曆一樣回 0 個視窗。所以這不是
    /// 「yabai 有歷史、我們沒有」，是那個視窗現在對 AX 整個不可達，yabai 只是還留著
    /// 一筆它自己也動不了的記錄。判別方法：
    /// `yabai -m query --windows | jq '.[]|select(.["has-ax-reference"]==false)'`。
    ///
    /// **螢幕鎖住時這裡會回空的**——`AXIsProcessTrusted()` 照樣是 true、
    /// `kAXWindowsAttribute` 照樣回元素，只是那些元素拿不到 window id（`-25201`），
    /// 於是每個視窗看起來都沒有 AX 元素。查鎖定狀態：
    /// `ioreg -n Root -d1 -k IOConsoleUsers | grep CGSSessionScreenIsLocked`。
    func windows() -> [WindowInfo] {
        let spaceList = spaces()
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = raw.compactMap { candidate($0, spaceList: spaceList) }
        var byPID: [pid_t: [CGWindowID: AXWindow]] = [:]
        return candidates.filter { candidate in
            let pid = candidate.info.pid
            let listed = byPID[pid] ?? AXWindow.windowsByID(pid: pid, bridge: bridge)
            byPID[pid] = listed
            return isManaged(candidate, listed: listed)
        }.map(\.info)
    }

    /// 單一 id：與 `windows()` 同一組過濾，但**只問這一個視窗**。
    /// `.window(id)` 走這條而不是重建整份清單，因為 `MinimizedWindows` 還原一個視窗
    /// 時會輪詢它最多 20 次——整份清單一次 0.78 秒，二十次就是十幾秒。
    /// 實測單一 id 34ms（Zed 那個 227ms，AX 慢的是那個 app 不是這條路）。
    /// 單一 id 的查詢。走 `entry(of:)` 而不是 `.optionIncludingWindow`——見那支的說明，
    /// 被蓋住的視窗在單一查詢下是查不到的，而那正是 `--space` 每次都要碰的那幾個。
    func window(id: CGWindowID) -> WindowInfo? {
        guard let entry = entry(of: id),
              let found = candidate(entry, spaceList: spaces()) else { return nil }
        let listed = AXWindow.windowsByID(pid: found.info.pid, bridge: bridge)
        return isManaged(found, listed: listed) ? found.info : nil
    }

    // MARK: - 私有

    /// CG 那一半：`layer == 0` 加上「剛好屬於一個 space」。
    /// `onVisibleSpace` 給 `isManaged` 決定要不要付暴力搜的錢。
    private struct Candidate {
        let info: WindowInfo
        let onVisibleSpace: Bool
    }

    private func candidate(_ entry: [String: Any], spaceList: [SpaceInfo]) -> Candidate? {
        guard (entry[kCGWindowLayer as String] as? Int) == 0,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = entry[kCGWindowBounds as String] as? [String: Double],
              let originX = bounds["X"], let originY = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return nil }
        let onSpaces = skyLight.spaces(ofWindow: id)
        guard onSpaces.count == 1 else { return nil }
        let space = onSpaces.first.flatMap { sid in spaceList.first { $0.id == sid } }
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (entry[kCGWindowOwnerName as String] as? String) ?? ""
        let info = WindowInfo(id: id, pid: pid, app: app,
                              frame: Rect(originX: originX, originY: originY, width: width, height: height),
                              space: space?.index ?? 0, display: space?.display ?? 0)
        return Candidate(info: info, onVisibleSpace: space?.isVisible ?? false)
    }

    /// **不在 AX 清單裡而且在可見 space 上 → 直接丟掉，不要暴力搜。**
    /// 可見 space 上的視窗一定列得出來，列不出來就是它根本沒有元素；那種每個都要掃滿
    /// `0..<0x7fff`，實測整批從 129ms 變 **10810ms**。不可見 space 上的才搜
    /// （那是 `AXWindow` 的 doc 講的那個 macOS 限制），實測那一輪只有 3 次。
    private func isManaged(_ candidate: Candidate, listed: [CGWindowID: AXWindow]) -> Bool {
        let element = listed[candidate.info.id] ?? (candidate.onVisibleSpace
            ? nil : AXWindow.search(pid: candidate.info.pid, id: candidate.info.id, bridge: bridge))
        guard let subrole = element?.subrole else { return false }
        return Self.managedSubroles.contains(subrole)
    }

    /// 不是 private：`WindowControlClient.swift` 的 focus 與 close 要用它，
    /// 而 `private` 是同檔可見。
    func axWindow(_ window: String) throws -> AXWindow {
        guard let id = CGWindowID(window), let info = self.window(id: id),
              let found = AXWindow.find(pid: info.pid, id: id, bridge: bridge)
        else { throw WindowServerFailure.windowNotFound(window) }
        return found
    }

    /// **不能用 `CGWindowListCopyWindowInfo([.optionIncludingWindow], id)`。** 那個查詢
    /// 對**被別的視窗蓋住**的視窗回**零筆**（2026-09-03 實測：Ghostty 113 與 Safari 141
    /// 各回 1 筆，而同樣在可見 space 上、只是被蓋住的 Tower 121 與郵件 2460 回 0 筆；
    /// 加上 `.optionAll` 也一樣是 0）。它看的是「螢幕上」而不是「存在」。
    ///
    /// 所以單一查詢只當**快路徑**：它答得出來就用（實測 0.19ms／次），答不出來才掃
    /// 全表（4.4ms／次）。兩者差 23 倍，而 `setFrame` 的輪詢會叫它最多 60 次——
    /// 全部走全表就是 264ms，剛好把 300ms 的 settle 預算吃掉。
    ///
    /// 掃全表本身不貴：真正的成本是逐視窗的 AX 與 space 查詢，而那部分呼叫端只做
    /// 被指名的那一個。
    private func entry(of id: CGWindowID) -> [String: Any]? {
        if let fast = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
            as? [[String: Any]])?.first
        {
            return fast
        }
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.first { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    private func serverBounds(of id: CGWindowID) -> Rect? {
        guard let bounds = entry(of: id)?[kCGWindowBounds as String] as? [String: Double],
              let originX = bounds["X"], let originY = bounds["Y"],
              let width = bounds["Width"], let height = bounds["Height"] else { return nil }
        return Rect(originX: originX, originY: originY, width: width, height: height)
    }

    /// uuid → 可視區（CG 座標）。NSScreen 是左下原點，要翻：CG 的 y ＝ 主螢幕高 − NS 的 maxY。
    private func visibleFrames() -> [String: Rect] {
        MainActor.assumeIsolated {
            guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [:] }
            var out: [String: Rect] = [:]
            for screen in NSScreen.screens {
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                guard let number = screen.deviceDescription[key] as? CGDirectDisplayID,
                      let reference = CGDisplayCreateUUIDFromDisplayID(number) else { continue }
                let uuid = CFUUIDCreateString(nil, reference.takeRetainedValue()) as String
                let visible = screen.visibleFrame
                out[uuid] = Rect(originX: visible.origin.x, originY: primaryHeight - visible.maxY,
                                 width: visible.width, height: visible.height)
            }
            return out
        }
    }
}
