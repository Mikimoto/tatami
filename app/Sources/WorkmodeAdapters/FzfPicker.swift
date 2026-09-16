import Foundation
import WorkmodeCore

/// workmode.sh:1031、1052 的兩段式選單。
public struct FzfPicker: Picker, Sendable {
    public static let homebrewPath = "/opt/homebrew/bin/fzf"

    private let executablePath: String?

    /// 找不到 fzf **不 throw**，記成 nil 讓 `isAvailable` 回 false。
    ///
    /// bash 那側是 `command -v fzf >/dev/null 2>&1 || { 印提示; return 1; }`——
    /// 缺席是一條正常的降級路徑（改用 `--switch 地點/profile`），不是錯誤。
    /// 建構子 throw 會逼 CLI 在還不知道使用者要不要互動之前就先失敗。
    public init() {
        executablePath = try? locateExecutable(name: "fzf", homebrew: Self.homebrewPath)
    }

    /// 測試與非標準安裝路徑用。
    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    /// workmode.sh:1016 的 `command -v fzf`。
    ///
    /// 每次問都重新檢查那個路徑**現在**是不是可執行檔，而不是只看建構時找到了沒有：
    /// `command -v` 檢查的就是這件事，而 `init(executablePath:)` 那條路徑完全沒經過
    /// 尋找，若只看 nil 就會對一個不存在的路徑回 true——那是把「我指定了路徑」
    /// 誤讀成「fzf 在那裡」。
    public var isAvailable: Bool {
        guard let executablePath else { return false }
        return FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// 旗標與 bash 完全相同。三件事不要「順手改好」：
    ///
    /// 1. `--delimiter=\t` 傳的是**反斜線與 t 兩個字元**，不是一個 tab。bash 寫的是
    ///    `--delimiter='\t'`（單引號，不展開），而 fzf 把 delimiter 當 regex 解，
    ///    所以那兩個字元才是對的；傳真的 tab 是另一種行為。
    /// 2. 選單內容從 stdin 餵，而 stdin **一定是管線**——但 fzf 的按鍵是從
    ///    controlling tty 讀的，所以互動不受影響。這也是為什麼沒有 tty 時它
    ///    無聲卡住而不是失敗（CLAUDE.md 記著實測：timeout 3 兩分鐘都收不掉），
    ///    因此呼叫端必須先問 `Terminal.hasControllingTTY`。
    /// 3. stderr 不擋：fzf 的整個畫面是畫在 stderr 上的，擋掉等於選單不見。
    ///
    /// 回 nil 是使用者取消（fzf rc≠0，bash 是 `|| return 1`）。
    /// 回的是整行原文（含 tab），呼叫端自己取第一欄——bash 就是 `| cut -f1`。
    public func pick(_ lines: [String], prompt: String) throws -> String? {
        guard let executablePath else {
            throw ExecutableNotFound(name: "fzf", searchedPaths: [Self.homebrewPath])
        }
        // 每行一個換行，包含最後一行：bash 那側餵進去的是 jq 的串流輸出加一行
        // `printf 'auto\t…\n'`，兩者都以換行結尾。
        let input = lines.map { $0 + "\n" }.joined()
        // 不能用 runProcess：Foundation 的 Process 會把子行程放進自己的 process
        // group，fzf 讀 /dev/tty 就被 SIGTTIN 停住，畫面完全不出現（理由與實測數字
        // 見 ForegroundSpawn.swift）。這是全 repo 唯一需要前景 group 的子行程。
        let result = try spawnInForegroundGroup(
            executable: executablePath,
            arguments: ["--delimiter=\\t", "--with-nth=1,2", "--prompt=\(prompt)",
                        "--height=40%", "--reverse"],
            stdin: Data(input.utf8)
        )
        guard result.status == 0 else { return nil }
        var text = String(decoding: result.stdout, as: UTF8.self)
        // `pick_loc=$(… | fzf …)` 剝掉全部尾端換行。
        while text.hasSuffix("\n") {
            text.removeLast()
        }
        return text
    }
}
