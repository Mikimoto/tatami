import WorkmodeDomain

// `--space --all` 的目標解析，從 `SpaceLayout.swift` 拆出來：那個檔已經過了 swiftlint
// 的 `file_length`（400），而 `.swiftlint.yml` 明文不准調參數。

extension SpaceLayout {
    /// 一個角色在這一輪的「位置」：它是誰、在哪台、那台的 index、以及畫布。
    ///
    /// 收成 struct 而不是四個參數：`allTargets` 另外還要 `spaces` 與 `spaceTrees`，
    /// 攤平就是 6 個，過了 swiftlint 的 `function_parameter_count`（5）。
    struct RoleSite {
        let role: String
        let display: String
        let displayIndex: JSONValue
        let canvas: FrameLayout.Canvas
    }

    /// `.all`：這個角色底下每一棵有樹的 space，**只收現在真的在這台螢幕上的**。
    ///
    /// 不在這台的兩種成因（被刪掉、拔插之後跑到別台）在這裡分不出來，處置也相同：
    /// 跳過並說出來。用**這台**的畫布去排一棵其實在**別台**的樹會把視窗放到螢幕外。
    /// `spaceText` 用它現在的 index（`FrameLayout` 搬視窗要的是 index，不是 uuid）。
    ///
    func allTargets(at site: RoleSite, spaces: JSONValue, spaceTrees: JSONValue) -> [Target] {
        var out: [Target] = []
        for entry in SpaceNames.trees(role: site.role, in: spaceTrees) {
            guard let space = Displays.spaceObject(uuid: entry.uuid, in: spaces),
                  space["display"] == site.displayIndex
            else {
                reporter.report(.space(.spaceNotOnItsDisplay(role: site.role, uuid: entry.uuid)))
                continue
            }
            out.append(Target(role: site.role, uuid: entry.uuid, display: site.display,
                              tree: entry.tree, spaceText: renderRaw(space["index"] ?? .null),
                              canvas: site.canvas))
        }
        return out
    }
}
