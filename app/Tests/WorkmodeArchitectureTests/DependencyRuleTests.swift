import Foundation
import Testing

// MARK: - 這套檢查擋不住什麼

// 這裡的每一條規則都是**掃字串**，不是編譯器也不是型別系統，所以它有尾巴。
// 下面每一條都實測過（把那段程式碼放進對應的 target，build 成功且這幾條測試全綠），
// 不是推測。看到它們別當成缺陷回報——要當成「這套檢查的保證到哪裡為止」。
//
//  1. UI 那層的 Foundation I/O 擋不完。UI 是 SwiftUI target，而 `import SwiftUI`
//     re-export Foundation，所以整個 Foundation 都在射程內，而 allowlist 攔不到它
//     （SwiftUI 本來就得准）。`forbiddenSymbols` 只列了最順手的那幾種拼法：
//     實測 `Text(Bundle.main.bundlePath)` 編得過、測試綠。`URLSession` 等同理。
//
//  2. 更長的識別字包住禁令字時躲得過。詞界比對是為了不把 `runProcessQueue` 誤判成
//     `Process`，代價就是這個：實測在 UI 宣告 `enum FileManagerStore` 並使用它，
//     編得過、測試綠。import 那一側沒有這個問題（allowlist 比的是整個模組名）。
//
//  3. 字串插值裡的呼叫掃不到。掃描把字串字面值整段拿掉，插值 `\(…)` 一起消失：
//     實測 `Text("\(FileManager.default.currentDirectoryPath)")` 編得過、測試綠。
//
// 換句話說：**import 那一側是清單式的保證，I/O 那一側是減速丘。** 誰想繞都繞得過，
// 這幾條擋的是順手寫下去的那一次。

/// Domain 是最內層，不得碰外部世界、也不得依賴外層。這兩條都寫成測試而不是註解：
/// 前者編譯器本來就不管，後者實測發現編譯器**只在 clean build 管**（熱快取下加
/// import 只是一行警告，`swift build` 照樣 exit 0）。
///
/// 掃描是靠字串比對，所以它自己也可能壞掉——`patternActuallyMatches` 是正控制組，
/// 沒有它的話「乾淨」與「pattern 根本不匹配」外觀完全相同。
private let forbidden = [
    // 碰外部世界
    "Process", "FileManager", "JSONSerialization", "FileHandle",
    // 依賴外層（相依方向是 CLI → Adapters → Core → Domain、Wire → Domain）
    "import WorkmodeWire", "import WorkmodeCore",
    "import WorkmodeAdapters", "import WorkmodeCLI",
]

/// 從測試檔往上找到 app/，再定位 Sources/。用 #filePath 而不是 cwd：
/// swift test 的工作目錄不保證是 package 根目錄。
func sourcesDirectory() -> URL {
    URL(fileURLWithPath: #filePath) // …/app/Tests/WorkmodeArchitectureTests/X.swift
        .deletingLastPathComponent() // …/app/Tests/WorkmodeArchitectureTests
        .deletingLastPathComponent() // …/app/Tests
        .deletingLastPathComponent() // …/app
        .appendingPathComponent("Sources")
}

private func swiftFiles(in directory: URL) throws -> [URL] {
    let items = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    return items.filter { $0.hasSuffix(".swift") }.map { directory.appendingPathComponent($0) }
}

@Test func domainDependsOnNothingOutsideItself() throws {
    let domain = sourcesDirectory().appendingPathComponent("WorkmodeDomain")
    let files = try swiftFiles(in: domain)
    #expect(!files.isEmpty, "掃不到任何 Domain 原始碼——路徑算錯了，這個測試等於沒跑")

    for file in files {
        // 與編輯器那三層共用同一個掃描器。原本只丟棄「整行都是註解」的行再做子字串
        // 比對，於是同樣的四種假陽性在這裡也成立：實測 Domain 檔尾加
        // `// 這裡不能碰 FileManager` 或 `func runProcessQueue() {}` 都會轉紅。
        let code = try scannableCode(of: String(contentsOf: file, encoding: .utf8))
        for name in forbidden {
            #expect(!containsAsWord(code, name),
                    "\(file.lastPathComponent) 用到了 \(name)：Domain 不得碰外部世界，也不得依賴外層")
        }
    }
}

