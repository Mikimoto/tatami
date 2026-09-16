import Foundation
import WorkmodeCore

/// `layout.json`（workmode.sh:108-113）與狀態檔（548-551、1000）的讀寫。
public struct FileManagerStore: FileStore, Sendable {
    public init() {}

    /// `[ -f "$FILE" ]`：**普通檔案**才算，目錄不算。
    /// `FileManager.fileExists(atPath:)` 對目錄回 true，直接用就會讓
    /// 「有一個叫 layout.json 的目錄」被當成設定檔存在，接著讀取失敗在別的地方爆。
    /// 兩者都跟隨 symlink（`[ -f ]` 也是），這點不必另外處理。
    public func exists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    /// 對應 `cat`。不存在回 nil（呼叫端自己決定那是錯誤還是空字串），
    /// 存在但讀不動（權限、是目錄）才 throw——bash 那側 `cat` 會印錯誤並讓
    /// `json` 變成空字串，之後 `validate_layout` 擋下來；這裡讓它成為明確的錯誤。
    public func read(atPath path: String) throws -> String? {
        guard exists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw FileStoreError.readFailed(path: path)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 對應 `printf '%s\n' "$state" >| "$STATE_FILE"`：**這裡補上那個結尾換行**。
    ///
    /// 換行補在 Adapter 而不是讓 Core 自己加，是為了讓兩個方法的語意一致：
    /// bash 的另一個寫入點（writeAtomically）也是 `printf '%s\n' … | jq .`，
    /// 而 jq 的輸出同樣以一個換行結束。也就是說 bash 兩處寫出的檔案都恰好以一個
    /// 換行結尾，而 `JSONWriter.format` 與 `StateFile.set` 之外的字串都不帶它。
    /// 所以這兩個方法的合約是「寫入這些**行**」，呼叫端傳的內容**不要**自帶結尾換行。
    ///
    /// `noclobber` 不必模擬：那是 shell 的 redirect 行為，bash 用 `>|` 明確要求覆寫。
    public func write(_ contents: String, toPath path: String) throws {
        let data = Data((contents + "\n").utf8)
        guard FileManager.default.createFile(atPath: path, contents: data) else {
            throw FileStoreError.writeFailed(path: path)
        }
    }

    /// workmode.sh:1246-1252：`mktemp "${LAYOUT_FILE}.XXXXXX"` → 寫 → `mv -f`。
    ///
    /// 那段註解本身就是這個方法存在的理由（中途失敗不會留下半份設定），所以
    /// **失敗一律不留下暫存檔**，也絕不先截斷目標檔案：暫存檔與目標同一個目錄
    /// （同一個檔案系統）才能靠 `rename` 原子換上去，寫到 `/tmp` 再搬會退化成
    /// 「複製」，那就有半份檔案的窗口了。
    ///
    /// 用 `rename(2)` 而不是 `FileManager.moveItem`：後者要求目標不存在，
    /// 而這裡的目標永遠存在（就是要覆蓋它）。`mv -f` 在同一個檔案系統上做的
    /// 就是 rename。
    public func writeAtomically(_ contents: String, toPath path: String) throws {
        let temporary = try createTemporary(besidePath: path)
        do {
            // 結尾換行的理由見 `write`：bash 那側是 jq 的輸出，帶一個換行。
            try Data((contents + "\n").utf8).write(to: URL(fileURLWithPath: temporary))
            adoptModeOfFile(atPath: path, into: temporary)
            guard rename(temporary, path) == 0 else {
                throw FileStoreError.writeFailed(path: path)
            }
        } catch {
            // rm -f：清掉自己剛建的那個，別把它留在使用者的 scripts/ 底下。
            try? FileManager.default.removeItem(atPath: temporary)
            throw error is FileStoreError ? error : FileStoreError.writeFailed(path: path)
        }
    }

    /// `rename` 換上去的是暫存檔，所以檔案帶的是**暫存檔**的權限（0600）而不是
    /// 原檔的。對 `layout.json` 那只是看得見的副作用（bash 的 `mktemp` 也是 600），
    /// 對 `yabai/yabairc` 卻是壞掉：yabai 直接 exec 那個檔，掉了執行位元之後它會
    /// **安靜地不載入任何設定**——下次重開機才看得出來，而那時已經沒有線索了。
    ///
    /// 只在目標已經存在時沿用它的權限。新建的檔仍然是 0600，與 `mktemp` 一致。
    /// 失敗不擋寫入：權限沒跟上比整份設定寫不進去輕。
    private func adoptModeOfFile(atPath path: String, into temporary: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return }
        _ = chmod(temporary, info.st_mode & 0o7777)
    }

    /// `mktemp "<path>.XXXXXX"` 的等價物：同一個目錄、六個隨機字元、
    /// **O_EXCL 建立**（不是「挑一個看起來沒被用的名字」——那中間有競態）。
    private func createTemporary(besidePath path: String) throws -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        // mktemp 自己也是重試，次數有限；失敗就當成寫不進去。
        for _ in 0 ..< 64 {
            let suffix = String((0 ..< 6).map { _ in alphabet.randomElement()! })
            let candidate = path + "." + suffix
            let descriptor = Darwin.open(candidate, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if descriptor >= 0 {
                Darwin.close(descriptor)
                return candidate
            }
            if errno != EEXIST {
                break
            }
        }
        throw FileStoreError.writeFailed(path: path)
    }
}
