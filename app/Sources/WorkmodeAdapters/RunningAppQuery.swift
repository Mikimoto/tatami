import AppKit
import WorkmodeCore

/// 「這個 app 在跑嗎」。取代原本的 `osascript -e 'application "X" is running'`。
///
/// **換掉的理由是原本那支對本地化名稱一律回 false**（2026-09-07 實測）。
/// `layout.json` 的 app 名字來自 yabai 的 `.app`，而那是本地化名稱；System Events
/// 認的是 bundle 名，兩邊逐字不同——本機十個執行中的 app 裡有五個對不上
/// （`訊息`／`行事曆`／`郵件`／`備忘錄`／`密碼`），而 `zed`／`ghostty` 連大小寫都不同。
/// 後果是 `--launch` 對這些 app 每次都判「沒在跑」、去 `open` 一次、再失敗。
///
/// `NSRunningApplication.localizedName` 與 yabai 的 `.app` **逐字相同**（實測當下
/// 七個 app 全對）——兩邊讀的都是那個 bundle 自己的本地化名稱，而不是呼叫端的語系，
/// 所以 tatami 自己沒有本地化資源也拿得到中文名字。
///
/// 副作用是這條路上 **`tatami <profile>`（`ApplyLayout`）也一起改了**，那是好事：
/// 同一個 bug 在那裡也存在。bash 沒有任何 golden 語料涵蓋 `app_running`
/// （`__diff` 沒有這個子命令），所以這個分歧不動任何期望值。
public struct RunningAppQuery: AppQuery, Sendable {
    public init() {}

    /// 比對兩種名字：本地化名稱（yabai 給的那個），以及 bundle 的檔名去掉 `.app`
    /// （手寫設定比較可能打成 `Messages`）。兩者任一相符就算在跑。
    ///
    /// 只看 `.regular`：那是有 Dock 圖示、開得出視窗的 app，也就是版面唯一在乎的
    /// 那種。背景 daemon 撞名時回 true 會讓 `--launch` 跳過真正該開的那個。
    public func isRunning(app: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { running in
            guard running.activationPolicy == .regular else { return false }
            if running.localizedName == app {
                return true
            }
            return running.bundleURL?.deletingPathExtension().lastPathComponent == app
        }
    }
}
