import Foundation
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// `tatami --space`：逐螢幕把該排的 space 排成它自己的樹。
///
/// `AppPresence` 是**條件建的**——只有 `--launch` 才傳進去，其餘一律 nil
/// （`:38`，理由見 `SpaceLayout.init` 的 doc：收了就會有人用）。
///
/// **這段 doc 2026-09-14 重寫過，因為它本來掛在隔壁那支 `runSpaceSignal` 上**
/// （那支同日隨 yabai 退役了），而且裡面兩個引用早就死了：`runApplyLayout`
/// 隨 `ApplyLayout` 2026-09-07 一起刪掉、`main.swift:136` 現在只是一個 `)`。
/// 留下來的只有實際查證過的那一句。
///
/// 原本還寫過「收的 port 少四個（不 `ensure_app`、不等還原動畫）」與「這句話不進
/// 用法字串」，兩句都已經不成立：`clock` 2026-08-29 收回來、`--space` 2026-09-03
/// 進了用法字串。
func runSpaceLayout(want: String, json: Bool, launch: Bool,
                    mode: SpaceLayout.Mode, scope: SpaceLayout.Scope) -> Never
{
    // 2026-09-03 起這條路不叫 yabai：查詢、搬移、設 frame 全走 AX 加 SkyLight。
    // 同一個物件同時是 YabaiClient（查詢形狀）與 WindowServer（setFrame）。
    let engine: WindowServerClient
    do {
        engine = try WindowServerClient()
    } catch {
        if json {
            print((try? JSONEnvelope.failure(command: "space", kind: "engine_unavailable",
                                             message: "\(error)")) ?? "")
            exit(1)
        }
        fail("! \(error)", code: 1)
    }

    let paths = TatamiPaths()
    let reporter = makeReporter(json: json)
    let outcome = SpaceLayout(
        yabai: engine,
        server: engine,
        safari: SafariOsascriptClient(),
        clock: SystemClock(),
        files: FileManagerStore(),
        layoutPath: paths.layout,
        statePath: paths.state,
        parse: JSONParser.parse,
        renderRaw: rawText,
        reporter: reporter,
        // 只有 `--launch` 才建 `AppPresence`：nil 代表這一輪連 `isRunning` 都不問。
        presence: launch
            ? AppPresence(apps: RunningAppQuery(), launcher: OpenAppLauncher(),
                          clock: SystemClock(), reporter: reporter)
            : nil
    ).run(want: want, mode: mode, scope: scope)

    if json {
        // probe 與套用是兩件事，封套的消費端要分得出來（`ApplyLayout` 那側原本就是
        // `probe`／`apply` 兩個名字）。
        print(ApplyEnvelope.line(command: mode == .probe ? "probe" : "space",
                                 outcome: outcome))
    } else if case let .layoutUnavailable(failure) = outcome {
        reportLoadFailure(failure)
    }
    guard case .completed = outcome else { exit(1) }
    exit(0)
}
