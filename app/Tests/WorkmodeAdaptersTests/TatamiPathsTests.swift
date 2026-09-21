import Darwin
import Foundation
import Testing
import WorkmodeAdapters

// 設定檔的位置是唯一會讓程式去讀「別人的設定」的地方，所以它怎麼決定必須自己有斷言。
//
// 2026-09-15 起只有兩段：`TATAMI_DIR` → `~/.config/tatami`。在那之前還有中間一段
// 「從執行檔往上找 `scripts/layout.json`」，存在的理由是「scratch checkout 跑
// `--save` 不要寫進使用者正在用的設定」。設定搬出 repo 之後那一段永遠找不到東西、
// 會靜默落到第二段——也就是它本來要防的事——所以拿掉了。要沙盒就明寫 `TATAMI_DIR`。

/// 沒有覆寫就用 `~/.config/tatami`，**扁平**（不再有 `scripts/` 那一層）。
@Test func defaultsToTheConfigDirectoryUnderHome() {
    let paths = TatamiPaths(environment: [:], home: "/Users/x")

    #expect(paths.directory == "/Users/x/.config/tatami")
    #expect(paths.layout == "/Users/x/.config/tatami/layout.json")
    #expect(paths.state == "/Users/x/.config/tatami/.tatami-state")
    #expect(paths.hotkeys == "/Users/x/.config/tatami/hotkeys.json")
}

@Test func honoursTheTatamiDirOverride() {
    let paths = TatamiPaths(environment: ["TATAMI_DIR": "/tmp/wm"], home: "/Users/x")

    #expect(paths.directory == "/tmp/wm")
    #expect(paths.layout == "/tmp/wm/layout.json")
    #expect(paths.state == "/tmp/wm/.tatami-state")
}

/// 舊名字要撐過一個版本：使用者的 shell 設定與 CLAUDE.md 的範例都還寫著它。
@Test func theOldEnvironmentNameStillOverrides() {
    let paths = TatamiPaths(environment: ["WORKMODE_DIR": "/tmp/old"], home: "/Users/x")

    #expect(paths.directory == "/tmp/old")
}

/// 空字串當成沒設：`TATAMI_DIR=` 是「取消覆寫」而不是「用根目錄」。
@Test func treatsAnEmptyOverrideAsUnset() {
    let paths = TatamiPaths(environment: ["TATAMI_DIR": ""], home: "/Users/x")

    #expect(paths.directory == "/Users/x/.config/tatami")
}

// MARK: - 執行檔路徑

/// spawn 出去的必須**就是正在跑的這個執行檔**。
///
/// 這條是 2026-09-21 那個缺陷的迴歸守衛。0.1.0 把它寫死成
/// `~/.local/bin/tatami`（`mise run install` 建的開發用 symlink），而用 Homebrew
/// 裝的人那個檔不存在——選單列的「格線」與「編輯設定」、以及 ⌃⌥⌘G 三個入口
/// 對他們全部無效，且 `try? process.run()` 讓它連 log 都不留。
///
/// **當時有一條測試守著這個值，而它把缺陷寫成了期望值**（斷言
/// `hasSuffix("/.local/bin/tatami")`）——一條釘住寫死路徑的測試，在那個路徑錯掉
/// 時只會更用力地保護它。
///
/// **這一條的第一版也是假守衛**：它斷言「那個檔存在且可執行」，而修這個缺陷的
/// 人（為了讓自己的機器先能用）剛好把那條 symlink 建了回來，於是把實作退回
/// 0.1.0 那行**測試照樣綠**。實測 0 個 issue。教訓是「檔案存在」這個量在開發者
/// 的機器上幾乎恆真，它分不出「正確的路徑」與「碰巧也存在的另一條路徑」。
///
/// 所以 oracle 換成 `proc_pidpath`——**與 `Bundle` 無關的第二個來源**，直接問
/// 核心「這個 pid 的執行檔是哪個」。兩者 resolve symlink 之後必須相同。
/// 實測三種情境（裸執行檔、bundle 內、經 symlink 叫 bundle 內那份）resolve 後
/// 都一致，而第三種正是 cask 的形狀：`Bundle` 回 symlink、`proc_pidpath` 回本體。
///
/// 仍然斷言絕對路徑：這個 app 由 launchd 起，`PATH` 可能只剩
/// `/usr/bin:/bin:/usr/sbin:/sbin`，裸命令名在那裡安靜失敗。
@Test func theSpawnTargetIsTheExecutableWeAreRunning() throws {
    let executable = try #require(TatamiPaths.runningExecutable,
                                  "拿不到自己的執行檔路徑，三個 spawn 入口都會死")
    #expect(executable.hasPrefix("/"), "不是絕對路徑，launchd 起的 Tatami.app 會安靜失敗")

    var buffer = [CChar](repeating: 0, count: 4096)
    let written = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
    try #require(written > 0, "proc_pidpath 問不到自己的執行檔，這條 oracle 失效")
    let fromKernel = String(cString: buffer)

    let resolve = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    #expect(resolve(executable) == resolve(fromKernel),
            "spawn 的是 \(executable)，而正在跑的是 \(fromKernel)，指到別的地方就是 0.1.0 那個缺陷")
}