/// 正控制組：掃描器對確定含有違規字樣的字串必須有反應。兩種違規各驗一個樣本——
/// 只驗一種的話，另一種的 pattern 打錯了也看不出來。
/// 這條紅了代表偵測器壞了，而不是程式碼變乾淨了。
@Test func patternActuallyMatches() {
    #expect(forbidden.contains { containsAsWord(scannableCode(of: "let p = Process()"), $0) })
    #expect(forbidden.contains { containsAsWord(scannableCode(of: "import WorkmodeCore"), $0) })
}

// MARK: - 編輯器三層的相依規則

/// 一層的規矩。相依走 allowlist、I/O 走 denylist，兩者的強度差很多——見下面各自的說明。
///
/// 四份清單**兩兩獨立列出**，然後由 `editorPatternsActuallyMatch` 斷言集合相等。
/// 上一版用 `forbiddenSymbols: Array(samples.keys)` 從樣本表推導禁令清單，於是那條
/// 集合相等的斷言前提蘊含結論、結構上不可能失敗：實測把 `FileHandle` 整列刪掉，
/// 控制組照樣綠，同時 UI 寫 `FileHandle.standardOutput` 也綠。
private struct EditorRule: Sendable {
    let target: String
    /// **只准** import 這些。allowlist 而不是「不准 import X」：後者對 `import struct X.Decl`
    /// 這種部分匯入的子字串比對是漏的（實測 `import struct WorkmodeAdapters.FileManagerStore`
    /// 放進 UI，編得過、測試綠）。這一側涵蓋得到的是**所有走 import 敘述進來的模組**，
    /// 它擋不住的東西列在檔頭的「這套檢查擋不住什麼」。
    let allowedImports: [String]
    /// 每個准許的模組配一個樣本 import 敘述，形狀刻意分散（裸的、帶屬性的、部分匯入的、
    /// tab 分隔的），用來驗剖析器對這些形狀都認得出模組名。
    let importSamples: [String: String]
    /// 不准出現的 I/O 符號。這份清單**不完備**，不要當成「這一層碰不到 I/O」的保證——
    /// 具體漏得掉什麼、怎麼實測出來的，寫在檔頭那一段。
    ///
    /// 對 Control 而言它是**預防未來**而不是實擋：那一層編譯時根本拿不到 Foundation
    /// （`import Observation` 不 re-export 它），實測寫 `FileManager.default` 得到
    /// `error: cannot find 'FileManager' in scope`。它要對外就走 port（`FileStore`）。
    let forbiddenSymbols: [String]
    /// 每個禁令符號配一個**必定命中**的樣本。
    let symbolSamples: [String: String]
}

/// 三層共用的 I/O 禁令。與 `ioSymbolSamples` 是各自獨立的一份，刪任一邊都會讓控制組紅。
private let ioForbiddenSymbols = [
    "Process", "ProcessInfo", "FileManager", "JSONSerialization", "FileHandle",
    // 這兩個是複審實測溜過去的寫法：UI 的 view body 寫
    // `String(contentsOfFile:encoding:)` 編得過而且當時全綠。
    "String(contentsOfFile:", "Data(contentsOf:",
]

private let ioSymbolSamples: [String: String] = [
    "Process": "let p = Process()",
    "ProcessInfo": "ProcessInfo.processInfo.environment",
    "FileManager": "FileManager.default.contents(atPath: path)",
    "JSONSerialization": "JSONSerialization.data(withJSONObject: x)",
    "FileHandle": "FileHandle.standardOutput.write(data)",
    "String(contentsOfFile:": "try String(contentsOfFile: path, encoding: .utf8)",
    "Data(contentsOf:": "try Data(contentsOf: url)",
]

