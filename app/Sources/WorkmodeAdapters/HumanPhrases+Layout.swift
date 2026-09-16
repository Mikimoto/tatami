import Foundation
import WorkmodeCore
import WorkmodeDomain

// 套版迴圈與規則比對的句子。與主檔分開只是為了型別長度——它們仍然是
// HumanEventRenderer 的一部分，`render(layout:)` 與 `render(_:)` 在主檔。

extension HumanEventRenderer {
    func render(restore: RestoreEvent) -> String {
        switch restore {
        // workmode.sh:656
        case let .minimizedWindowRestored(label):
            "  「\(label)」原本是最小化的，已還原\n"
        // workmode.sh:658
        case let .minimizedWindowRestoreFailed(label):
            "  ! 「\(label)」是最小化的且還原失敗，它排不進佈局\n"
        }
    }

    func render(role: RoleEvent) -> String {
        switch role {
        // workmode.sh:1328
        case let .treeRoleHasNoDisplay(role):
            "  ! trees 有「\(role)」但 displays 沒定義這個角色，跳過\n"
        }
    }

    func render(rules: RuleEvent) -> String {
        switch rules {
        // workmode.sh:667。這一句是 `echo` 不是 `printf`——換行由 echo 自己補。
        case .noRulesResolved:
            "  （沒有解到任何視窗）\n"
        // workmode.sh:674。**這一行是 jq 的字串插值印的，不是 printf**，所以它的
        // 逐位元組比對走的是真的 `jq`（見 RuleLineRendererTests）而不是 bash printf。
        // `jq -r` 印完一個值補一個換行，那個換行也在這裡。
        case let .ruleWindowPositionReported(label, id, display, space, frame):
            "  \(label)  id=\(id) display=\(display) space=\(space) "
                + "\(frame.width)x\(frame.height) @\(frame.originX),\(frame.originY)\n"
        // workmode.sh:894。候選是 `printf '%s' "$cands" | tr '\n' ' '`——每個換行變
        // 一個空白，而 `$( )` 早就剝掉了尾端換行，所以**最後一個候選後面沒有空白**
        // （實測 `7 8` 是三個位元組）。`joined(separator:)` 正好是這個。
        case let .ruleMatchedMultipleWindows(label, count, candidates):
            "  ! 「\(label)」命中 \(count) 個視窗（\(candidates.joined(separator: " "))）"
                + "，取第一個未被認領的\n"
        // workmode.sh:907
        case let .ruleCandidatesAllClaimed(label):
            "  ! 「\(label)」的候選視窗都已被前面的規則認領，跳過\n"
        // workmode.sh:909
        case let .ruleWindowNotFound(label, matchType, matchValue):
            "  ! 找不到「\(label)」的視窗（\(matchType) \(matchValue)）\n"
        }
    }
}
