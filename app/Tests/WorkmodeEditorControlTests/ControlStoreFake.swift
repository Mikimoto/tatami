import Testing
import WorkmodeCore
import WorkmodeEditorControl

// `Store` 從 `EditorControllerTests.swift` 搬出來，理由是 swiftlint 的 `file_length`
// ——那個檔加完新測試是 429 行，門檻 400，而 `.swiftlint.yml` 的參數不准調。
//
// **搬的是這個 fake 而不是 `path` 或 `editor(_:)`**：`path` 這個名字當時在
// `SignalSettingTests.swift` 也有一個（值不同的 `private let`），拿掉 `private`
// 會撞名。整個 target 只有一個叫 `Store` 的型別，所以它改成 internal 是安全的。
// `ReadOnlyStore` 後來因為同一個理由也搬了進來（見檔尾）。
// （`SignalSettingTests.swift` 與它自己的 `SignalStore` 隨 signal 開關
// 2026-09-15 一起刪掉了，所以那個撞名現在不存在——但它是這個檔存在的理由。）

/// 假的 FileStore。**寫入時補一個結尾換行。**
///
/// `FileManagerStore` 兩個 write 方法都做 `contents + "\n"`（`FileManagerStore.swift:41`
/// 與 `:61`），合約寫在它的 doc：呼叫端傳的內容不自帶結尾換行。Controller 的外部
/// 變更閘門會拿寫出去的內容與之後讀回來的內容比對，所以這個換行是**語意的一部分**：
/// fake 少補它，「連續存兩次」在測試裡會被誤判成外部變更，而真的環境不會。
///
/// `WorkmodeCoreTests/Fakes.swift:318` 的那個 fake **沒有**補——那邊沒有任何測試
/// 寫完再讀同一個路徑，所以看不出來。不要照抄它。
final class Store: FileStore {
    /// 一次寫入。三個欄位裝成 struct 而不是 tuple，是 `large_tuple` 要的
    /// （上限兩個成員），`WorkmodeCoreTests/Fakes.swift:280` 也是同一個形狀。
    struct WriteRecord {
        let path: String
        let contents: String
        let atomic: Bool
    }

    var files: [String: String]
    private(set) var writes: [WriteRecord] = []
    var failWrites = false
    /// 對這些路徑的讀取一律失敗（`exists` 仍回 true）。真的 `FileManagerStore.read`
    /// 在權限不足或路徑是目錄時就是這個形狀（`WorkmodeCoreTests/Fakes.swift:290-293`
    /// 的 `unreadablePaths` 同一件事）。
    var unreadablePaths: Set<String> = []

    init(files: [String: String]) {
        self.files = files
    }

    func exists(atPath path: String) -> Bool {
        files[path] != nil
    }

    func read(atPath path: String) throws -> String? {
        guard !unreadablePaths.contains(path) else {
            throw FileStoreError.readFailed(path: path)
        }
        return files[path]
    }

    func write(_ contents: String, toPath path: String) throws {
        try record(contents, path, atomic: false)
    }

    func writeAtomically(_ contents: String, toPath path: String) throws {
        try record(contents, path, atomic: true)
    }

    private func record(_ contents: String, _ path: String, atomic: Bool) throws {
        // 失敗就不動內容：真的那支是 `rm -f "$tmp"` 之後原檔沒動。
        guard !failWrites else { throw StoreFailure.nope }
        writes.append(WriteRecord(path: path, contents: contents, atomic: atomic))
        files[path] = contents + "\n"
    }

    enum StoreFailure: Error { case nope }
}

/// 只夠 `load()` 用的假 store。這一支不碰存檔，所以不需要 `Store` 那套寫入記帳。
///
/// **internal 不是 private**：`ApplySeamTests` 與 `SpaceLookupTests` 兩邊都要它，
/// 而 `private` 是同檔可見——各留一份的下場是兩份會漂。整個 target 只有一個叫
/// `ReadOnlyStore` 的型別，所以升成 internal 是安全的（與上面 `Store` 從
/// `EditorControllerTests.swift` 搬出來逐字同一條理由）。
final class ReadOnlyStore: FileStore {
    private let text: String

    init(text: String) {
        self.text = text
    }

    func exists(atPath _: String) -> Bool {
        true
    }

    func read(atPath _: String) throws -> String? {
        text
    }

    func write(_: String, toPath _: String) throws {}
    func writeAtomically(_: String, toPath _: String) throws {}
}