/// 掃原始碼而不是靠編譯器：編譯器只在 clean build 管 import，而開發機的 .build
/// 幾乎永遠是熱的（CLAUDE.md 記著實測結果——熱快取下只降級成一行警告）。
private let editorRules: [EditorRule] = [
    EditorRule(target: "WorkmodeEditorModel",
               allowedImports: ["WorkmodeDomain"],
               importSamples: ["WorkmodeDomain": "import WorkmodeDomain"],
               forbiddenSymbols: ioForbiddenSymbols,
               symbolSamples: ioSymbolSamples),
    EditorRule(target: "WorkmodeEditorControl",
               allowedImports: ["Observation", "WorkmodeEditorModel",
                                "WorkmodeDomain", "WorkmodeWire", "WorkmodeCore"],
               importSamples: ["Observation": "import Observation",
                               "WorkmodeEditorModel": "@preconcurrency import WorkmodeEditorModel",
                               "WorkmodeDomain": "import struct WorkmodeDomain.JSONValue",
                               "WorkmodeWire": "import\tWorkmodeWire",
                               "WorkmodeCore": "@testable import WorkmodeCore"],
               forbiddenSymbols: ioForbiddenSymbols,
               symbolSamples: ioSymbolSamples),
    EditorRule(target: "WorkmodeEditorUI",
               allowedImports: ["SwiftUI", "Observation", "WorkmodeEditorControl",
                                "WorkmodeEditorModel", "WorkmodeDomain"],
               importSamples: ["SwiftUI": "import SwiftUI",
                               "Observation": "@_exported import Observation",
                               "WorkmodeEditorControl": "@_spi(Editor) import WorkmodeEditorControl",
                               "WorkmodeEditorModel": "import struct WorkmodeEditorModel.LayoutDocument",
                               "WorkmodeDomain": "@testable @preconcurrency import WorkmodeDomain"],
               forbiddenSymbols: ioForbiddenSymbols,
               symbolSamples: ioSymbolSamples),
]

// MARK: - 掃描器

/// 把註解與字串字面值換掉再比對。原本只丟棄「整行都是註解」的行，配上裸字串比對
/// 之後製造了四種假陽性，複審實測全部轉紅：行尾註解 `// 這裡不能碰 WorkmodeCore`、
/// 區塊註解、`Text("WorkmodeCore")`、以及識別字 `runProcessQueue` 撞上 `Process`。
/// 前兩種遲早會踩到——這個 repo 的慣例正是「註解寫為什麼」，而理由裡一定會提到模組名。
///
/// 換行原樣保留，因為 import 是逐行認的。字串插值 `\(…)` 連同字串一起被拿掉，
/// 所以插值裡的 I/O 呼叫掃不到——那是上面說的「不完備」的一部分。
private func scannableCode(of source: String) -> String {
    var out = ""
    let chars = Array(source)
    var index = 0
    while index < chars.count {
        if let next = skipComment(chars, from: index) {
            index = next; continue
        }
        if let next = skipStringLiteral(chars, from: index, into: &out) {
            index = next; continue
        }
        out.append(chars[index])
        index += 1
    }
    return out
}

/// 回傳註解結束後的索引；此處不是註解就回 nil。Swift 的區塊註解可以巢狀。
private func skipComment(_ chars: [Character], from start: Int) -> Int? {
    guard chars[start] == "/", start + 1 < chars.count else { return nil }
    if chars[start + 1] == "/" {
        var index = start
        while index < chars.count, chars[index] != "\n" {
            index += 1
        }
        return index // 換行本身留給呼叫端照抄
    }
    guard chars[start + 1] == "*" else { return nil }
    var index = start + 2
    var depth = 1
    while index < chars.count, depth > 0 {
        if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "*" {
            depth += 1; index += 2; continue
        }
        if chars[index] == "*", index + 1 < chars.count, chars[index + 1] == "/" {
            depth -= 1; index += 2; continue
        }
        index += 1
    }
    return index
}

/// 回傳字串字面值結束後的索引，並把它涵蓋的換行補進 `out`（多行字串會吃掉好幾行，
/// 不補的話後面的 import 逐行判讀會錯位）。
///
/// raw string（`#"…"#`）要按 `#` 的數量處理，不能當成一般字串：`#"\"#` 裡的反斜線
/// 不是跳脫字元，照一般規則讀會把收尾的引號吃掉、連同該行後面的程式碼一起消失
/// （假陰性）；而 `#"a "import X" b"#` 裡的內層引號不是結尾，照一般規則讀會提早收工、
/// 把字串內容當成程式碼（假陽性）。兩種都實測過。
private func skipStringLiteral(_ chars: [Character], from start: Int, into out: inout String) -> Int? {
    var index = start
    var hashes = 0
    while index < chars.count, chars[index] == "#" {
        hashes += 1
        index += 1
    }
    guard index < chars.count, chars[index] == "\"" else { return nil }
    let isMultiline = index + 2 < chars.count && chars[index + 1] == "\"" && chars[index + 2] == "\""
    let quoteRun = isMultiline ? 3 : 1
    index += quoteRun
    while index < chars.count {
        // raw string 裡只有 `\` 後面接足夠多的 `#` 才是跳脫。
        if chars[index] == "\\", hashesFollow(chars, at: index + 1, count: hashes) {
            index += 1 + hashes + 1
            continue
        }
        if chars[index] == "\n" {
            if !isMultiline {
                return index // 單行字串沒收尾就當它到行尾為止
            }
            out.append("\n")
            index += 1
            continue
        }
        if chars[index] == "\"", closesLiteral(chars, at: index, quoteRun: quoteRun, hashes: hashes) {
            return index + quoteRun + hashes
        }
        index += 1
    }
    return index
}

