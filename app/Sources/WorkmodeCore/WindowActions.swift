import WorkmodeDomain

/// 一個快捷鍵動作的編排。
///
/// **`applyLayout` 與 `showGrid` 不在這裡**：那兩個已經各有入口（`SpaceLayout`
/// 與另一個行程的 `tatami grid`），由 CLI 那層在呼叫這支之前先接走。這裡只做
/// 「對視窗動手」的那些，於是它需要的 port 是固定的五個，測得起來。
public struct WindowActions {
    // 不是 private：`WindowActionsLayout.swift` 那半要用，而 `private` 是同檔可見
    // （拆檔的理由是 file_length，不是封裝）。
    let yabai: any YabaiClient
    let server: any WindowServer
    let control: any WindowControl
    private let shell: any ShellRunner
    let files: any FileStore
    let statePath: String
    let reporter: any Reporter
    /// balance／rotate／gaps 跳過的 app 名（`hotkeys.json` 的 `float` 清單）。
    /// 只影響那三個掃整個 space 的動作——focus／swap／stack 是使用者指著一個
    /// 視窗做的事，指得到就該做。
    let floatApps: [String]
    /// 每台螢幕的格線設定。格線放置與三個走樹的動作都讀它。
    let grids: [String: GridConfig]

    public init(yabai: any YabaiClient, server: any WindowServer, control: any WindowControl,
                shell: any ShellRunner, files: any FileStore, statePath: String,
                reporter: any Reporter, floatApps: [String],
                grids: [String: GridConfig])
    {
        self.yabai = yabai
        self.server = server
        self.control = control
        self.shell = shell
        self.files = files
        self.statePath = statePath
        self.reporter = reporter
        self.floatApps = floatApps
        self.grids = grids
    }

    /// 做一個動作。失敗一律發事件而不是 throw——按鍵沒有呼叫端可以處理錯誤，
    /// 而使用者要的是一句話說明為什麼沒反應。
    public func run(_ action: HotkeyAction) {
        // `shell:` 不需要焦點視窗，所以它在讀畫面之前就分岔——為了一條開桌面的
        // 命令去掃 219 個視窗是白付的。
        if case let .runShell(command) = action {
            do { try shell.run(command) } catch {
                reporter.report(.hotkeyShellFailed(command: command,
                                                   status: statusOf(error)))
            }
            return
        }
        // 兩層 optional：`try?` 一層，port 自己「檔案不存在回 nil」一層。
        let state = ((try? files.read(atPath: statePath)) ?? nil) ?? ""
        guard let scene = WindowScene.read(yabai: yabai, control: control, state: state)
        else {
            reporter.report(.hotkeyNoFocusedWindow)
            return
        }
        perform(action, scene, state)
    }

    /// 拆成兩支只為了過 swiftlint 的 `cyclomatic_complexity`（上限 10，不准調參數）。
    /// 界線是「只碰焦點視窗」與「碰整個 space 或別的螢幕」。
    private func perform(_ action: HotkeyAction, _ scene: WindowScene, _ state: String) {
        switch action {
        case let .focusWindow(direction): focus(direction, scene)
        case let .swapWindow(direction): swap(direction, scene)
        case let .stackWindow(direction): stack(direction, scene)
        case let .focusStack(next): cycleStack(next: next, scene)
        case let .placeGrid(rows, columns, originX, originY, width, height):
            // 間距**無條件**套（不看 `gaps` 那個開關）：那台螢幕的間距是它的
            // 固定屬性，讓 toggle 管它會做出「我設了 20 卻沒效果」而原因在
            // 另一個開關。`gaps` 只管 balance／rotate，它本來就只影響那三個。
            place(GapInset.cell(config(scene),
                                spec: .init(rows: rows, columns: columns, originX: originX,
                                            originY: originY, width: width, height: height),
                                canvas: scene.canvas), scene.focused)
        case let .resizeWindow(deltaWidth, deltaHeight):
            place(WindowGeometry.resized(scene.frame, deltaWidth: Double(deltaWidth),
                                         deltaHeight: Double(deltaHeight),
                                         canvas: scene.canvas), scene.focused)
        case .closeWindow: try? control.close(window: scene.focused)
        case .balanceSpace, .moveToDisplay, .moveToSpace, .rotateSpace, .toggleFullscreen,
             .toggleGaps:
            performAcrossTheSpace(action, scene, state)
        // `applyLayout` 與 `showGrid` 由 CLI 那層在呼叫這支之前接走，
        // `runShell` 在 `run` 就分岔了。
        case .applyLayout, .showGrid, .runShell: break
        }
    }

