import Foundation
import WorkmodeCore
import WorkmodeDomain

// 套版迴圈與規則比對的欄位。與主檔分開只是為了型別長度。

extension JSONEventRenderer {
    func render(restore: RestoreEvent) -> [String: Any] {
        switch restore {
        case let .minimizedWindowRestored(label):
            ["kind": "minimizedWindowRestored", "label": label]
        case let .minimizedWindowRestoreFailed(label):
            ["kind": "minimizedWindowRestoreFailed", "label": label]
        }
    }

    func render(role: RoleEvent) -> [String: Any] {
        switch role {
        case let .treeRoleHasNoDisplay(role):
            ["kind": "treeRoleHasNoDisplay", "role": role]
        }
    }

    func render(rules: RuleEvent) -> [String: Any] {
        switch rules {
        case .noRulesResolved:
            ["kind": "noRulesResolved"]
        // 八個欄位一律是字串，與 human 版同一個理由：它們是 jq 印出來的文字，
        // 而 `2.50`／`1E+3`／`1.7976931348623157e+308` 這些形狀是資料的一部分。
        // 轉成 JSON 的數字會讓消費端拿到一個被重新格式化過的值。
        case let .ruleWindowPositionReported(label, id, display, space, frame):
            ["kind": "ruleWindowPositionReported", "label": label, "id": id,
             "display": display, "space": space,
             "width": frame.width, "height": frame.height,
             "x": frame.originX, "y": frame.originY]
        // 候選是陣列而不是那串接好的文字：`tr '\n' ' '` 是**人看的**表示法，而
        // 消費端要能逐一取出候選（id 本身不含空白，但那是資料的性質不是格式的保證）。
        case let .ruleMatchedMultipleWindows(label, count, candidates):
            ["kind": "ruleMatchedMultipleWindows", "label": label,
             "count": count, "candidates": candidates]
        case let .ruleCandidatesAllClaimed(label):
            ["kind": "ruleCandidatesAllClaimed", "label": label]
        case let .ruleWindowNotFound(label, matchType, matchValue):
            ["kind": "ruleWindowNotFound", "label": label,
             "matchType": matchType, "matchValue": matchValue]
        }
    }
}