private func hashesFollow(_ chars: [Character], at start: Int, count: Int) -> Bool {
    guard count > 0 else { return true }
    guard start + count <= chars.count else { return false }
    return chars[start ..< start + count].allSatisfy { $0 == "#" }
}

private func closesLiteral(_ chars: [Character], at start: Int, quoteRun: Int, hashes: Int) -> Bool {
    guard start + quoteRun <= chars.count else { return false }
    guard chars[start ..< start + quoteRun].allSatisfy({ $0 == "\"" }) else { return false }
    return hashesFollow(chars, at: start + quoteRun, count: hashes)
}

private func isIdentifierCharacter(_ char: Character) -> Bool {
    char.isLetter || char.isNumber || char == "_"
}

/// 詞界比對。子字串比對會把 `runProcessQueue` 判成用了 `Process`；只在 needle 的
/// 頭尾本身是識別字字元時才要求詞界，這樣 `String(contentsOfFile:` 這種以冒號結尾的
/// needle 也配得上 `String(contentsOfFile:path)`。
private func containsAsWord(_ haystack: String, _ needle: String) -> Bool {
    let hay = Array(haystack), pin = Array(needle)
    guard let first = pin.first, let last = pin.last, hay.count >= pin.count else { return false }
    let needsLeft = isIdentifierCharacter(first), needsRight = isIdentifierCharacter(last)
    for start in 0 ... (hay.count - pin.count) where Array(hay[start ..< start + pin.count]) == pin {
        let leftOK = !needsLeft || start == 0 || !isIdentifierCharacter(hay[start - 1])
        let end = start + pin.count
        let rightOK = !needsRight || end == hay.count || !isIdentifierCharacter(hay[end])
        if leftOK, rightOK {
            return true
        }
    }
    return false
}

/// 剝掉行首任意數量的屬性，含帶括號的 `@_spi(X)`。只認 `@testable` 是不夠的：
/// 實測 `@preconcurrency import WorkmodeAdapters` 讓 `importedModules` 回空陣列，
/// 於是 UI 那個檔的 import 檢查整個沒跑，body 用 `FileManagerStore()` 也 build 成功、
/// 兩條架構測試全綠。`@_exported`／`@_implementationOnly`／`@_spi(X)` 同樣。
private func strippingLeadingAttributes(_ line: String) -> String {
    let chars = Array(line)
    var index = 0
    while index < chars.count, chars[index] == "@" {
        index += 1
        while index < chars.count, isIdentifierCharacter(chars[index]) {
            index += 1
        }
        if index < chars.count, chars[index] == "(" {
            var depth = 0
            repeat {
                if chars[index] == "(" {
                    depth += 1
                } else if chars[index] == ")" {
                    depth -= 1
                }
                index += 1
            } while index < chars.count && depth > 0
        }
        while index < chars.count, chars[index].isWhitespace {
            index += 1
        }
    }
    return String(chars[index...])
}

/// 抓出每一行 import 敘述的模組名。分隔用「任意空白」切 token 而不是 `hasPrefix("import ")`：
/// 後者漏掉 tab 分隔的 `import\tX`（實測放進 UI，測試全綠）。
private func importedModules(in code: String) -> [String] {
    let kinds = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let", "actor"]
    return code.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
        let line = strippingLeadingAttributes(rawLine.trimmingCharacters(in: .whitespaces))
        var tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.first == "import" else { return nil }
        tokens.removeFirst()
        if let kind = tokens.first, kinds.contains(kind) {
            tokens.removeFirst()
        }
        // 部分匯入（`import struct X.Decl`）的模組名是第一段。
        guard let module = tokens.first?.split(separator: ".").first.map(String.init) else { return nil }
        return module.isEmpty ? nil : module
    }
}

// MARK: - 斷言

