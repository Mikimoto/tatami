import Foundation
import Testing
import WorkmodeDomain
import WorkmodeEditorModel
import WorkmodeWire

/// 從 `#filePath` 往上爬到 repo 根目錄。不用工作目錄：`swift test` 的 cwd 不保證是
/// package 根目錄，而 `#filePath` 在編譯期就釘死了這支檔案的絕對位置。
private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // app/Tests/WorkmodeEditorModelTests/
        .deletingLastPathComponent() // app/Tests/
        .deletingLastPathComponent() // app/
        .deletingLastPathComponent() // repo 根目錄
}

/// 載入真實形狀的設定（`examples/layout.json`，使用者那份的副本）、不做任何編輯、
/// 印回去——位元組必須完全相同。
///
/// Wire 那層已經驗過 parser／writer 自己的往返
/// （`WorkmodeWireTests/RoundTripTests.swift:26`），這條驗的是**中間多了
/// `LayoutDocument`** 之後還成立。現在的 `init` 只是存起來所以自明地會過；
/// 價值在 phase 2——有人把內部換成自訂 struct 或在 init 裡正規化，
/// Wire 那條照樣綠，只有這條紅。
@Test func theRealConfigSurvivesTheDocumentUnchanged() throws {
    let url = repoRoot().appendingPathComponent("examples/layout.json")
    let original = try String(contentsOf: url, encoding: .utf8)
    // 沒有這條的話，路徑算錯會退化成「兩個空字串相等」的假綠。
    #expect(original.count > 100, "讀到的檔案太小，路徑大概算錯了：\(url.path)")

    let document = try LayoutDocument(root: JSONParser.parse(original))
    // `format()` 不含結尾換行（那個由 FileStore 補），所以這裡補上再比。
    #expect(JSONWriter.format(document.root) + "\n" == original)
}

/// 真檔驗不到的那半：數字字面值與非字母序的鍵序。
///
/// jq 1.8 對一般小數逐字保留（`2.50` 不會變 `2.5`），`JSONWriter` 照做。若
/// `LayoutDocument` 改成解成 `Double` 再存，這條會紅而上面那條**不會**——
/// 因為現在的 `layout.json` 一個數字都沒有。
@Test func numberLiteralsAndKeyOrderSurviveTheDocument() throws {
    let text = """
    {
      "z": {
        "ratio": 2.50
      },
      "a": {
        "ratio": -0.750
      }
    }
    """
    let document = try LayoutDocument(root: JSONParser.parse(text))
    #expect(JSONWriter.format(document.root) == text)
}

/// 正控制組：上面兩條都是「相等」的斷言，而相等最容易在兩邊一起壞掉時假綠。
/// 這條把它們**應該**抓到的兩種失敗真的做出來，確認輸出會不同。
@Test func theComparisonCatchesBothFailureModes() throws {
    let text = """
    {
      "z": 2.50,
      "a": 1
    }
    """
    guard case let .object(members) = try JSONParser.parse(text) else {
        Issue.record("fixture 的最外層應該是物件")
        return
    }
    #expect(JSONWriter.format(.object(members)) == text, "fixture 本身要先能往返")

    // 鍵序被排序掉。
    #expect(JSONWriter.format(.object(members.sorted { $0.key < $1.key })) != text)
    // 數字字面值被正規化：2.50 → 2.5。
    let normalized = members.map {
        $0.key == "z" ? JSONMember(key: "z", value: .number("2.5")) : $0
    }
    #expect(JSONWriter.format(.object(normalized)) != text)
}
