import Foundation

// `tatami __diff <函式> [參數...]`：差分 harness 的入口，不進 usage。
//
// 每個子命令都**鏡射 bash 的 exit code**，不是用產品命令的慣例——
// `display_index_for_uuid` 回 5 是因為 bash 那支的最後一個命令是 jq，而 jq 的
// runtime error 是 5。差分 harness 比 exit code，所以那個鏡射是它存在的一半理由。
//
// 用表而不是 switch：29 個 case 在一支函式裡是複雜度 118，而每個 case 自己又帶
// 兩三個 guard，所以分組拆也壓不下來（實測拆成四支仍是 23–40）。表把分派變成
// 一次查表，每個子命令各自是一支小函式。這裡沒有窮舉可以保護——原本就有
// `default:`，未知名稱回 exit 2。

/// `@Sendable` 與 nonisolated(unsafe) 二選一：這張表是不可變的常數，而 Swift 6
/// 對全域的函式型別要求可跨隔離域。標成 @Sendable 是實話——這些函式不碰共用狀態。
private let diffCommands: [String: @Sendable ([String]) -> Void] = [
    "__marker": diffMarker,
    "tree_root": diffTreeRoot,
    "tree_seq": diffTreeSeq,
    "tree_ratios": diffTreeRatios,
    "prune_tree": diffPruneTree,
    "referenced_labels": diffReferencedLabels,
    "rects_to_tree": diffRectsToTree,
    "trim_ratios": diffTrimRatios,
    "validate": diffValidate,
    "location_desc": diffLocationDesc,
    "location_display": diffLocationDisplay,
    "location_names_from": diffLocationNamesFrom,
    "profile_names_in": diffProfileNamesIn,
    "exile_for": diffExileFor,
    "windows_for": diffWindowsFor,
    "resolve_profile": diffResolveProfile,
    "merge_profile": diffMergeProfile,
    "display_index_for_uuid": diffDisplayIndexForUuid,
    "visible_space_on": diffVisibleSpaceOn,
    "other_space_on": diffOtherSpaceOn,
    "match_location": diffMatchLocation,
    "space_rects": diffSpaceRects,
    "find_windows": diffFindWindows,
    "current_tab_url": diffCurrentTabUrl,
    "id_for_label": diffIdForLabel,
    "escape_ere": diffEscapeEre,
    "rule_for_window": diffRuleForWindow,
    "state_get": diffStateGet,
    "state_set": diffStateSet,
]

func runDiff(_ args: [String]) -> Never {
    guard args.count >= 2 else { fail("用法：tatami __diff <函式> [參數...]", code: 2) }
    guard let handler = diffCommands[args[1]] else {
        fail("未知的函式：\(args[1])", code: 2)
    }
    handler(args)
    exit(0)
}
