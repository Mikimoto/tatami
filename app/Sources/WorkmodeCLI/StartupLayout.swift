import AppKit
import Foundation
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeWire

/// 啟動時把版面排好，取代 `yabai/yabairc` 檔尾那段手寫的 shell。
///
/// **判斷全在 `StartupApply`（Core，有測試）**，這裡只負責「用 Timer 隔 3 秒再叫
/// 一次」與「真的去跑」。那段 shell 的三件事逐一對應：`&`（不擋住 run loop）、
/// `for i in $(seq 10)`（次數）、`&& break`（第一次成功就停）。
///
/// **不擋住 run loop 是必要的**：`SpaceLayout` 是同步的，成功那一次實測 5 秒
/// （要搬視窗）。在 `application.run()` 之前跑等於選單列圖示 5 秒後才出現，
/// 而 `yabairc` 那側是靠 `&` 解決同一件事。
///
/// **每次 app 啟動都會跑一次，不只登入那一次。** 與 `yabairc` 那段的行為相同
/// （`yabai --restart-service` 會重跑整個檔案），而 `--space` 是等冪的——它把
/// frame 設成樹說的樣子，重跑一次不會累積。代價是手動重開這個 app 也會重排、
/// 也會開 app（`--launch`）。
@MainActor
final class StartupLayout {
    private var state = StartupApply()
    private var timer: Timer?

    /// 排第一次。之後由 timer 接手。
    func start() {
        // 第一次也走 timer 而不是直接跑：`start()` 是在 `application.run()`
        // 之前呼叫的，同步跑就把圖示的出現往後推 5 秒。0 秒的 timer 會在
        // run loop 起來之後的第一輪觸發。
        schedule(after: 0)
    }

    private func schedule(after delay: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.01), repeats: false) { _ in
            MainActor.assumeIsolated { self.attempt() }
        }
    }

    private func attempt() {
        guard state.shouldTry else { return }
        let reporter = TextReporter(renderer: HumanEventRenderer(), sink: StandardStreams())
        guard let engine = try? WindowServerClient() else {
            // 沒有 AX 權限就不重試：那不是等一下會好的東西（要使用者去撥開關），
            // 而每 3 秒重試一次只會把 log 灌滿。
            reporter.report(.hotkeyNoFocusedWindow)
            return
        }
        let paths = TatamiPaths()
        let outcome = SpaceLayout(
            yabai: engine, server: engine, safari: SafariOsascriptClient(),
            clock: SystemClock(), files: FileManagerStore(),
            layoutPath: paths.layout, statePath: paths.state,
            parse: JSONParser.parse, renderRaw: rawText, reporter: reporter,
            // **這條路開 app**（`--launch`），與 `yabairc` 那一行相同：登入時樹裡
            // 引用到而沒開的 app 要開起來，否則那個葉靜默排不到。
            presence: AppPresence(apps: RunningAppQuery(), launcher: OpenAppLauncher(),
                                  clock: SystemClock(), reporter: reporter)
        ).run(want: "", mode: .apply, scope: .all)
        state.record(outcome)
        if state.shouldTry {
            schedule(after: StartupApply.interval)
        }
    }
}
