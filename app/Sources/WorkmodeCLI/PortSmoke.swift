import Foundation
import WorkmodeAdapters
import WorkmodeCore

// 其餘七個 port 的實機 smoke。存在的理由與 YabaiSmoke 相同（見那個檔的說明）：
// fake 測得到編排，測不到「Process 真的接上了、輸出真的長那樣」。
//
// 這裡的邊界比 yabai 那支更嚴，因為這些 port 碰的是使用者的注意力而不只是視窗：
//   - AppLauncher 只驗**失敗**路徑。對真的 app 呼叫 `open -a` 會搶焦點。
//   - Picker 只驗 `isAvailable`。fzf 在沒有 controlling tty 時是**無聲卡住**
//     （CLAUDE.md 記著實測：timeout 3 兩分鐘都收不掉，最後要 pkill），
//     所以 `pick` 在任何非互動環境都不能跑，包含這裡。
//   - FileStore 只碰 `/tmp` 底下自己建的路徑，絕不碰 layout.json 與狀態檔。

/// `workmode __smoke safari-dump`：把 `safari_tab_dump` 的輸出原封不動吐到 stdout。
///
/// 這支是為了逐位元組差分而存在的：
///   bash -c 'source scripts/workmode.sh; safari_tab_dump' >| /tmp/dump_bash.txt
///   workmode __smoke safari-dump                          >| /tmp/dump_swift.txt
///   cmp /tmp/dump_bash.txt /tmp/dump_swift.txt
/// 不能用 `$(...)` 比字串——那會剝掉尾端換行，而結尾有幾個換行正是待驗的東西之一。
func runSafariDumpSmoke() -> Never {
    do {
        let dump = try SafariOsascriptClient().tabDump()
        FileHandle.standardOutput.write(Data(dump.utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("FAIL safari dump：\(error)\n".utf8))
        exit(1)
    }
}

/// `workmode __smoke safari-script`：印出內嵌的 AppleScript 本體。
///
/// 差分的另一半：dump 相同可能只是「兩邊剛好都取得同一份分頁狀態」，而腳本本體
/// 相同才是「未來改動不會靜默漂移」的那個保證。對照組是
/// `awk 'NR>=585 && NR<=611' scripts/workmode.sh`。
func runSafariScriptSmoke() -> Never {
    FileHandle.standardOutput.write(Data(SafariOsascriptClient.script.utf8))
    exit(0)
}

/// `workmode __smoke app-running <名稱>`：印 true／false，與 bash 的
/// `app_running <名稱>; echo $?` 對照。
func runAppRunningSmoke(app: String) -> Never {
    print(RunningAppQuery().isRunning(app: app) ? "true" : "false")
    exit(0)
}

/// `tatami __smoke app-open <名稱>`：真的把那個 app 開起來，印走了哪一條路。
///
/// 兩條路要分得出來，不然「`open -a` 就成功了」與「後備救回來的」外觀相同，
/// 而後者才是這支存在的理由。判別法是先問 Spotlight：`open -a` 認得的名字
/// Spotlight 通常也查得到，所以印的是**路徑**而不是「走了哪一條」——路徑對得上
/// 那個本地化名字，就證明查得回來。
func runAppOpenSmoke(app: String) -> Never {
    let before = RunningAppQuery().isRunning(app: app)
    let resolved = (try? OpenAppLauncher.bundlePath(displayName: app)) ?? nil
    print("開之前在跑：\(before)")
    print("Spotlight 查到：\(resolved ?? "查不到")")
    do {
        try OpenAppLauncher().open(app: app)
        print("open 成功")
    } catch {
        print("open 失敗：\(error)")
        exit(1)
    }
    exit(0)
}

/// `tatami __smoke menu`：印出打開選單列那一刻會看到的東西。
///
/// 選單列本身沒有任何自動化驗法（`MenuController` 與 `WorkmodeEditorUI` 同一個處境），
/// 而「抬頭寫錯地點」或「profile 清單少一個」在畫面上看起來完全正常。這一支把
/// `MenuSnapshot` 的每個欄位攤出來，那是那個選單唯一有內容的部分。
@MainActor
func runMenuSmoke() -> Never {
    let snapshot = MenuSnapshot()
    print("抬頭：\(snapshot.headline)")
    // **生效地點與它的來源是這支探針存在的第二個理由。**
    // 「選單列的是偵測到那個地點的 profile，而動作用的是覆寫那個地點的鍵」在
    // 畫面上每一個字都正常，這裡是唯一看得見它的地方。
    print("生效地點：\(snapshot.location.isEmpty ? "(認不出來)" : snapshot.location)"
        + "（來源：\(snapshot.source?.rawValue ?? "無")）")
    print("目前 profile：\(snapshot.profile.isEmpty ? "(沒記住)" : snapshot.profile)")
    print("可選 profile：\(snapshot.profiles.isEmpty ? "(空的)" : snapshot.profiles.joined(separator: " "))")
    // 每個 profile 存了幾個 space 的樹——覆蓋確認框那句話的數字來源。
    //
    // **它必須看得見**：`savedSpaceCount` 走一條四段的 subscript 鏈
    // （`config[地點]["profiles"][profile]["spaceTrees"]`），任何一段寫錯都回 0，
    // 而 0 是合法值（一個還沒畫過的 profile 就是 0）——**壞掉的鏈與「真的是空的」
    // 在對話框上完全相同**，而那個對話框是它唯一的消費端。
    for profile in snapshot.profiles {
        let trees = MenuActions.savedSpaceCount(location: snapshot.location,
                                                profile: profile)
        print("  \(profile)：存了 \(trees) 個 space 的樹")
    }
    exit(0)
}

/// `workmode __smoke ports`：其餘五個 port 的一輪驗證。
func runPortSmoke() -> Never {
    var failures = 0

    func check(_ name: String, _ body: () throws -> String) {
        do {
            try print("ok   \(name)：\(body())")
        } catch {
            failures += 1
            print("FAIL \(name)：\(error)")
        }
    }

    checkPathsAndLaunching(check)
    checkTerminalClockAndFiles(check)
    checkFileStore(check)

    print(failures == 0 ? "--- smoke passed ---" : "--- \(failures) 項失敗 ---")
    exit(failures == 0 ? 0 : 1)
}

/// TatamiPaths、AppLauncher、Picker。與下面那組分開只是因為 runPortSmoke 塞不下——
/// `check` 當參數傳進來，計數仍然留在那一支的區域變數裡。
private func checkPathsAndLaunching(_ check: (String, () throws -> String) -> Void) {
    // 這一項不是 port，但它與那些 port 同一種問題：真實輸入只有在這裡才餵得到。
    // 單元測試餵給 `TatamiPaths` 的是注入的 `environment` 與 `home`，而**真的
    // `$HOME` 底下那個目錄存不存在**只能實跑一次才知道。它決定 `--save` 會覆寫
    // 哪一份 layout.json。
    //
    // **2026-09-15 起這一項的意義變了。** 在那之前解析有三段（中間那段從執行檔
    // 往上找 `scripts/layout.json`），所以這裡真正在驗的是「`Bundle.main
    // .executablePath` 實際長什麼形狀」。那一段拿掉之後只剩兩段，而兩段都不看
    // 執行檔——現在驗的是「使用者的 `~/.config/tatami/` 真的備妥了嗎」，那對一個
    // 要發出去的工具反而更重要：全新安裝的人那個目錄是空的。
    check("TatamiPaths 解到一個真的有 layout.json 的目錄") {
        let paths = TatamiPaths()
        // 斷言的是「解出來的地方真的有設定檔」，不是「等於某個寫死的路徑」——
        // 後者在 `TATAMI_DIR` 指到沙盒時就假性失敗，而一個會假性失敗的驗證工具
        // 比沒有更糟。解到**哪裡**印出來讓人看。
        guard FileManager.default.fileExists(atPath: paths.layout) else {
            throw PortSmokeFailure.message(
                "解到 \(paths.directory) 但那裡沒有 layout.json"
                    + "（TATAMI_DIR=\(ProcessInfo.processInfo.environment["TATAMI_DIR"] ?? "未設"))"
            )
        }
        return paths.directory
    }

    check("AppLauncher.open 對不存在的 app 丟 openFailed") {
        do {
            try OpenAppLauncher().open(app: "NoSuchApp12345")
            throw PortSmokeFailure.expectedThrow
        } catch let error as AppLauncherError {
            guard case let .openFailed(app, status) = error, app == "NoSuchApp12345" else {
                throw PortSmokeFailure.unexpectedShape
            }
            return "status=\(status)"
        }
    }

    check("Picker.isAvailable（不跑 pick，它會無聲卡住）") {
        let picker = FzfPicker()
        guard picker.isAvailable else { throw PortSmokeFailure.unexpectedShape }
        let missing = FzfPicker(executablePath: "/nonexistent/fzf")
        guard !missing.isAvailable else { throw PortSmokeFailure.unexpectedShape }
        return "找到了；假路徑回 false"
    }
}

/// Terminal、Clock、FileStore。
private func checkTerminalClockAndFiles(_ check: (String, () throws -> String) -> Void) {
    // 沒有 tty 時**必須**是 false：這是 --save 唯一的守衛，回錯了就會走進
    // fzf／read 那條無聲卡住的路。所以連 isatty 與 access 的原始值一起印，
    // 讓「回 false」與「為什麼 false」在同一份輸出裡對得起來。
    check("Terminal.hasControllingTTY 與它的兩個成因") {
        let terminal = DevTTYTerminal()
        let interactive = isatty(0) != 0
        let readable = access("/dev/tty", R_OK) == 0
        guard terminal.hasControllingTTY == (interactive && readable) else {
            throw PortSmokeFailure.unexpectedShape
        }
        return "hasControllingTTY=\(terminal.hasControllingTTY)"
            + "（[ -t 0 ]=\(interactive)、[ -r /dev/tty ]=\(readable)）"
    }

    check("Clock.sleep(0.1) 真的睡了") {
        let start = ContinuousClock.now
        SystemClock().sleep(seconds: 0.1)
        let elapsed = ContinuousClock.now - start
        guard elapsed >= .milliseconds(100) else { throw PortSmokeFailure.unexpectedShape }
        return "\(elapsed)"
    }
}

/// FileStore 自己一支：讀寫、覆寫、原子換上、失敗不留半份檔案，四件事都要真的
/// 碰檔案系統（只碰 /tmp），一支就把上面那組撐過長度上限。
private func checkFileStore(_ check: (String, () throws -> String) -> Void) {
    check("FileStore 讀寫與原子寫") {
        let store = FileManagerStore()
        let directory = "/tmp/workmode-smoke-\(getpid())"
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = directory + "/state"
        guard !store.exists(atPath: path), try store.read(atPath: path) == nil else {
            throw PortSmokeFailure.unexpectedShape
        }

        // 寫入的內容要**恰好**多一個結尾換行（對應 printf '%s\n'）。
        try store.write("location=home", toPath: path)
        guard store.exists(atPath: path),
              try store.read(atPath: path) == "location=home\n"
        else {
            throw PortSmokeFailure.unexpectedShape
        }

        // 覆寫不留舊內容的殘尾（noclobber 的坑在 shell 才有，這裡驗的是截斷）。
        try store.write("a=1", toPath: path)
        guard try store.read(atPath: path) == "a=1\n" else {
            throw PortSmokeFailure.unexpectedShape
        }

        let target = directory + "/layout.json"
        try store.writeAtomically("{}", toPath: target)
        guard try store.read(atPath: target) == "{}\n" else {
            throw PortSmokeFailure.unexpectedShape
        }
        // 再寫一次：目標已存在時 rename 要覆蓋而不是失敗。
        try store.writeAtomically("{\"a\":1}", toPath: target)
        guard try store.read(atPath: target) == "{\"a\":1}\n" else {
            throw PortSmokeFailure.unexpectedShape
        }

        try verifyAtomicFailurePaths(store, directory: directory, target: target)

        return "讀寫、覆寫、原子換上、失敗不留半份檔案"
    }
}

/// `writeAtomically` 的兩條失敗路徑。抽出來是為了讓上面那支回到長度上限內，
/// 而它們本來就是一組：兩條都在問「失敗之後有沒有留下半份檔案」。
private func verifyAtomicFailurePaths(_ store: FileManagerStore,
                                      directory: String, target: String) throws
{
    // 失敗路徑之一：暫存檔寫好了、`rename` 才失敗（目標是個非空目錄）。
    // 這條走的是 catch 裡的 `rm -f`，是「不留下半份檔案」真正被執行的那條路；
    // 下面那條「目錄不可寫」在建暫存檔就失敗了，驗不到清理。
    let occupied = directory + "/occupied"
    try FileManager.default.createDirectory(atPath: occupied + "/inner",
                                            withIntermediateDirectories: true)
    var renameThrew = false
    do { try store.writeAtomically("{}", toPath: occupied) } catch { renameThrew = true }
    let strays = try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasPrefix("occupied.") }
    guard renameThrew, strays.isEmpty else { throw PortSmokeFailure.unexpectedShape }

    // 失敗路徑之二：目錄不可寫。要驗的是「原檔沒有被動、也沒有留下暫存檔」。
    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: directory)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory)
    }
    var threw = false
    do { try store.writeAtomically("壞了", toPath: target) } catch { threw = true }
    guard threw, try store.read(atPath: target) == "{\"a\":1}\n" else {
        throw PortSmokeFailure.unexpectedShape
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasPrefix("layout.json.") }
    guard leftovers.isEmpty else { throw PortSmokeFailure.unexpectedShape }

    var writeThrew = false
    do { try store.write("x", toPath: directory + "/nope") } catch { writeThrew = true }
    guard writeThrew else { throw PortSmokeFailure.unexpectedShape }
}

private enum PortSmokeFailure: Error, CustomStringConvertible {
    case unexpectedShape
    case expectedThrow
    /// 帶實際值的失敗。`unexpectedShape` 只說「不符」，而一個路徑解錯時要看得到
    /// 它解到哪裡才查得出原因。
    case message(String)

    var description: String {
        switch self {
        case .unexpectedShape: "行為與預期不符"
        case .expectedThrow: "預期會 throw，但成功回傳了"
        case let .message(text): text
        }
    }
}
