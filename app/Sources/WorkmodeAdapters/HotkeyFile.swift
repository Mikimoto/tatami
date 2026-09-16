import WorkmodeCore
import WorkmodeDomain
import WorkmodeWire

/// `hotkeys.json` 的讀寫。
///
/// 解析與寫回走 Wire 的 `JSONParser`／`JSONWriter`（不是 `JSONSerialization`）：
/// 與 `layout.json` 同一條理由——保住鍵序與數字字面值，於是使用者手改過的檔案
/// 存回去只會有他改的那幾行的 diff。
public enum HotkeyFile {
    /// 讀。檔案不存在就回內建的預設並說一聲——不存在是**常態**（第一次跑，
    /// 或使用者剛從 skhd 搬過來），把它當錯誤會讓所有快捷鍵在第一次啟動時失效。
    public static func load(from path: String, files: any FileStore,
                            reporter: any Reporter) -> HotkeyDocument
    {
        guard let text = ((try? files.read(atPath: path)) ?? nil), !text.isEmpty else {
            return HotkeyDocument.defaults
        }
        guard let json = try? JSONParser.parse(text) else {
            reporter.report(.hotkeyBindingRejected(detail: "hotkeys.json 不是合法的 JSON，這一輪用內建的預設值"))
            return HotkeyDocument.defaults
        }
        let (document, problems) = HotkeyBindings.read(json)
        for problem in problems {
            reporter.report(.hotkeyBindingRejected(detail: "hotkeys.json \(problem)"))
        }
        // 問的是 `registrableBindings` 而不是 `bindings`：**要送去註冊的就是那一份**，
        // 而 zone 的鍵與某條綁定撞了的時候，後來那個會被 `RegisterEventHotKey` 安靜地
        // 拒絕。只問 `bindings` 的話那個撞鍵一個字都不會印，使用者只從
        // `hotkeysRegistered` 的 `skipped` 看到一個數字——症狀是「我明明設了這個
        // zone，按下去卻沒反應」。`GridZone.registrableBindings` 的 doc 一直宣稱
        // 這件事自動被抓到，而在這一行改掉之前那句話是假的。
        for key in HotkeyBindings.conflicts(in: document.registrableBindings) {
            reporter.report(.hotkeyConflict(key: key.description))
        }
        return document
    }

    /// **可以安全覆寫**的那一份，看不懂就 nil。
    ///
    /// `load` 分不出四種狀態（它對前三種都回 `defaults`），而覆寫那條路必須分得出：
    ///
    /// | 檔案 | 這裡回 | 為什麼 |
    /// |---|---|---|
    /// | 不存在 | `defaults` | 常態：第一次跑，或剛從 skhd 搬過來 |
    /// | 空的 | `defaults` | 同上 |
    /// | parse 不過 | `nil` | 使用者只是打錯一個逗號 |
    /// | parse 得過但不是 hotkeys 文件 | `nil` | 同上，只是打錯的是鍵名 |
    ///
    /// 第四種是 2026-09-09 抓到的資料遺失缺陷：`bindings` 打成 `binding`（或最外層
    /// 是個陣列）時 `HotkeyBindings.read` 回的是一份**空文件加一句 problem** 而不是
    /// 失敗，於是「格線」那一頁 `canSave` 為真、`save()` 回 `.written`，使用者的 45 條
    /// 綁定、29 個 float app 與 mouse 設定就在他動一下 stepper 的那一刻從檔案上消失。
    /// 前兩種**必須仍然回非 nil**：一起擋掉等於讓第一次使用的人永遠存不出第一份檔。
    ///
    /// **住在這一層而不是 CLI**：這是一個 yes/no 的判斷，而 CLI 是 executable target、
    /// 零測試——它原本就在那裡，代價是那道守衛只靠測試裡的一份副本活著，把產品那支
    /// 改成一律回 `defaults`（正是要防的危害）整套測試零 issue。這裡有 `FileStore` port
    /// 與 fake，所以四種狀態各自釘得住。
    ///
    /// 不走 `load`：那一支要一個 `Reporter`，而這裡只問一個 yes/no。壞掉的**單一條目**
    /// 照舊由 `HotkeyBindings.read` 跳過——那不是「看不懂」，那是「少一條」。
    public static func readable(from path: String, files: any FileStore) -> HotkeyDocument? {
        guard let text = ((try? files.read(atPath: path)) ?? nil), !text.isEmpty else {
            return HotkeyDocument.defaults
        }
        guard let json = try? JSONParser.parse(text), HotkeyBindings.isDocument(json)
        else { return nil }
        return HotkeyBindings.read(json).document
    }

    /// 寫。原子寫——與 `layout.json` 同級，中途失敗不會留下半份設定。
    public static func save(_ document: HotkeyDocument, to path: String,
                            files: any FileStore) throws
    {
        try files.writeAtomically(JSONWriter.format(HotkeyBindings.write(document)), toPath: path)
    }
}
