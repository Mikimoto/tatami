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

/// spawn 子行程用的執行檔路徑是 `mise run install` 建的那個 symlink，**絕對路徑**。
///
/// 不是裸命令名：呼叫端（`HotkeyCommand.swift:72`、`MenuActions.swift:121`）跑在
/// `Tatami.app` 裡，而那個 app 是 login item、由 launchd 起，`PATH` 可能只剩
/// `/usr/bin:/bin:/usr/sbin:/sbin`——裸名在那裡**安靜失敗**。
/// 也不是 `Bundle.main.executablePath`——在 .app 裡那會指到 bundle 內的複製品。
///
/// 這段 doc 2026-09-15 改過：原文說的是「寫進 `yabairc` 的路徑」與「`skhdrc:164`
/// 同一個理由」，兩者都已退役（見 `TatamiPaths` 那一側的同一段）。
///
/// 同樣是 verifier 抓到的無測試項：改成裸名 `"tatami"`，918 條全綠。
@Test func theInstalledExecutableIsAnAbsolutePath() {
    let executable = TatamiPaths.installedExecutable
    #expect(executable.hasPrefix("/"), "不是絕對路徑，launchd 起的 Tatami.app 會安靜失敗")
    #expect(executable.hasSuffix("/.local/bin/tatami"))
    #expect(!executable.contains(".build"), "指到 build 產物了，重新 build 就失效")
}
