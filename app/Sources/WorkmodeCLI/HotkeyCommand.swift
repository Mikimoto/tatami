import Foundation
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// 一個快捷鍵動作要怎麼跑。
///
/// **`applyLayout` 與 `showGrid` 在這裡分岔**，不進 `WindowActions`：前者是
/// `SpaceLayout` 整支（它要 layout.json、Safari dump、AppPresence，與「對焦點視窗
/// 動手」是完全不同的一件事），後者要另一個行程（`grid` 要 `.regular` 的
/// activation policy 才收得到 Esc，而選單列這個行程是 `.accessory`；
/// 一個行程一種身分比在 runtime 切來切去可靠——與選單列對 `grid`／`edit`
/// 同一個決定）。
enum HotkeyRuntime {
    /// 在**這個行程裡**跑。選單列 app 收到按鍵時走這條。
    ///
    /// `applyLayout` 也在行程內跑（與選單的「重排目前可見」同一條），只有 `grid`
    /// 一定要 spawn 出去。
    static func perform(_ action: HotkeyAction, floatApps: [String],
                        grids: [String: GridConfig], reporter: any Reporter)
    {
        switch action {
        case let .applyLayout(all):
            runLayoutInProcess(all: all, reporter: reporter)
        case .showGrid:
            spawnGrid()
        default:
            guard let actions = makeActions(floatApps: floatApps, grids: grids,
                                            reporter: reporter)
            else {
                reporter.report(.hotkeyNoFocusedWindow)
                return
            }
            actions.run(action)
        }
    }

    /// 五個 port 接起來。引擎建不起來（沒有 AX 權限）就回 nil——呼叫端把它報成
    /// 「沒有焦點視窗」，那是使用者在畫面上看得到的同一件事。
    ///
    /// `floatApps` 由呼叫端在**啟動時**讀一次傳進來，不在這裡每次按鍵重讀：
    /// 重讀會讓 `HotkeyFile.load` 的 problems 與 conflicts 每按一鍵重印一次，
    /// 而「改完設定要重開」本來就是綁定那半的規矩，清單跟著同一條比較不意外。
    static func makeActions(floatApps: [String], grids: [String: GridConfig],
                            reporter: any Reporter) -> WindowActions?
    {
        guard let engine = try? WindowServerClient() else { return nil }
        let paths = TatamiPaths()
        return WindowActions(yabai: engine, server: engine, control: engine,
                             shell: ShellCommandRunner(), files: FileManagerStore(),
                             statePath: paths.state, reporter: reporter,
                             floatApps: floatApps, grids: grids)
    }

    private static func runLayoutInProcess(all: Bool, reporter: any Reporter) {
        guard let engine = try? WindowServerClient() else { return }
        let paths = TatamiPaths()
        _ = SpaceLayout(
            yabai: engine, server: engine, safari: SafariOsascriptClient(),
            clock: SystemClock(), files: FileManagerStore(),
            layoutPath: paths.layout, statePath: paths.state,
            parse: JSONParser.parse, renderRaw: rawText, reporter: reporter,
            // 快捷鍵那條路不開 app，與 `__space-signal`、編輯器 ⌘R 同一個立場：
            // 要開就明確打 `tatami --space --launch`。
            presence: nil
        ).run(want: "", mode: .apply, scope: all ? .all : .visible)
    }

    private static func spawnGrid() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TatamiPaths.installedExecutable)
        process.arguments = ["grid"]
        try? process.run()
    }
}

/// `tatami __hotkey <action>`：跑一個動作再結束（隱藏子命令，`__diff`／`__smoke`
/// 的先例，不進 usage）。
///
/// 兩個用途。**驗**：這 45 個動作沒有別的辦法從終端機各按一次
/// （`WindowActions` 的測試用 fake，證明不了 AX 那半真的動得了）。**過渡**：
/// 還沒把 `skhdrc` 拔掉之前，那邊可以先改成叫這一支，一條一條搬。
func runHotkeyAction(_ text: String, json: Bool) -> Never {
    let reporter = makeReporter(json: json)
    guard let action = HotkeyAction.parse(text) else {
        reporter.report(.hotkeyBindingRejected(detail: "認不得動作「\(text)」"))
        if json {
            print((try? JSONEnvelope.failure(command: "hotkey", kind: "unknown_action",
                                             message: "認不得動作「\(text)」")) ?? "")
        }
        exit(1)
    }
    let paths = TatamiPaths()
    let document = HotkeyFile.load(from: paths.hotkeys, files: FileManagerStore(),
                                   reporter: reporter)
    HotkeyRuntime.perform(action, floatApps: document.floatApps, grids: document.grids,
                          reporter: reporter)
    if json {
        print((try? JSONEnvelope.success(command: "hotkey", data: ["action": action.text]))
            ?? "")
    }
    exit(0)
}
