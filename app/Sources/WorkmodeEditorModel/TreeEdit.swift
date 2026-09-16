import WorkmodeDomain

/// 畫布上的五個編輯動作，形狀與 `RuleEdit` 相同：`LayoutDocument → LayoutDocument`
/// 的純函式，走 `JSONPath` 做定點修改，走不通就回原文件讓 `EditorController.edit`
/// 出聲（C8）。
///
/// **不能拿 `PaneNode` 寫回去。** 它是有損投影：非字串的 label 走
/// `JQPrint.interpolate`（`PaneNode.swift:50`），`ratio` 是字面值字串，而分割節點上
/// 使用者自己加的鍵它連讀都沒讀。整棵樹重建會把 `{"window": 7}` 改成
/// `{"window": "7"}` 並靜默刪掉 `note` 這種鍵——與 `RuleEdit` 檔頭那條同一個理由。
public extension LayoutDocument {
    /// 這一格現在的內容。nil 代表 `trees.<角色>` 或路徑上某一段不存在。
    func node(at path: PanePath) -> JSONValue? {
        JSONPath.get(root, path.steps)
    }

    /// 把一個 label 放到某一格的某一區。
    ///
    /// 三條分支：
    /// 1. **那一格是空的** → 直接放葉，不分割。分割會留一個空的兄弟，而 `{}` 在
    ///    `LayoutValidator.splitNodeChecks` 報「節點既沒有 window 也沒有 axis」
    ///    ——⌘S 被擋住，而畫面上沒有任何辦法修好它。
    /// 2. **正中間且那一格是葉** → 只換 `window` 這個鍵，`ratio` 與不認得的鍵留著。
    /// 3. **其餘** → 換成一個分割節點，原本的內容退到另一邊。
    ///
    /// 「空的」只認 缺鍵／`null`／`false`／`{}` 四種。畸形但有內容的節點
    /// （純量、三個 children）走第 3 條——它在畫布上是一格「未指定」，分割之後
    /// validate 會指名它那一側，使用者才有得修；靜默換掉等於刪掉他看不見的東西。
    ///
    /// **那棵樹的鍵不存在時，放到它照樣會成功建出來**。差的往往是**中繼段**：
    /// 分頁列現在自動列出 yabai 查到的每一個 space（2026-08-30），所以一個從來沒被
    /// 畫過的 space 在 profile 底下連 `spaceTrees` 這個鍵都還沒有，而 `set` 對走不通
    /// 的中繼段是 throw。
    ///
    /// 所以空白分支走 `setCreatingMissingObjects`（`ProfileMerge` 的先例）。
    /// 少了這一步，**還沒畫過的分頁上第一次拖放什麼都不會發生**，而使用者只看到一句
    /// 泛用的「沒有改到任何東西」——2026-08-23 由 fresh-context verifier 抓到。
    ///
    /// 畫布到不了「角色不存在」那個分支——`canvasRoles` 只列 display 與 tree 角色的
    /// 聯集——所以那不是需要擋的輸入，擋反而是多一個沒有輸入踩得到的守衛
    /// （2026-08-20 實測，見 `TreeEditTests.anUnknownRoleIsCreated`）。
    func placing(_ label: LabelChoice, at path: PanePath, zone: DropZone) -> LayoutDocument {
        let leaf = JSONValue.object([JSONMember(key: "window", value: label.value)])
        let existing = node(at: path)

        if Self.isVacant(existing) {
            return rebuilt(try? JSONPath.setCreatingMissingObjects(root, path.steps, to: leaf))
        }
        guard let existing else { return self }

        if zone == .center {
            guard case let .object(members) = existing,
                  members.contains(where: { $0.key == "window" })
            else { return self }
            return rebuilt(try? JSONPath.set(root, path.steps + [.key("window")],
                                             to: label.value))
        }
        guard let axis = zone.axis else { return self }
        let children = zone.putsNewNodeFirst ? [leaf, existing] : [existing, leaf]
        return rebuilt(try? JSONPath.set(root, path.steps, to: .object([
            JSONMember(key: "axis", value: .string(axis)),
            JSONMember(key: "children", value: .array(children)),
        ])))
    }

    /// 這一格有沒有東西可以刪。
    ///
    /// **「未指定」有兩種，只有一種刪得掉。** `node(at:)` 回 nil 代表
    /// `trees.<角色>` 這個鍵根本不存在——畫布把它畫成一格「未指定」，但底下沒有
    /// 任何節點，`deletingPane` 走的 `JSONPath.delete` 刪一個不存在的鍵是 no-op，
    /// 而 `edit` 只看得到「文件沒變」。UI 據此不給那一格刪除的選單，
    /// 因為**給了一個按下去什麼都不會發生的選項，與「壞了」在畫面上分不出來**。
    ///
    /// 分割底下的 `{}` 是另一種：`node(at:)` 回 `.object([])`，刪得掉
    /// （兄弟頂上來、那一層塌掉）。
    func canDeletePane(at path: PanePath) -> Bool {
        node(at: path) != nil
    }

    /// 拖走一個窗格。
    ///
    /// 有父親 → 父親整個被兄弟取代(塌掉一層)。是根 → **刪掉 `trees.<角色>` 這個鍵**:
    /// 留 `{}` 會讓 `LayoutValidator` 報「節點既沒有 window 也沒有 axis」而 ⌘S 被擋住,
    /// 而 `allTreeChecks` 走的是 `trees` 的 `to_entries`,鍵不存在就完全不檢查(C2)。
    ///
    /// 副作用要知道:**只有 tree 沒 display 的角色,那一格會整格消失**
    /// (`CanvasRole` 的聯集第二段沒東西了)。那是忠實的,而且 ⌘Z 救得回來。
    func deletingPane(at path: PanePath) -> LayoutDocument {
        guard let parent = path.parent, let slot = path.siblingSlot else {
            return rebuilt(try? JSONPath.delete(root, path.roleSteps))
        }
        guard let sibling = node(at: parent.child(slot)) else { return self }
        return rebuilt(try? JSONPath.set(root, parent.steps, to: sibling))
    }

