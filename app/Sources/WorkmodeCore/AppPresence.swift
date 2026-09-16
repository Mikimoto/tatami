/// `ensure_app`（workmode.sh:620-633）。
///
/// 輪詢的形狀與 `MinimizedWindows.restore` **相反**，這不是筆誤：這裡是**先睡再查**
/// （`sleep 1` 在 while 的第一行），所以 app 一開起來也至少等一秒；`restore_minimized`
/// 是先查再睡，deminimize 立刻生效時一次都不睡。兩邊各有一條測試釘住那個形狀，因為
/// 把它們統一成同一個樣子在畫面上看不出來，只有等待秒數會變。
public struct AppPresence {
    /// workmode.sh:7 的 `APP_WAIT_SECONDS=10`。
    public static let waitSeconds = 10

    private let apps: any AppQuery
    private let launcher: any AppLauncher
    private let clock: any Clock
    private let reporter: any Reporter

    public init(apps: any AppQuery, launcher: any AppLauncher,
                clock: any Clock, reporter: any Reporter)
    {
        self.apps = apps
        self.launcher = launcher
        self.clock = clock
        self.reporter = reporter
    }

    /// 回 false ＝ bash 的 `return 1`（`open -a` 失敗或逾時），呼叫端自行決定要不要跳過。
    @discardableResult
    public func ensure(app: String) -> Bool {
        // 已經在跑就**什麼都不印**：那是常態，連 workmode.sh:624 那句都不該出現。
        guard !apps.isRunning(app: app) else { return true }

        reporter.report(.appNotRunning(app: app))
        do {
            try launcher.open(app: app)
        } catch {
            reporter.report(.appLaunchFailed(app: app))
            return false
        }

        var waited = 0
        while waited < Self.waitSeconds {
            clock.sleep(seconds: 1)
            waited += 1
            if apps.isRunning(app: app) {
                // 帶的是**迴圈計數**（第幾次查到），不是常數：那句話宣稱等了幾秒，
                // 而它必須是真的等了幾秒。
                reporter.report(.appLaunched(app: app, waitedSeconds: waited))
                return true
            }
        }
        // 逾時那句帶的是**常數**而不是 waited。兩者在這裡剛好相等（迴圈跑滿），
        // 但 bash 內插的是 `$APP_WAIT_SECONDS`，所以照抄來源。
        reporter.report(.appLaunchTimedOut(app: app, seconds: Self.waitSeconds))
        return false
    }
}
