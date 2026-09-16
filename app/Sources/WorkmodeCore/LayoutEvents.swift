import WorkmodeDomain

// 套版迴圈對視窗做的事。兩組各自對應 workmode.sh 的一支函式，分組不是為了美觀：
// renderer 那側一組一支 switch，而 case 數就是那支 switch 的複雜度。
//
// 2026-09-07 隨 `ApplyLayout`／`TreeLayout`／`StrangerExile` 退役，這裡原本還有
// `ExileEvent`（3 個 case，`exile_strangers` workmode.sh:681-702）與 `TreeEvent`
// （8 個 case，`layout_tree` 768-819 與 `apply_ratio` 824-856），另外 `RoleEvent`
// 有 5 個 case。那三支編排刪掉之後它們一個發送者都沒有，所以整組移除——
// 留著看起來還活著的路徑，比刪掉它糟。原文在
// `git show bash-oracle:scripts/workmode.sh` 的那幾行。

/// `restore_minimized`（workmode.sh:643-661）。
public enum RestoreEvent: Equatable, Sendable {
    /// workmode.sh:656。還原成功，`i < RESTORE_POLLS`。
    case minimizedWindowRestored(label: String)

    /// workmode.sh:658。輪詢 20 次仍是最小化的。
    case minimizedWindowRestoreFailed(label: String)

    public var channel: OutputChannel {
        switch self {
        case .minimizedWindowRestoreFailed, .minimizedWindowRestored:
            .stdout
        }
    }
}

/// `main` 迴圈裡「跳過這個角色」的降級路徑（workmode.sh:1256-1369）。
///
/// 原本五條，2026-09-07 只剩這一條——另外四條（螢幕未接、整棵樹被剪光、找不到
/// 可見的 space、只有一個 space）的發送者隨 `ApplyLayout` 一起刪掉了。`--space`
/// 那條路有自己的一組（`SpaceEvent`），不共用這裡。
public enum RoleEvent: Equatable, Sendable {
    /// workmode.sh:1328。`trees` 有這個角色，但 `displays` 沒定義它。
    case treeRoleHasNoDisplay(role: String)

    public var channel: OutputChannel {
        switch self {
        case .treeRoleHasNoDisplay:
            .stdout
        }
    }
}

/// 套版迴圈的事件。
public enum LayoutEvent: Equatable, Sendable {
    /// 最小化的視窗要先還原才排得進 bsp 樹。
    case restore(RestoreEvent)

    /// 這個角色整個跳過。
    case role(RoleEvent)

    public var channel: OutputChannel {
        switch self {
        case let .restore(event): event.channel
        case let .role(event): event.channel
        }
    }
}
