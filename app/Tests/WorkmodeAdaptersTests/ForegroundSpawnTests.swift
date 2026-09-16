import Foundation
import Testing
@testable import WorkmodeAdapters

// fzf 那一端**沒有任何自動化測試驗得到**（沒有 tty 時它無聲卡住，pty driver 也驅動
// 不起來）。所以這裡驗的是這支 spawn 存在的**機制**：子行程留在父行程的 process
// group。那正是 fzf 能不能讀 `/dev/tty` 的分water嶺。
//
// 選單本身仍然只能靠人跑一次 `workmode --switch` 確認。

private func childProcessGroup(spawner: (String, [String]) throws -> String) rethrows -> String {
    // `ps -o pgid= -p $$` 印子行程自己的 process group，沒有標題列。
    try spawner("/bin/bash", ["-c", "ps -o pgid= -p $$"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func theChildStaysInOurProcessGroup() throws {
    let group = try childProcessGroup { executable, arguments in
        let result = try spawnInForegroundGroup(executable: executable,
                                                arguments: arguments,
                                                stdin: Data())
        return String(decoding: result.stdout, as: UTF8.self)
    }
    #expect(!group.isEmpty, "沒讀到 pgid——spawn 或管線壞了，這條測試等於沒跑")
    #expect(group == String(getpgrp()),
            "子行程的 process group 是 \(group)，父行程是 \(getpgrp())：不同組就會被 SIGTTIN 停住")
}

/// 反向對照組：Foundation 的 `Process` **必須**跟上面得到不同的答案。
///
/// 這條不是在測 Foundation，是在確認「這支 spawn 還有存在的理由」。哪天它紅了，
/// 代表 Foundation 不再另開 group，那時該做的是刪掉 ForegroundSpawn.swift 而不是
/// 改這條測試——所以訊息要說得夠清楚。
///
/// 沒有這條的話，上面那條在「兩種 spawn 行為其實相同」的世界裡照樣會過，
/// 而那個世界裡整個 workaround 是多餘的複雜度。
@Test func foundationsProcessIsWhyThisFileExists() throws {
    let ours = try childProcessGroup { executable, arguments in
        let result = try spawnInForegroundGroup(executable: executable,
                                                arguments: arguments,
                                                stdin: Data())
        return String(decoding: result.stdout, as: UTF8.self)
    }
    let theirs = try childProcessGroup { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    #expect(!ours.isEmpty && !theirs.isEmpty, "有一邊沒讀到 pgid，這條測試等於沒跑")
    #expect(ours != theirs,
            "Foundation 的 Process 不再另開 process group（兩邊都是 \(ours)）——那 ForegroundSpawn.swift 已經沒有存在理由，該刪掉它而不是改這條測試")
}

@Test func stdinReachesTheChildAndStdoutComesBack() throws {
    let result = try spawnInForegroundGroup(executable: "/bin/cat", arguments: [],
                                            stdin: Data("一二三\n".utf8))
    #expect(String(decoding: result.stdout, as: UTF8.self) == "一二三\n")
    #expect(result.status == 0)
}

/// 使用者按 ESC 時 fzf 回非零，呼叫端靠它判斷「取消」，所以 exit code 必須是真的。
@Test func theExitStatusIsTheChildsOwn() throws {
    let result = try spawnInForegroundGroup(executable: "/bin/bash",
                                            arguments: ["-c", "exit 3"],
                                            stdin: Data())
    #expect(result.status == 3)
}
