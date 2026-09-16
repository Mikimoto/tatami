import Foundation

/// 讓子行程留在**父行程的 process group** 的 spawn。只有互動式的挑選器用它。
///
/// 為什麼需要這支：Foundation 的 `Process` 會把子行程放進**自己的** process group
/// （實測 2026-08-17：父 pgid=21557，`Process` 生的子行程 pid=21579 pgid=21579；
/// 同一台機器上 bash fork/exec 的子行程 pgid 與父行程相同）。那個新 group 不是終端機
/// 的前景 group，所以子行程一讀 `/dev/tty` 就收到 **SIGTTIN 被停住**——對 fzf 來說
/// 就是畫面完全不出現、整個命令卡住要 Ctrl-C。
///
/// 這個症狀騙人的地方在於它與「fzf 沒有 tty」一模一樣（都是無聲卡住），而且
/// **有 tty 也一樣會發生**：實測在 `script` 底下錄，bash 版錄到 11400 bytes 的
/// 選單畫面，Swift 版錄到 12 bytes——全是使用者自己按的鍵。
///
/// `posix_spawn` 不帶 `POSIX_SPAWN_SETPGROUP` 時，子行程繼承父行程的 group，也就是
/// 終端機的前景 group，與 shell 的行為相同（實測子 pgid == 父 pgid）。
///
/// **只有挑選器走這條。** 其餘的子行程（yabai、osascript、open）不碰 tty，
/// Foundation 的 `Process` 對它們沒有問題，換過來只會多一份要維護的 C interop。
///
/// **沒有任何自動化測試驗得到 fzf 這一端**：沒有 tty 時 fzf 無聲卡住，pty driver
/// 也驅動不起來它（實測改前改後都畫不出東西）。能驗的只有機制本身——
/// `ForegroundSpawnTests` 拿 `ps` 當子行程斷言 pgid 相同——以及人在真的終端機
/// 跑一次 `workmode --switch` 看選單出不出來。
struct SpawnFailed: Error, CustomStringConvertible {
    let executable: String
    let code: Int32
    var description: String {
        "spawn \(executable) 失敗（errno=\(code)）"
    }
}

struct ForegroundSpawnResult {
    let status: Int32
    let stdout: Data
}

/// stdin 餵 `input`、stdout 收回來、**stderr 原封不動繼承**（fzf 的畫面畫在 stderr 上，
/// 擋掉等於選單不見）。
///
/// 先寫完 stdin 再讀 stdout 是安全的，理由與 `runProcess` 那邊相同：餵進去的是十來行
/// 的選單，而挑選器在使用者選定之前不會吐出任何東西，塞不爆 64KB 的管線緩衝。
/// 哪天有呼叫端要餵大量資料，這裡要先改成邊寫邊讀。
func spawnInForegroundGroup(
    executable: String,
    arguments: [String],
    stdin input: Data
) throws -> ForegroundSpawnResult {
    var toChild: [Int32] = [-1, -1]
    var fromChild: [Int32] = [-1, -1]
    guard pipe(&toChild) == 0 else { throw SpawnFailed(executable: executable, code: errno) }
    guard pipe(&fromChild) == 0 else {
        close(toChild[0]); close(toChild[1])
        throw SpawnFailed(executable: executable, code: errno)
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // 0 ← 管線讀端、1 → 管線寫端。2 不動：繼承父行程的 stderr。
    posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
    posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
    // 子行程不需要另外那兩端；留著會讓 EOF 永遠等不到。
    posix_spawn_file_actions_addclose(&actions, toChild[1])
    posix_spawn_file_actions_addclose(&actions, fromChild[0])

    // attr 全部留預設——**關鍵就是不設 POSIX_SPAWN_SETPGROUP**。
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }

    let argv: [UnsafeMutablePointer<CChar>?] =
        ([executable] + arguments).map { strdup($0) } + [nil]
    defer { for pointer in argv where pointer != nil {
        free(pointer)
    } }

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
    close(toChild[0])
    close(fromChild[1])
    guard spawned == 0 else {
        close(toChild[1]); close(fromChild[0])
        throw SpawnFailed(executable: executable, code: spawned)
    }

    write(input, to: toChild[1])
    let collected = drain(fromChild[0])

    var raw: Int32 = 0
    while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
    // 與 Process.terminationStatus 對齊：正常結束回 exit code，被訊號殺掉回 128+訊號。
    let status = (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
    return ForegroundSpawnResult(status: Int32(status), stdout: collected)
}

/// 把 stdin 餵完再關掉寫端。子行程要看到 EOF 才會開始輸出。
private func write(_ input: Data, to descriptor: Int32) {
    input.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(descriptor, raw.baseAddress!.advanced(by: offset),
                                raw.count - offset)
            // 對方提早收工（使用者按 ESC）會拿到 EPIPE，那不是錯誤，停下就好。
            if written <= 0 {
                break
            }
            offset += written
        }
    }
    close(descriptor)
}

/// 讀到 EOF 為止再關掉讀端。
private func drain(_ descriptor: Int32) -> Data {
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let got = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, 4096) }
        if got <= 0 {
            break
        }
        collected.append(contentsOf: buffer[0 ..< got])
    }
    close(descriptor)
    return collected
}
