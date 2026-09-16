import Foundation
import WorkmodeDomain
import WorkmodeWire

// ---------- jq 的三種印法（樹走訪的 __diff 用）----------
//
// 三種**不是**同一回事，全是實測出來的，別合併：
//   -r        字串原樣，其餘印 `jq .` 的**縮排**格式（`{"k":1}` 會印成三行）
//   tostring  字串原樣，其餘印 **compact**（`{"a":1,"b":[2,3]}`）
//   @tsv      只吃純量：null 是空字串，其餘印字面值；容器是 runtime error
//             （`object ({"a":1}) is not valid in a csv row`）

/// jq `-r` 的輸出。
func rawText(_ value: JSONValue) -> String {
    if case let .string(text) = value {
        return text
    }
    return JSONWriter.format(value)
}

/// jq `tostring` 的輸出。容器要 compact，而 JSONWriter 是縮排的——差別只在容器的
/// 分隔符與換行，所以這裡只重寫容器那兩層，字串的跳脫仍然借 JSONWriter
/// （`JSONWriter.format(.string(k))` 就是 jq 的帶引號跳脫形式），不另抄一份。
func compactText(_ value: JSONValue) -> String {
    switch value {
    case let .array(items):
        return "[" + items.map(compactText).joined(separator: ",") + "]"
    case let .object(members):
        let pairs = members.map { JSONWriter.format(.string($0.key)) + ":" + compactText($0.value) }
        return "{" + pairs.joined(separator: ",") + "}"
    case .null, .bool, .number, .string:
        // 純量的 compact 與縮排格式本來就相同。
        return JSONWriter.format(value)
    }
}

func toStringText(_ value: JSONValue) -> String {
    if case let .string(text) = value {
        return text
    }
    return compactText(value)
}

/// `@tsv` 的一欄。轉義與「容器是 runtime error」都在 `JQPrint`——那一份走在
/// `validate`／`match_location` 的差分路徑上，對真的 jq 比過。這裡只把 nil 換成
/// bash 那側看得見的結束狀態（jq 的 runtime error 是 exit 5，見 `exitLikeJQ`）。
func tsvField(_ value: JSONValue) throws -> String {
    guard let field = JQPrint.tsvField(value) else { throw LayoutTreeError.runtime }
    return field
}

/// 樹走訪在 __diff 的收場。jq 的 runtime error 是 exit 5，所以這裡也回 5。
///
/// `nonTerminating` 沒有可鏡射的 exit code——bash 那側是掛住或 SIGABRT，不是一個
/// 結束狀態。一併回 5 並在 stderr 說明；run_pair 只比 stdout，所以那行不進差分，
/// 而真要把這種輸入放進語料的人會先發現 bash 那側根本不會回來。
func exitLikeJQ(_ error: Error) -> Never {
    if case LayoutTreeError.nonTerminating = error {
        FileHandle.standardError.write(
            Data("節點既沒有 window 也沒有兩個 children：bash 那側會無限遞迴\n".utf8)
        )
    }
    if case RectTreeError.nonTerminating = error {
        FileHandle.standardError.write(
            Data("有矩形的寬（高）不是正的，切線兩邊都收得下它：bash 那側會無限遞迴\n".utf8)
        )
    }
    exit(5)
}

// validate 的本體。stdin 與 `__diff` 的參數只是輸入來源不同，行為必須完全一樣，
// 所以兩個入口共用這一支——分成兩份寫，漂移的那天差分只會驗到其中一份。
