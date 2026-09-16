import Foundation
import WorkmodeAdapters
import WorkmodeDomain
import WorkmodeWire

// `tatami validate` 的 CLI 那一層。從 `main.swift` 整段搬出來（行為零變更）：
// 那個檔在 tty 分支加進去之後是 402 行，也就是 swiftlint `file_length` 的門檻
// 再過去兩行，而 `.swiftlint.yml` 的檔頭明文禁止調參數。
// `EditCommand.swift` → `SaveCommand.swift` 是同一個先例。
//
// **這裡的訊息一個位元組都不能改**：`tests/oracle/workmode-38.line` 凍著 bash 的
// printf 原文，而 `tests/swift_checks.sh:60` 從那個檔挖前綴出來比對。

/// 只給「不是合法 JSON」那條用。bash 印的是 jq 的內部錯誤文字
/// （`jq: parse error: Invalid numeric literal at line 1, column 4`），那個複製不了，
/// 所以這裡刻意用自己的描述——差分 harness 因此把這條排除在逐位元組比對之外，
/// 改成「兩邊都 rc=1、都以同一個前綴開頭」的獨立斷言。
func describeParseError(_ error: Error) -> String {
    guard let error = error as? JSONParseError else { return "解析失敗" }
    switch error {
    case let .unexpected(_, offset): return "第 \(offset) 個位元組不是預期的字元"
    case .truncated: return "輸入在中途結束"
    case let .trailingGarbage(offset): return "第 \(offset) 個位元組之後還有多餘的內容"
    case let .badEscape(offset): return "第 \(offset) 個位元組的跳脫序列不合法"
    case let .badUTF8(offset): return "第 \(offset) 個位元組不是合法的 UTF-8"
    }
}

func runValidate(text: String, json: Bool) -> Never {
    let root: JSONValue
    do {
        root = try JSONParser.parse(text)
    } catch {
        let reason = describeParseError(error)
        if json {
            let line = (try? JSONEnvelope.failure(command: "validate", kind: "invalid_json",
                                                  message: reason)) ?? ""
            print(line)
            exit(1)
        }
        fail("! layout.json 不是合法 JSON：\(reason)", code: 1)
    }

    let problems = LayoutValidator.validate(root)
    if json {
        // 失敗也走 verdict 而不是 failure：問題清單是呼叫端要的結果，不是錯誤細節。
        let line = (try? JSONEnvelope.verdict(command: "validate", succeeded: problems.isEmpty,
                                              data: ["problems": problems.map(payload)])) ?? ""
        print(line)
        exit(problems.isEmpty ? 0 : 1)
    }
    guard !problems.isEmpty else { exit(0) }
    FileHandle.standardError.write(Data(renderProblems(problems).utf8))
    exit(1)
}