    private func performAcrossTheSpace(_ action: HotkeyAction, _ scene: WindowScene,
                                       _ state: String)
    {
        switch action {
        case let .moveToSpace(target): move(toSpace: target, scene)
        case let .moveToDisplay(target): move(toDisplay: target, scene, state)
        case .toggleFullscreen: toggleFullscreen(scene, state)
        case .balanceSpace: relayout(scene, state, flipAxes: false)
        case .rotateSpace: relayout(scene, state, flipAxes: true)
        case .toggleGaps: toggleGaps(scene, state)
        // 兩支都窮舉、都不用 `default`：新增一個動作而忘了接它，會是編譯錯誤
        // 而不是「這個鍵沒反應」（與兩個 renderer 同一條紀律）。
        case .applyLayout, .closeWindow, .focusStack, .focusWindow, .placeGrid,
             .resizeWindow, .runShell, .showGrid, .stackWindow, .swapWindow:
            break
        }
    }

    // MARK: - 方向那四個

    private func focus(_ direction: HotkeyAction.Direction, _ scene: WindowScene) {
        guard let target = WindowGeometry.neighbour(of: scene.frame, among: scene.others,
                                                    direction: direction)
        else {
            reporter.report(.hotkeyNoNeighbour(direction: direction.rawValue))
            return
        }
        try? control.focus(window: target.id)
    }

    /// 交換兩個視窗的 frame。yabai 的 `--swap` 換的是樹裡的位置；沒有樹的時候
    /// 換座標就是使用者看到的同一件事。
    private func swap(_ direction: HotkeyAction.Direction, _ scene: WindowScene) {
        guard let target = WindowGeometry.neighbour(of: scene.frame, among: scene.others,
                                                    direction: direction)
        else {
            reporter.report(.hotkeyNoNeighbour(direction: direction.rawValue))
            return
        }
        place(target.frame, scene.focused)
        place(scene.frame, target.id)
    }

    /// 疊到鄰居身上。單向——鄰居不動，所以連按兩次不會回到原位。
    private func stack(_ direction: HotkeyAction.Direction, _ scene: WindowScene) {
        guard let target = WindowGeometry.neighbour(of: scene.frame, among: scene.others,
                                                    direction: direction)
        else {
            reporter.report(.hotkeyNoNeighbour(direction: direction.rawValue))
            return
        }
        place(target.frame, scene.focused)
        try? control.focus(window: scene.focused)
    }

    /// 在「疊在同一個位置」的那群裡循環焦點。只有自己一個就什麼都不做——
    /// 對自己 `focus` 一次是 no-op，但那會讓「這個鍵沒反應」少一句解釋。
    private func cycleStack(next: Bool, _ scene: WindowScene) {
        let group = WindowGeometry.stack(around: scene.frame, among: scene.onSpace)
        guard group.count > 1, let position = group.firstIndex(where: { $0.id == scene.focused })
        else {
            reporter.report(.hotkeyNoNeighbour(direction: next ? "stack.next" : "stack.prev"))
            return
        }
        let step = next ? 1 : group.count - 1
        try? control.focus(window: group[(position + step) % group.count].id)
    }

    // MARK: - 設 frame

    /// 設完重讀，差超過 1pt 就說出來——與 `FrameLayout` 同一個理由：AX 設 frame
    /// 是請求，app 可以夾。label 用 window id，因為這條路上沒有規則名字。
    func place(_ frame: Rect, _ window: String) {
        guard let actual = try? server.setFrame(window: window, frame) else {
            reporter.report(.space(.frameRejected(label: window, wanted: frame, actual: nil)))
            return
        }
        if !actual.isClose(to: frame, within: FrameLayout.tolerance) {
            reporter.report(.space(.frameRejected(label: window, wanted: frame, actual: actual)))
        }
    }

    func write(state: String) {
        try? files.write(state, toPath: statePath)
    }

    private func statusOf(_ error: any Error) -> Int32 {
        guard case let ShellRunnerError.commandFailed(_, status) = error else { return 1 }
        return status
    }
}
