import AppKit
import ServiceManagement
import WorkmodeAdapters
import WorkmodeCore
import WorkmodeDomain

/// 常駐的選單列 app 自己聽 space 切換，不經過 yabai 的 `space_changed` signal。
///
/// **這是「tatami 不依賴 yabai 才活得下來」的最後一塊。** 事件來源是
/// `NSWorkspace.activeSpaceDidChangeNotification`——實測（2026-09-08）連續切四次
/// 四次都到，延遲在切換完成之後。它沒有 payload（不說切到哪個 space），
/// 但這條路本來就不需要知道：`--space` 自己會去問現在可見的是哪一個。
///
/// **要不要聽由 `SpaceWatchDecision` 決定**（Core，有測試）：那是狀態檔裡的
/// `autospace` 開關，預設關。
@MainActor
final class SpaceWatch {
    /// 停多久才算「使用者停下來了」。
    ///
    /// **debounce 是 trailing 不是 leading**：連刷四格時要排的是**最後停下來的
    /// 那一格**。leading（第一次就做、之後 N 秒忽略）會排到中間某一格，而使用者
    /// 看到的是「我停在 C，它排成 B」。
    ///
    /// **0.5 秒是折衷，不是「夠用」**：每一次切換都要付這個延遲。2026-08-23 掛在
    /// yabai 的 `space_changed` 上的一個探針量到連續滑動會爆發（4 筆／4.8 秒，
    /// 最短間隔 0.669 秒），所以 0.5 秒的窗口**擋不掉那一次**——它擋的是比那更快
    /// 的滑動。拉長到 1 秒能多擋一格，代價是單次切換也慢一秒。
    /// （**那份原始紀錄不存在了**：它寫在 `/tmp`，不跨重開機。數字保留是因為結論
    /// 仍然成立，但不可複驗；要再確認就重掛一次探針。）
    ///
    /// 這個值 2026-09-14 之前住在 `SpaceSignal.defaultSettle`——那支是 yabai 的
    /// signal 那條路的守門員，隨 yabai 一起退役了。這裡用計時器而不是那支的檔案
    /// token：signal 每次都是一個新行程、彼此只能靠檔案溝通，而這裡是同一個行程。
    private static let settle = 0.5

    private var pending: Timer?
    private let paths = TatamiPaths()

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` 保證這個 block 在 main thread 上跑，但編譯器看不出來
            // ——它只看得到一個 nonisolated 的閉包在叫 `@MainActor` 的方法。
            // `assumeIsolated` 是把那個保證講給它聽，前提條件由上面那個參數建立；
            // 同一支下面那個 `Timer` callback 用的就是這一招。
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    /// 每次事件都把計時器往後推——最後一次事件之後 `settle` 秒才真的排。
    private func spaceChanged() {
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: Self.settle, repeats: false) { _ in
            MainActor.assumeIsolated { self.applyIfOwned() }
        }
    }

    /// **每一次都重新問一遍**，不在啟動時決定一次。
    ///
    /// 使用者會在 app 跑著的時候撥開關，而快取那個答案的症狀是「我明明關掉了
    /// 它還在排」——那與「壞了」分不出來。代價是每次切 space 讀一個小檔案。
    private func applyIfOwned() {
        let state = (try? FileManagerStore().read(atPath: paths.state)) ?? ""
        switch SpaceWatchDecision.decide(state: state) {
        case .observe:
            // `.visible`：切到某個 space 就只排那一個。`--all` 在這裡是錯的——
            // 刷過去的時候把十個 space 全部重排，使用者只是想看一眼。
            MenuActions.applySpaces(scope: .visible)
        case .disabled:
            break
        }
    }
}

/// 登入時自動啟動。
///
/// `SMAppService.mainApp` 而不是 `yabairc` 那一行：那一行讓 tatami 只有在 yabai
/// 起得來的時候才活得了。這一支登記的是**這個 .app 自己**，由 launchd 起——
/// 而它拿得到 AX 權限的前提是 Developer ID 的簽章（bundle id ＋ team id 的
/// designated requirement 不含 cdhash，所以授權撐得過重建；2026-09-08 實測
/// cdhash 從 `fc5ff4c1…` 換成 `c99b0bf4…` 之後照樣有權限）。
///
/// **只有在 .app 裡才有意義**：裸的 CLI 沒有 bundle，`mainApp` 對它會失敗。
@MainActor
enum LoginItem {
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 回訊息不回 Bool：三種結果（開了、關了、失敗）要說的話不一樣，而選單列
    /// 沒有地方顯示對話框，只能把話寫進 log。
    static func toggle() -> String {
        do {
            if isRegistered {
                try SMAppService.mainApp.unregister()
                return "登入自動啟動：已關閉"
            }
            try SMAppService.mainApp.register()
            return "登入自動啟動：已開啟"
        } catch {
            return "登入自動啟動：改不動（\(error)）"
        }
    }
}
