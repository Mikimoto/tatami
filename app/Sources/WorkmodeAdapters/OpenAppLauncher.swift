import Foundation
import WorkmodeCore

/// workmode.sh:625 的 `open -a "$app" 2>/dev/null`，外加一條給本地化名字的後備。
public struct OpenAppLauncher: AppLauncher, Sendable {
    /// `/usr/bin/open` 寫死，理由與 osascript 相同（macOS 內建，不會裝在別處）。
    static let openPath = "/usr/bin/open"
    /// Spotlight。同樣寫死。
    static let mdfindPath = "/usr/bin/mdfind"

    public init() {}

    /// 不等 app 起來：bash 也不等，`ensure_app` 的輪詢是 `open` 之後另外做的
    /// （`sleep 1` × `APP_WAIT_SECONDS`）。這裡只負責「發出開啟請求」這一件事，
    /// 輪詢屬於 Core 的編排（那正是 `Clock` 與 `AppQuery` 分開的理由）。
    ///
    /// stderr 丟掉，對齊 `2>/dev/null`——open 找不到 app 時的那句
    /// `Unable to find application named 'NoSuchApp12345'` 在 bash 那側是看不到的，
    /// 使用者看到的是腳本自己印的「! 開不起來：<app>」。
    ///
    /// **`-a` 失敗之後多試一次 Spotlight**（2026-09-07 加）：`layout.json` 的 app 名字
    /// 來自 yabai 的 `.app`，而那是**本地化名稱**——本機實測 yabai 說 `訊息`／`行事曆`
    /// 而 `open -a` 只認得 bundle 名 `Messages`／`Calendar`，於是那兩條規則的 app
    /// 每次都開不起來（`Unable to find application named '訊息'`）。
    /// `mdfind` 的 `kMDItemDisplayName` 索引的正是本地化名稱，實測兩個都查得到。
    /// 順序是 `-a` 先：它不需要 Spotlight，而 Spotlight 可以被關掉或還沒索引完。
    public func open(app: String) throws {
        if (try? runProcess(executable: Self.openPath, arguments: ["-a", app],
                            inheritStderr: false))?.status == 0
        {
            return
        }
        guard let bundle = try? Self.bundlePath(displayName: app),
              (try? runProcess(executable: Self.openPath, arguments: [bundle],
                               inheritStderr: false))?.status == 0
        else {
            throw AppLauncherError.openFailed(app: app, status: 1)
        }
    }

    /// 本地化顯示名稱 → app bundle 的路徑。查不到回 nil。
    ///
    /// 名字含 `"` 或 `\` 一律放棄：那兩個字元會讓查詢字串本身壞掉，而壞掉的查詢與
    /// 「查不到」外觀相同。mdfind 走 argv 不經過 shell，所以最壞情況只是零結果，
    /// 但一個永遠零結果的查詢不值得送出去。yabai 的 `.app` 實際不會有這種東西。
    ///
    /// 只取第一行：同一個顯示名稱可能對到多個 bundle（`/Applications` 與
    /// `~/Applications` 各一份），而這裡沒有任何資訊可以挑——`open -a` 那條路
    /// 也是 LaunchServices 自己挑一個。
    public static func bundlePath(displayName: String) throws -> String? {
        guard !displayName.contains("\""), !displayName.contains("\\") else { return nil }
        let query = "kMDItemContentType == \"com.apple.application-bundle\""
            + " && kMDItemDisplayName == \"\(displayName)\""
        let result = try runProcess(executable: mdfindPath, arguments: [query],
                                    inheritStderr: false)
        guard result.status == 0 else { return nil }
        let first = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).first
        return first.map(String.init)
    }
}