    /// 這條分割線存不存得住 ratio。
    ///
    /// **只有第一個 child 是葉時才存得住**(C1):ratio 只能掛在葉上
    /// (`RectTree.swift:94` 的「內部節點不帶 ratio」),而畫布讀的是第一個 child 的
    /// 那一個(`CanvasView.swift:60`)。寫到第二個 child 上雖然存得下,但畫面讀不到它,
    /// 使用者會拖、放手、然後看到線彈回原位。
    ///
    /// 條件與 `settingRatio` 的 guard 是同一個,抄兩份會漂移,所以
    /// `aDividerWhoseFirstChildIsASplitCannotHoldARatio` 把兩支綁在一起驗。
    func canSetRatio(at path: PanePath) -> Bool {
        guard case let .object(members)? = node(at: path.child(0)) else { return false }
        return members.contains { $0.key == "window" }
    }

    /// 拖分割線。`path` 指的是**分割節點**,值寫進它第一個 child。
    ///
    /// 夾到 0.05…0.95,與 `CanvasView.dividerFraction` 讀回來時同一組邊界——
    /// 寫得進去卻讀不回來的值會讓畫面與檔案永久不一致。字面值走
    /// `RectTree.ratioLiteral`,與 `--save` 寫出來的同形(C7)。
    func settingRatio(at path: PanePath, to fraction: Double) -> LayoutDocument {
        guard canSetRatio(at: path),
              let literal = RectTree.ratioLiteral(min(max(fraction, 0.05), 0.95))
        else { return self }
        return rebuilt(try? JSONPath.set(root, path.child(0).steps + [.key("ratio")],
                                         to: .number(literal)))
    }

    /// ⌥ 點分割線。
    ///
    /// 認不得的 axis(`diagonal`、`null`)翻成 `vertical` 而不是拒絕:拒絕的話那個檔在
    /// 編輯器裡就沒有辦法修好,而修好它正是使用者開編輯器的理由(C6)。
    ///
    /// 有 `window` 的節點不給翻:`window` 優先於 `axis`(`PaneNode.swift:49`、
    /// `LayoutValidator.swift:272`),那個 axis 在畫布上根本沒被畫出來。
    func flippingAxis(at path: PanePath) -> LayoutDocument {
        guard case let .object(members)? = node(at: path),
              !members.contains(where: { $0.key == "window" }),
              let axis = members.first(where: { $0.key == "axis" })?.value
        else { return self }
        let next = axis == .string("vertical") ? "horizontal" : "vertical"
        return rebuilt(try? JSONPath.set(root, path.steps + [.key("axis")],
                                         to: .string(next)))
    }

    /// 這棵樹裡的葉，依畫面順序（深度優先、先 `children[0]`）。
    ///
    /// 回的是**整個節點**不是 `window` 的值：`ratio` 的字面值與使用者自己加的鍵
    /// （fixture 的 `note`）都要活過重排，理由與這個檔的檔頭那條「不能拿
    /// `PaneNode` 寫回去」同一條——`PaneNode` 是有損投影。
    ///
    /// `window` 優先於 `axis`，與 `PaneNode.init` 及
    /// `LayoutValidator.treeChecks` 同一個順序：兩者都有時 children 完全不看。
    func windowLeaves(at path: PanePath) -> [JSONValue] {
        Self.leaves(in: node(at: path))
    }

    /// 套一個版面模板到整棵樹。
    ///
    /// **放不下就整個回原文件**，不截斷：截斷會產生一棵合法的樹，而少掉的那個視窗
    /// 沒有任何訊號。`EditorController.applyTemplate` 據此出一句具名的拒絕。
    ///
    /// 走 `setCreatingMissingObjects` 而不是 `set`，與 `placing` 的空白分支同一條：
    /// 還沒畫過的 space 在 profile 底下連 `spaceTrees` 這個鍵都還沒有，而 `set`
    /// 對走不通的**中繼段**是 throw。
    ///
    /// `ratio` **刻意不清掉**：使用者調過的比例被新的分割線繼承，比一律均分接近他
    /// 的意圖。代價是那個比例可能來自另一個軸（原本是上下分的 0.75 變成左右分的
    /// 0.75），但它只影響畫面上那條線的位置，改不壞任何東西。
    func applyingTemplate(_ template: PaneTemplate, at path: PanePath) -> LayoutDocument {
        let leaves = windowLeaves(at: path)
        guard leaves.count <= template.slotCount else { return self }
        var queue = leaves[...]
        let tree = template.skeleton.filled(from: &queue)
        return rebuilt(try? JSONPath.setCreatingMissingObjects(root, path.roleSteps,
                                                               to: tree))
    }

    private static func leaves(in value: JSONValue?) -> [JSONValue] {
        guard let value, case let .object(members) = value else { return [] }
        if members.contains(where: { $0.key == "window" }) {
            return [value]
        }
        guard case let .array(children)? =
            members.first(where: { $0.key == "children" })?.value
        else { return [] }
        return children.flatMap { leaves(in: $0) }
    }

    private static func isVacant(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null, .bool(false):
            true
        case let .object(members):
            members.isEmpty
        default:
            false
        }
    }
}
