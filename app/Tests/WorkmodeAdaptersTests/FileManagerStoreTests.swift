import Foundation
import Testing
@testable import WorkmodeAdapters

// `writeAtomically` 用 `rename` 把暫存檔換上去，所以檔案帶的是暫存檔的權限。
// 對 `yabai/yabairc` 那是壞掉的：yabai 直接 exec 它，掉了執行位元之後整份設定
// 安靜地不生效，而且要重開機才看得出來。實際踩過一次（2026-08-26 的 signal 開關）。

private func mode(of path: String) -> mode_t {
    var info = stat()
    #expect(stat(path, &info) == 0)
    return info.st_mode & 0o7777
}

private func scratchPath(_ name: String) -> String {
    NSTemporaryDirectory() + "workmode-store-\(name)-\(UInt64.random(in: 0 ..< .max))"
}

/// 覆寫一個可執行的檔：權限必須原封不動地留著。
@Test func anAtomicWriteKeepsTheExecutableBit() throws {
    let path = scratchPath("exec")
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(FileManager.default.createFile(atPath: path, contents: Data("舊的\n".utf8),
                                           attributes: [.posixPermissions: 0o755]))
    #expect(mode(of: path) == 0o755)

    try FileManagerStore().writeAtomically("新的", toPath: path)

    #expect(mode(of: path) == 0o755)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "新的\n")
}

/// 不是「一律 755」而是「沿用目標的」——0644 的檔覆寫完仍然是 0644。
@Test func anAtomicWriteKeepsAPlainFilesMode() throws {
    let path = scratchPath("plain")
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(FileManager.default.createFile(atPath: path, contents: Data("舊的\n".utf8),
                                           attributes: [.posixPermissions: 0o644]))

    try FileManagerStore().writeAtomically("新的", toPath: path)

    #expect(mode(of: path) == 0o644)
}

/// 對照組：目標不存在時沒有東西可以沿用，維持 `mktemp` 的 0600。
/// 少了這條，「一律 chmod 755」與正確的實作分不出來。
@Test func aBrandNewFileStaysAtTheTemporaryFilesMode() throws {
    let path = scratchPath("fresh")
    defer { try? FileManager.default.removeItem(atPath: path) }

    try FileManagerStore().writeAtomically("新的", toPath: path)

    #expect(mode(of: path) == 0o600)
}