@Test func editorLayersKeepTheirDistance() throws {
    for rule in editorRules {
        let directory = sourcesDirectory().appendingPathComponent(rule.target)
        let files = try swiftFiles(in: directory)
        #expect(!files.isEmpty, "掃不到 \(rule.target) 的原始碼——路徑算錯了，這條等於沒跑")

        for file in files {
            let code = try scannableCode(of: String(contentsOf: file, encoding: .utf8))
            for module in importedModules(in: code) {
                #expect(rule.allowedImports.contains(module),
                        "\(file.lastPathComponent) import 了 \(module)：不在 \(rule.target) 准許的清單上")
            }
            for symbol in rule.forbiddenSymbols {
                #expect(!containsAsWord(code, symbol),
                        "\(file.lastPathComponent) 用到了 \(symbol)：違反 \(rule.target) 的相依規則")
            }
        }
    }
}

/// 正控制組：與 `patternActuallyMatches` 同一個理由，但這裡要求**每一個字串**都有樣本，
/// 不是每一類抽一個。上一版三層之間不對稱（Model 四個都有、Control 與 UI 各只有兩個），
/// 於是 Control 的 `JSONSerialization` 與 `FileHandle` 同時打錯照樣綠。
@Test func editorPatternsActuallyMatch() {
    #expect(editorRules.count == 3, "三層少了一層——下面的逐層檢查會靜默少驗")

    for rule in editorRules {
        #expect(Set(rule.symbolSamples.keys) == Set(rule.forbiddenSymbols),
                "\(rule.target)：禁令符號與正控制樣本沒有一一對應")

        for symbol in rule.forbiddenSymbols {
            let sample = rule.symbolSamples[symbol] ?? ""
            #expect(containsAsWord(scannableCode(of: sample), symbol),
                    "\(rule.target) 的 \(symbol) 對它自己的樣本沒反應——字串打錯了")
        }

        #expect(!rule.allowedImports.isEmpty, "\(rule.target) 的 allowlist 是空的")
        #expect(Set(rule.importSamples.keys) == Set(rule.allowedImports),
                "\(rule.target)：allowlist 與樣本 import 敘述沒有一一對應")
        for module in rule.allowedImports {
            #expect(importedModules(in: rule.importSamples[module] ?? "") == [module],
                    "\(rule.target) 的 allowlist 上 \(module) 從它自己的樣本認不出來")
        }
    }

    // 剖析器的正控制：屬性前綴與 tab 分隔都得認得，漏讀等於那一行完全不檢查。
    #expect(importedModules(in: "import WorkmodeCore") == ["WorkmodeCore"])
    #expect(importedModules(in: "import struct WorkmodeAdapters.FileManagerStore") == ["WorkmodeAdapters"])
    #expect(importedModules(in: "@testable import WorkmodeCLI") == ["WorkmodeCLI"])
    #expect(importedModules(in: "@preconcurrency import WorkmodeAdapters") == ["WorkmodeAdapters"])
    #expect(importedModules(in: "@_spi(Foo) import WorkmodeAdapters") == ["WorkmodeAdapters"])
    #expect(importedModules(in: "@testable @preconcurrency import WorkmodeAdapters") == ["WorkmodeAdapters"])
    #expect(importedModules(in: "import\tWorkmodeAdapters") == ["WorkmodeAdapters"])

    // 反向控制：註解、字串字面值、raw string、以及包住禁令字的識別字都**不得**命中，
    // 否則假陽性會逼下一個人放寬規則。
    #expect(scannableCode(of: "let x = 1 // 這裡不能碰 WorkmodeCore\n") == "let x = 1 \n")
    #expect(!containsAsWord(scannableCode(of: "/* import WorkmodeAdapters */"), "WorkmodeAdapters"))
    #expect(importedModules(in: scannableCode(of: "Text(\"import WorkmodeCore\")")).isEmpty)
    #expect(!containsAsWord(scannableCode(of: "func runProcessQueue() {}"), "Process"))
    #expect(importedModules(in: scannableCode(of: "let s = #\"a \"import WorkmodeAdapters\" b\"#")).isEmpty)
    // raw string 的收尾若被誤讀，同一行後面的程式碼會被吞掉——那是假陰性，比假陽性難發現。
    #expect(containsAsWord(scannableCode(of: "let s = #\"\\\"#; let p = Process()"), "Process"))
}
